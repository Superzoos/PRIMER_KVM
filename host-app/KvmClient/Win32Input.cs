using System.ComponentModel;
using System.Runtime.InteropServices;

namespace KvmClient;

/// <summary>
/// Перехват клавиатуры Windows (низкоуровневый хук WH_KEYBOARD_LL): только так в рабочем режиме на удалённый ПК
/// уходят и системные сочетания (Win, Alt+Tab, Alt+F4, Ctrl+Esc); Ctrl+Alt+Del Windows не отдаёт никому.
/// Хук ставится из потока интерфейса (у него есть цикл сообщений) и вызывается в нём же.
/// Также: ограничение курсора прямоугольником окна (ClipCursor) и проверка, что окно активно.
/// </summary>
public sealed class Win32Input : IDisposable
{
    /// <summary>Событие клавиши: скан-код (с флагом E0), виртуальный код, отпускание. Вернуть true - не отдавать Windows.</summary>
    public delegate bool KeyHandler(int scan, bool extended, int vk, bool up);

    private const int WH_KEYBOARD_LL = 13;
    private const int LLKHF_EXTENDED = 0x01, LLKHF_INJECTED = 0x10, LLKHF_UP = 0x80;

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }
    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookExW(int idHook, HookProc fn, IntPtr hMod, uint threadId);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] private static extern bool ClipCursor(ref RECT r);
    [DllImport("user32.dll", EntryPoint = "ClipCursor")] private static extern bool ClipCursorNone(IntPtr r);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandleW(string? name);

    private readonly HookProc _proc;      // держим ссылку: иначе сборщик мусора уберёт делегат, а хук останется
    private readonly IntPtr _hook;
    private readonly KeyHandler _handler;

    public Win32Input(KeyHandler handler)
    {
        _handler = handler;
        _proc = Hook;
        _hook = SetWindowsHookExW(WH_KEYBOARD_LL, _proc, GetModuleHandleW(null), 0);
        if (_hook == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    private IntPtr Hook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var k = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
            if ((k.flags & LLKHF_INJECTED) == 0 &&
                _handler((int)k.scanCode, (k.flags & LLKHF_EXTENDED) != 0, (int)k.vkCode, (k.flags & LLKHF_UP) != 0))
                return (IntPtr)1;
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    public static bool IsForeground(IntPtr hwnd) => hwnd != IntPtr.Zero && GetForegroundWindow() == hwnd;

    /// <summary>Не выпускать курсор за пределы окна (true) или снять ограничение (false).</summary>
    public static void Clip(IntPtr hwnd, bool on)
    {
        if (on && hwnd != IntPtr.Zero && GetWindowRect(hwnd, out var r)) ClipCursor(ref r);
        else ClipCursorNone(IntPtr.Zero);
    }

    public void Dispose() => UnhookWindowsHookEx(_hook);

    // ---------------- Скан-коды (набор 1, как их отдаёт Windows) -> коды HID (Usage Page 0x07) ----------------

    /// <summary>Код клавиши HID или 0, если клавиша не поддерживается.</summary>
    public static byte ToHid(int scan, bool extended, int vk)
    {
        // особые случаи Windows: Pause и NumLock приходят со скан-кодом 0x45, различаются флагом/виртуальным кодом
        if (vk == 0x13) return 0x48;                          // Pause
        if (vk == 0x90) return 0x53;                          // NumLock
        if (vk == 0x2C) return 0x46;                          // PrintScreen
        if (scan is < 0 or > 0x7F) return 0;
        return extended ? Ext[scan] : Std[scan];
    }

    /// <summary>Бит модификатора в байте модификаторов HID для кода 0xE0..0xE7, иначе 0.</summary>
    public static byte ModBit(byte hid) => hid is >= 0xE0 and <= 0xE7 ? (byte)(1 << (hid - 0xE0)) : (byte)0;

    private static readonly byte[] Std = Build(new (int, byte)[]
    {
        (0x01, 0x29), (0x02, 0x1E), (0x03, 0x1F), (0x04, 0x20), (0x05, 0x21), (0x06, 0x22), (0x07, 0x23), (0x08, 0x24),
        (0x09, 0x25), (0x0A, 0x26), (0x0B, 0x27), (0x0C, 0x2D), (0x0D, 0x2E), (0x0E, 0x2A), (0x0F, 0x2B),
        (0x10, 0x14), (0x11, 0x1A), (0x12, 0x08), (0x13, 0x15), (0x14, 0x17), (0x15, 0x1C), (0x16, 0x18), (0x17, 0x0C),
        (0x18, 0x12), (0x19, 0x13), (0x1A, 0x2F), (0x1B, 0x30), (0x1C, 0x28), (0x1D, 0xE0),
        (0x1E, 0x04), (0x1F, 0x16), (0x20, 0x07), (0x21, 0x09), (0x22, 0x0A), (0x23, 0x0B), (0x24, 0x0D), (0x25, 0x0E),
        (0x26, 0x0F), (0x27, 0x33), (0x28, 0x34), (0x29, 0x35), (0x2A, 0xE1), (0x2B, 0x31),
        (0x2C, 0x1D), (0x2D, 0x1B), (0x2E, 0x06), (0x2F, 0x19), (0x30, 0x05), (0x31, 0x11), (0x32, 0x10),
        (0x33, 0x36), (0x34, 0x37), (0x35, 0x38), (0x36, 0xE5), (0x37, 0x55), (0x38, 0xE2), (0x39, 0x2C), (0x3A, 0x39),
        (0x3B, 0x3A), (0x3C, 0x3B), (0x3D, 0x3C), (0x3E, 0x3D), (0x3F, 0x3E), (0x40, 0x3F), (0x41, 0x40), (0x42, 0x41),
        (0x43, 0x42), (0x44, 0x43), (0x46, 0x47),
        (0x47, 0x5F), (0x48, 0x60), (0x49, 0x61), (0x4A, 0x56), (0x4B, 0x5C), (0x4C, 0x5D), (0x4D, 0x5E), (0x4E, 0x57),
        (0x4F, 0x59), (0x50, 0x5A), (0x51, 0x5B), (0x52, 0x62), (0x53, 0x63), (0x56, 0x64), (0x57, 0x44), (0x58, 0x45),
        (0x64, 0x68), (0x65, 0x69), (0x66, 0x6A), (0x67, 0x6B), (0x68, 0x6C), (0x69, 0x6D), (0x6A, 0x6E), (0x6B, 0x6F),
        (0x6C, 0x70), (0x6D, 0x71), (0x6E, 0x72), (0x76, 0x73),
    });

    private static readonly byte[] Ext = Build(new (int, byte)[]
    {
        (0x1C, 0x58), (0x1D, 0xE4), (0x35, 0x54), (0x37, 0x46), (0x38, 0xE6),
        (0x47, 0x4A), (0x48, 0x52), (0x49, 0x4B), (0x4B, 0x50), (0x4D, 0x4F), (0x4F, 0x4D), (0x50, 0x51), (0x51, 0x4E),
        (0x52, 0x49), (0x53, 0x4C), (0x5B, 0xE3), (0x5C, 0xE7), (0x5D, 0x65),
    });

    private static byte[] Build((int Scan, byte Hid)[] map)
    {
        var t = new byte[0x80];
        foreach (var (s, h) in map) t[s] = h;
        return t;
    }
}
