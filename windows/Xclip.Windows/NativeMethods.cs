using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Xclip.Windows;

internal static class NativeMethods
{
    internal const int ClipboardUpdate = 0x031D;
    internal const int HotKey = 0x0312;
    internal const uint ControlAltNoRepeat = 0x0002 | 0x0001 | 0x4000;

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool AddClipboardFormatListener(nint hwnd);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool RemoveClipboardFormatListener(nint hwnd);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UnregisterHotKey(nint hwnd, int id);
    [DllImport("user32.dll")]
    internal static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")]
    internal static extern nint GetClipboardOwner();
    [DllImport("user32.dll")]
    internal static extern nint GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern nint GetShellWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(nint hwnd, StringBuilder name, int capacity);
    [DllImport("user32.dll")]
    internal static extern uint GetWindowThreadProcessId(nint hwnd, out uint processId);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool IsWindow(nint hwnd);
    [DllImport("user32.dll")]
    internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterClipboardFormat(string name);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenClipboard(nint hwnd);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseClipboard();
    [DllImport("user32.dll")]
    private static extern nint GetClipboardData(uint format);
    [DllImport("kernel32.dll")]
    private static extern nuint GlobalSize(nint memory);
    [DllImport("kernel32.dll")]
    private static extern nint GlobalLock(nint memory);
    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalUnlock(nint memory);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, Input[] inputs, int size);

    // INPUT's union must include MOUSEINPUT so cbSize is 40 on x64/ARM64.
    [StructLayout(LayoutKind.Sequential)]
    private struct Input { public uint Type; public InputUnion Data; }
    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort Key, Scan;
        public uint Flags, Time;
        public nuint Extra;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X, Y;
        public uint MouseData, Flags, Time;
        public nuint Extra;
    }

    internal static bool IsExternalWindow(nint window)
    {
        if (window == 0 || !IsWindow(window) || window == GetShellWindow()) return false;
        var className = new StringBuilder(256);
        GetClassName(window, className, className.Capacity);
        if (className.ToString() is "Shell_TrayWnd" or "Shell_SecondaryTrayWnd" or "Progman" or "WorkerW") return false;
        GetWindowThreadProcessId(window, out var pid);
        return pid != 0 && pid != Environment.ProcessId;
    }

    internal static string? ProcessName(nint window)
    {
        GetWindowThreadProcessId(window, out var pid);
        if (pid == 0) return null;
        try { using var process = Process.GetProcessById((int)pid); return process.ProcessName; }
        catch (ArgumentException) { return null; }
        catch (System.ComponentModel.Win32Exception) { return null; }
        catch (InvalidOperationException) { return null; }
    }

    internal static bool ModifiersReleased() =>
        new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.All(key => (GetAsyncKeyState(key) & 0x8000) == 0);

    internal static bool InvocationKeysReleased() => ModifiersReleased() &&
        new[] { 0x01, 0x0D, 0x20, 0x56 }.All(key => (GetAsyncKeyState(key) & 0x8000) == 0);

    internal static bool SendPaste()
    {
        static Input Key(ushort key, bool up = false) => new()
        {
            Type = 1,
            Data = new InputUnion { Keyboard = new KeyboardInput { Key = key, Flags = up ? 2u : 0u } }
        };
        Input[] keys = [Key(0x11), Key(0x56), Key(0x56, true), Key(0x11, true)];
        var sent = SendInput((uint)keys.Length, keys, Marshal.SizeOf<Input>());
        if (sent == keys.Length) return true;
        // Recover any synthetic down event on partial injection.
        Input[] release = [Key(0x56, true), Key(0x11, true)];
        SendInput((uint)release.Length, release, Marshal.SizeOf<Input>());
        return false;
    }

    internal static int InputSize => Marshal.SizeOf<Input>();

    internal static bool ExcludedFromHistory(nint window)
    {
        var exclude = RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
        if (IsClipboardFormatAvailable(exclude)) return true;
        var include = RegisterClipboardFormat("CanIncludeInClipboardHistory");
        if (!IsClipboardFormatAvailable(include)) return false;
        if (!OpenClipboard(window)) throw new ExternalException("剪贴板正被其他应用占用。");
        try
        {
            var memory = GetClipboardData(include);
            // Malformed privacy hints are treated conservatively.
            if (memory == 0 || GlobalSize(memory) < 4) return true;
            var pointer = GlobalLock(memory);
            if (pointer == 0) return true;
            try { return Marshal.ReadInt32(pointer) == 0; }
            finally { GlobalUnlock(memory); }
        }
        finally { CloseClipboard(); }
    }
}
