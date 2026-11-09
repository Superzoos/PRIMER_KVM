using System.Diagnostics;
using Avalonia.Threading;

namespace KvmClient;

/// <summary>
/// Состояние клавиатуры и мыши удалённого ПК (kvm_input_t, firmware/app/kvm_proto.h) и его отправка на плату:
/// при каждом изменении и 20 раз в секунду, пока управление включено (плата отпускает всё, если пакетов нет 0.5 с).
/// Пакет - полное состояние, поэтому потеря одного не страшна. Колесо - накопительный счётчик щелчков.
/// Движение мыши без смены кнопок отправляется не чаще раза в MoveGapMs (последнее положение - по таймеру):
/// Windows даёт до ~1000 событий в секунду, а у платы два буфера приёма - поток таких пакетов вытеснял
/// запросы обновления картинки.
/// </summary>
public sealed class RemoteInput
{
    private readonly KvmLink _link;
    private readonly List<byte> _keys = new();     // нажатые клавиши (не модификаторы) по порядку нажатия
    private byte _mods, _buttons, _wheel, _pan;
    private ushort _x, _y;
    private double _wheelAcc, _panAcc;              // дробные щелчки (сенсорные панели)

    private const int MoveGapMs = 8;                // 125 пакетов движения в секунду (как у обычной мыши)
    private readonly Stopwatch _sinceSend = Stopwatch.StartNew();
    private readonly DispatcherTimer _flush = new() { Interval = TimeSpan.FromMilliseconds(MoveGapMs) };
    private bool _movePending, _flushOn;

    public bool Active { get; private set; }

    public RemoteInput(KvmLink link)
    {
        _link = link;
        _flush.Tick += (_, _) =>
        {
            _flush.Stop();
            _flushOn = false;
            if (_movePending && Active) Send();
        };
    }

    /// <summary>Включить или выключить управление. При выключении плата сразу отпускает всё.</summary>
    public void SetActive(bool on)
    {
        _keys.Clear();
        _mods = 0;
        _buttons = 0;
        Active = on;
        Send();
        if (!on) { Send(); Send(); }               // выключение - несколько раз, на случай потери пакета
    }

    /// <summary>Клавиша (код HID) нажата или отпущена.</summary>
    public void Key(byte hid, bool down)
    {
        if (hid == 0 || !Active) return;
        var m = Win32Input.ModBit(hid);
        if (m != 0)
        {
            var n = down ? (byte)(_mods | m) : (byte)(_mods & ~m);
            if (n == _mods) return;
            _mods = n;
        }
        else if (down)
        {
            if (_keys.Contains(hid)) return;        // автоповтор Windows: состояние то же
            _keys.Add(hid);
        }
        else if (!_keys.Remove(hid)) return;
        Send();
    }

    /// <summary>Положение мыши в долях экрана удалённого ПК (0..1) и нажатые кнопки (биты kvm_input_t.buttons).</summary>
    public void Mouse(double fx, double fy, byte buttons)
    {
        if (!Active) return;
        var x = (ushort)Math.Round(Math.Clamp(fx, 0, 1) * 32767);
        var y = (ushort)Math.Round(Math.Clamp(fy, 0, 1) * 32767);
        if (x == _x && y == _y && buttons == _buttons) return;
        var now = buttons != _buttons || _sinceSend.ElapsedMilliseconds >= MoveGapMs;
        _x = x; _y = y; _buttons = buttons;
        if (now) Send();
        else
        {
            _movePending = true;
            if (!_flushOn) { _flushOn = true; _flush.Start(); }
        }
    }

    /// <summary>Прокрутка: щелчки колеса (вверх - плюс) и горизонтальной прокрутки (вправо - плюс).</summary>
    public void Wheel(double dy, double dx)
    {
        if (!Active) return;
        _wheelAcc += dy;
        _panAcc += dx;
        int w = (int)Math.Truncate(_wheelAcc), p = (int)Math.Truncate(_panAcc);
        if (w == 0 && p == 0) return;
        _wheelAcc -= w;
        _panAcc -= p;
        _wheel = unchecked((byte)(_wheel + w));
        _pan = unchecked((byte)(_pan + p));
        Send();
    }

    /// <summary>Повтор состояния (раз в 50 мс, пока управление включено).</summary>
    public void Heartbeat()
    {
        if (Active) Send();
    }

    private void Send()
    {
        _movePending = false;
        _sinceSend.Restart();
        var p = new byte[16];
        p[0] = Active ? (byte)1 : (byte)0;
        p[1] = _mods;
        if (_keys.Count > 6)
            for (var i = 0; i < 6; i++) p[2 + i] = 0x01;            // ErrorRollOver (HID): больше 6 клавиш
        else
            for (var i = 0; i < _keys.Count; i++) p[2 + i] = _keys[i];
        p[8] = _buttons;
        p[10] = (byte)_x; p[11] = (byte)(_x >> 8);
        p[12] = (byte)_y; p[13] = (byte)(_y >> 8);
        p[14] = _wheel;
        p[15] = _pan;
        _link.SendInput(p);
    }
}
