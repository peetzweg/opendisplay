using System.Runtime.InteropServices;
using OpenDisplay.Windows.Models;

namespace OpenDisplay.Windows.Services;

internal sealed class WindowsInputInjector(DisplayTarget target)
{
    private const uint InputMouse = 0;
    private const uint MouseLeftDown = 0x0002;
    private const uint MouseLeftUp = 0x0004;
    private const uint MouseWheel = 0x0800;
    private const uint MouseHWheel = 0x01000;
    private bool _isDown;

    public void Touch(string phase, double x, double y)
    {
        var px = target.Left + (int)Math.Round(Math.Clamp(x, 0, 1) * Math.Max(0, target.Width - 1));
        var py = target.Top + (int)Math.Round(Math.Clamp(y, 0, 1) * Math.Max(0, target.Height - 1));
        SetCursorPos(px, py);
        switch (phase)
        {
            case "began" when !_isDown:
                SendMouse(MouseLeftDown, 0);
                _isDown = true;
                break;
            case "ended" or "cancelled" when _isDown:
                SendMouse(MouseLeftUp, 0);
                _isDown = false;
                break;
        }
    }

    public void Scroll(double dx, double dy)
    {
        // Receiver deltas are video pixels. Converting 40 px to one wheel
        // detent gives a trackpad-like baseline while preserving sub-detent
        // precision through Windows' standard WHEEL_DELTA units.
        var vertical = (int)Math.Round(-dy * 120 / 40.0);
        var horizontal = (int)Math.Round(dx * 120 / 40.0);
        if (vertical != 0) SendMouse(MouseWheel, vertical);
        if (horizontal != 0) SendMouse(MouseHWheel, horizontal);
    }

    public void ReleaseButtons()
    {
        if (!_isDown) return;
        SendMouse(MouseLeftUp, 0);
        _isDown = false;
    }

    private static void SendMouse(uint flags, int data)
    {
        var input = new INPUT
        {
            type = InputMouse,
            mouse = new MOUSEINPUT { dwFlags = flags, mouseData = unchecked((uint)data) }
        };
        _ = SendInput(1, [input], Marshal.SizeOf<INPUT>());
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public MOUSEINPUT mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx, dy;
        public uint mouseData, dwFlags, time;
        public nuint dwExtraInfo;
    }

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint inputCount, INPUT[] inputs, int size);
}
