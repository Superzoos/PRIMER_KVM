using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Net;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Input;
using Avalonia.Platform;
using Avalonia.Threading;

namespace KvmClient;

public partial class MainWindow : Window
{
    private readonly ObservableCollection<string> _log = new();
    private KvmLink? _link;
    private CancellationTokenSource? _cts;

    // вывод кадра: два растра по очереди - Image гарантированно перерисовывается при смене Source
    private readonly WriteableBitmap?[] _bmp = new WriteableBitmap?[2];
    private int _bmpIdx;

    // рабочий режим: клавиатура и мышь - на удалённый ПК (Ctrl+Alt+Q - вход и выход)
    private Win32Input? _hook;
    private RemoteInput? _input;
    private bool _work, _ctrlL, _ctrlR, _altL, _altR, _swallowQ;
    private readonly Dictionary<int, byte> _down = new();   // скан-код (| 0x100 для E0) -> код HID, отправленный при нажатии
    private WindowState _savedState;
    private int _iw = 1280, _ih = 720;                      // размер кадра удалённого ПК (для пересчёта мыши)
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(50) };
    private bool _linkOk;
    private string _videoInfo = "", _statusInfo = "";

    public MainWindow()
    {
        InitializeComponent();
        LogList.ItemsSource = _log;
        Opened += (_, _) =>
        {
            if (!OperatingSystem.IsWindows()) { Log("Перехват клавиатуры есть только в Windows"); return; }
            try { _hook = new Win32Input(OnKey); }
            catch (Exception ex) { Log($"Перехват клавиатуры не включился: {ex.Message}"); }
        };
        Deactivated += (_, _) => { if (_work) SetWork(false, "окно потеряло фокус"); };
        VideoBorder.PointerMoved += OnPointer;
        VideoBorder.PointerPressed += OnPointer;
        VideoBorder.PointerReleased += OnPointer;
        VideoBorder.PointerWheelChanged += OnWheel;
        _timer.Tick += OnTimer;
        _timer.Start();
    }

    private IntPtr Hwnd => TryGetPlatformHandle()?.Handle ?? IntPtr.Zero;

    // ---------------- Рабочий режим ----------------

    // Клавиша (хук Windows, поток интерфейса). true - не отдавать её Windows.
    private bool OnKey(int scan, bool ext, int vk, bool up)
    {
        switch (vk)                                             // свои Ctrl и Alt - для сочетаний
        {
            case 0xA2: _ctrlL = !up; break;
            case 0xA3: _ctrlR = !up; break;
            case 0xA4: _altL = !up; break;
            case 0xA5: _altR = !up; break;
        }
        if (!Win32Input.IsForeground(Hwnd)) return false;
        var ctrl = _ctrlL || _ctrlR;
        var alt = _altL || _altR;

        if (vk == 0x51)                                         // Q: Ctrl+Alt+Q - вход / выход
        {
            if (!up && ctrl && alt)
            {
                _swallowQ = true;
                if (_work) SetWork(false, "Ctrl+Alt+Q");
                else if (_link != null && _input != null && _linkOk) SetWork(true, "Ctrl+Alt+Q");
                else Log("Рабочий режим: нет связи с устройством");
                return true;
            }
            if (up && _swallowQ) { _swallowQ = false; return true; }
            if (!up && _swallowQ) return true;                  // автоповтор
        }
        if (!_work || _input == null) return false;

        var key = scan | (ext ? 0x100 : 0);
        if (!up)
        {
            var hid = Win32Input.ToHid(scan, ext, vk);
            if (hid == 0x4D && ctrl && alt) hid = 0x4C;          // Ctrl+Alt+End -> Ctrl+Alt+Del на удалённом ПК
            if (!_down.ContainsKey(key)) _down[key] = hid;
            _input.Key(_down[key], true);
        }
        else if (_down.Remove(key, out var hid))
        {
            _input.Key(hid, false);
        }
        return true;                                            // в рабочем режиме Windows клавиш не видит
    }

    private void SetWork(bool on, string why)
    {
        if (on == _work || _input == null && on) return;
        _work = on;
        _down.Clear();
        if (on)
        {
            _savedState = WindowState;
            TopBar.IsVisible = InfoText.IsVisible = LogList.IsVisible = false;
            RootGrid.Margin = new Thickness(0);
            VideoBorder.Margin = new Thickness(0);
            VideoBorder.BorderThickness = new Thickness(0);
            VideoBorder.Background = Brushes.Black;
            WindowState = WindowState.FullScreen;
            Cursor = new Cursor(StandardCursorType.None);
            _input!.SetActive(true);
            // курсор - внутри окна (после перехода в полный экран)
            DispatcherTimer.RunOnce(() => { if (_work && OperatingSystem.IsWindows()) Win32Input.Clip(Hwnd, true); },
                                    TimeSpan.FromMilliseconds(300));
            Log($"Рабочий режим включён ({why}): клавиатура и мышь - на удалённый ПК, выход - Ctrl+Alt+Q");
        }
        else
        {
            _input?.SetActive(false);
            if (OperatingSystem.IsWindows()) Win32Input.Clip(Hwnd, false);
            Cursor = Cursor.Default;
            WindowState = _savedState;
            TopBar.IsVisible = InfoText.IsVisible = LogList.IsVisible = true;
            RootGrid.Margin = new Thickness(10);
            VideoBorder.Margin = new Thickness(0, 10, 0, 0);
            VideoBorder.BorderThickness = new Thickness(1);
            UpdateLinkView(true);
            Log($"Рабочий режим выключен ({why})");
        }
    }

    // Мышь над изображением: положение в долях кадра удалённого ПК (изображение вписано в окно с полями)
    private void OnPointer(object? sender, PointerEventArgs e)
    {
        if (!_work || _input == null) return;
        var p = e.GetPosition(FrameImage);
        var b = FrameImage.Bounds;
        var scale = Math.Min(b.Width / _iw, b.Height / _ih);
        if (scale <= 0) return;
        double dw = _iw * scale, dh = _ih * scale;
        var fx = (p.X - (b.Width - dw) / 2) / dw;
        var fy = (p.Y - (b.Height - dh) / 2) / dh;
        var pp = e.GetCurrentPoint(FrameImage).Properties;
        var buttons = (byte)((pp.IsLeftButtonPressed ? 1 : 0) | (pp.IsRightButtonPressed ? 2 : 0) |
                             (pp.IsMiddleButtonPressed ? 4 : 0) | (pp.IsXButton1Pressed ? 8 : 0) |
                             (pp.IsXButton2Pressed ? 16 : 0));
        _input.Mouse(fx, fy, buttons);
        e.Handled = true;
    }

    private void OnWheel(object? sender, PointerWheelEventArgs e)
    {
        if (!_work || _input == null) return;
        _input.Wheel(e.Delta.Y, e.Delta.X);
        e.Handled = true;
    }

    // Каждые 50 мс: повтор состояния ввода; проверка связи (нет пакетов от устройства больше 1 с - "Нет связи")
    private void OnTimer(object? sender, EventArgs e)
    {
        _input?.Heartbeat();
        var ok = _link != null && _link.SinceLastRx < TimeSpan.FromSeconds(1);
        if (ok == _linkOk) return;
        _linkOk = ok;
        if (!ok && _work) SetWork(false, "нет связи с устройством");
        UpdateLinkView(false);
    }

    private void UpdateLinkView(bool restoreBackground)
    {
        var showImage = _linkOk && FrameImage.Source != null;
        FrameImage.IsVisible = showImage;
        NoVideoText.Text = _linkOk ? "Нет кадра" : "Нет связи";
        NoVideoText.IsVisible = !showImage;
        if (!_work || restoreBackground)
            VideoBorder.Background = showImage ? new SolidColorBrush(Color.Parse("#202020")) : new SolidColorBrush(Color.Parse("#505050"));
    }

    private void OnConnectClick(object? sender, RoutedEventArgs e)
    {
        if (_cts != null)
        {
            Disconnect();
            return;
        }
        if (!IPAddress.TryParse(IpBox.Text, out var ip) || !int.TryParse(PortBox.Text, out var port) || port is < 1 or > 65535)
        {
            Log("Неверный IP-адрес или порт");
            return;
        }

        _link = new KvmLink(new IPEndPoint(ip, port));
        _input = new RemoteInput(_link);
        _cts = new CancellationTokenSource();
        ConnectButton.Content = "Отключиться";
        IpBox.IsEnabled = PortBox.IsEnabled = false;
        Log($"Подключение к {ip}:{port}" + (_link.LocalAddress != null
            ? $", запросы с адреса {_link.LocalAddress}"
            : " (на ПК нет адреса из подсети платы - маршрут выберет Windows)"));
        _ = PollLoop(_link, _cts.Token);
        _ = VideoLoop(_link, _cts.Token);
    }

    private void Disconnect()
    {
        SetWork(false, "отключение");
        _cts?.Cancel();
        _cts?.Dispose();
        _cts = null;
        _input = null;
        _link?.Dispose();
        _link = null;
        FrameImage.Source = null;
        _linkOk = false;
        UpdateLinkView(true);
        ConnectButton.Content = "Подключиться";
        IpBox.IsEnabled = PortBox.IsEnabled = true;
        SetState(false, "не подключено");
        InfoText.Text = "";
        _videoInfo = "";
        Log("Отключено");
    }

    // Запрос состояния 4 раза в секунду (по ответам и плиткам проверяется связь); 4 пропуска подряд (1 с) -
    // устройство недоступно.
    private async Task PollLoop(KvmLink link, CancellationToken ct)
    {
        var online = false;
        var misses = 0;
        while (!ct.IsCancellationRequested)
        {
            var st = await link.RequestStatusAsync(TimeSpan.FromMilliseconds(500), ct);
            if (ct.IsCancellationRequested) break;
            if (st != null)
            {
                misses = 0;
                if (!online) { online = true; Log("Устройство отвечает"); }
                SetState(true, $"на связи, отклик {st.Rtt.TotalMilliseconds:F1} мс");
                _statusInfo = $"HDMI: {HdmiText(st)}    USB: {UsbText(st)}" +
                              (st.DdrMb == 0 ? "    DDR3: ошибка" : "");
                InfoText.Text = $"{_videoInfo}    {_statusInfo}";
                ToolTip.SetTip(StatusText, $"Прошивка {st.Firmware}, работает {TimeSpan.FromMilliseconds(st.UptimeMs):d\\.hh\\:mm\\:ss}");
            }
            else if (++misses >= 4 && online)
            {
                online = false;
                SetState(false, "нет ответа");
                Log("Устройство не отвечает");
            }
            else if (!online)
            {
                SetState(false, "ожидание ответа");
            }
            try { await Task.Delay(250, ct); } catch (OperationCanceledException) { break; }
        }
    }

    // usb_flags (kvm_proto.h): бит 0 - подключено, 1 - High Speed, 2 - удалённый ПК спит, 16 - управление включено
    private static string UsbText(DeviceStatus st)
    {
        var f = st.UsbFlags;
        if ((f & 1) == 0) return "не подключено";
        return ((f & 4) != 0 ? "удалённый ПК спит" : "подключено") + ((f & 0x10000) != 0 ? ", управление" : "");
    }

    // Обновления запрашиваются по одному: следующее - после применения предыдущего. Обновление применяется
    // целиком (все плитки из одного кадра); если плитки потерялись - запрашивается полное обновление.
    private async Task VideoLoop(KvmLink link, CancellationToken ct)
    {
        var watch = Stopwatch.StartNew();
        int shown = 0, lost = 0;
        double fps = 0;
        int[]? image = null;
        int iw = 0, ih = 0, source = -1;
        var full = true;
        UpdateResult? lastResult = null;
        int noReply = 0;                                       // подряд без ответа
        while (!ct.IsCancellationRequested)
        {
            // ответ платы в локальной сети приходит за доли миллисекунды: потерянный запрос повторяется через
            // 150 мс без паузы; пауза 0.5 с - только если плата молчит дольше (3 запроса подряд)
            var (result, info, set) = await link.GrabUpdateAsync(full, TimeSpan.FromMilliseconds(150),
                                                                 TimeSpan.FromSeconds(1), ct);
            if (ct.IsCancellationRequested) { set?.Release(); break; }
            noReply = result == UpdateResult.NoReply ? noReply + 1 : 0;

            if (result != lastResult && result != UpdateResult.Lost && (result != UpdateResult.NoReply || noReply >= 3))
            {
                lastResult = result;
                switch (result)
                {
                    case UpdateResult.Started: Log("Видео: обновления идут"); break;
                    case UpdateResult.NoVideo: Log("Видео: на устройстве нет буфера кадра (ошибка DDR3, см. UART)"); break;
                    case UpdateResult.NoReply: _videoInfo = "Видео: нет ответа"; break;
                }
            }
            if (result == UpdateResult.Lost) { lost++; full = true; continue; }
            if (result != UpdateResult.Started || info == null || set == null)
            {
                full = true;
                var pause = result == UpdateResult.Busy ? 5 : result == UpdateResult.NoReply && noReply < 3 ? 0 : 500;
                if (pause > 0)
                    try { await Task.Delay(pause, ct); } catch (OperationCanceledException) { break; }
                continue;
            }

            if (image == null || info.Width != iw || info.Height != ih)
            {
                if (!full) { set.Release(); full = true; continue; }   // новый размер - только с полного обновления
                iw = info.Width;
                ih = info.Height;
                image = new int[iw * ih];
                _iw = iw;
                _ih = ih;
            }
            if (info.Source != source)
            {
                source = info.Source;
                Log(source == 1 ? "Видео: захват HDMI" : "Видео: тестовая картинка (нет сигнала HDMI)");
            }
            full = false;
            if (set.Tiles.Count > 0)
            {
                foreach (var t in set.Tiles)
                {
                    int x0 = t.Tx * info.TileW, y0 = t.Ty * info.TileH;
                    var cw = Math.Min(info.TileW, iw - x0);
                    for (var r = 0; r < info.TileH && y0 + r < ih; r++)
                        Array.Copy(t.Pixels, r * info.TileW, image, (y0 + r) * iw + x0, cw);
                }
                set.Release();
                Show(image, iw, ih);
                shown++;
            }
            if (watch.ElapsedMilliseconds >= 1000)
            {
                fps = shown * 1000.0 / watch.ElapsedMilliseconds;
                shown = 0;
                watch.Restart();
                _videoInfo = $"Видео: {iw}x{ih}, {fps:F0} кадр/с" + (lost > 0 ? $", потерь {lost}" : "");
                InfoText.Text = $"{_videoInfo}    {_statusInfo}";
            }
            if (info.Tiles == 0)                               // изменений нет - не чаще ~100 запросов/с
            {
                try { await Task.Delay(10, ct); } catch (OperationCanceledException) { break; }
            }
        }
    }

    private void Show(int[] pixels, int w, int h)
    {
        _bmpIdx ^= 1;
        var bmp = _bmp[_bmpIdx];
        if (bmp == null || bmp.PixelSize.Width != w || bmp.PixelSize.Height != h)
        {
            bmp?.Dispose();
            bmp = new WriteableBitmap(new PixelSize(w, h), new Vector(96, 96),
                                      PixelFormat.Bgra8888, AlphaFormat.Opaque);
            _bmp[_bmpIdx] = bmp;
        }
        using (var fb = bmp.Lock())
        {
            if (fb.RowBytes == w * 4)
                Marshal.Copy(pixels, 0, fb.Address, w * h);
            else
                for (var y = 0; y < h; y++)
                    Marshal.Copy(pixels, y * w, fb.Address + y * fb.RowBytes, w);
        }
        FrameImage.Source = bmp;
        if (_linkOk && !FrameImage.IsVisible) UpdateLinkView(false);
    }

    // hdmi_flags (kvm_proto.h): 0 PLL, 1 фаза, 2 кадры идут, 3 захват идёт, 4 HPD, 5 захват включён
    private static string HdmiText(DeviceStatus st)
    {
        var f = st.HdmiFlags;
        if ((f & 0x10) == 0) return "не настроен";
        if ((f & 0x20) == 0) return "нет сигнала";
        return $"{st.HdmiRes & 0xFFFF}x{st.HdmiRes >> 16}";
    }

    private void SetState(bool ok, string text)
    {
        StatusDot.Fill = ok ? Brushes.LimeGreen : Brushes.Gray;
        StatusText.Text = text;
    }

    private void Log(string text)
    {
        _log.Add($"{DateTime.Now:HH:mm:ss}  {text}");
        LogList.ScrollIntoView(_log.Count - 1);
    }

    protected override void OnClosed(EventArgs e)
    {
        SetWork(false, "закрытие");
        _hook?.Dispose();
        _timer.Stop();
        _cts?.Cancel();
        _link?.Dispose();
        base.OnClosed(e);
    }
}
