using System.Runtime.InteropServices;
using OpenDisplay.Windows.Models;

namespace OpenDisplay.Windows.Services;

internal sealed class MonitorLocator
{
    private const int EnumCurrentSettings = -1;
    private const uint DisplayDeviceActive = 0x1;
    private const uint DisplayDevicePrimary = 0x4;
    private const uint DmPosition = 0x20;
    private const uint DmPelsWidth = 0x80000;
    private const uint DmPelsHeight = 0x100000;
    private const uint DmDisplayFrequency = 0x400000;
    private const uint CdsUpdateRegistry = 0x1;
    private const uint CdsNoReset = 0x10000000;
    private const int DispChangeSuccessful = 0;

    public IReadOnlyList<WindowsMonitor> GetAll()
    {
        var result = new List<WindowsMonitor>();
        for (uint index = 0; ; index++)
        {
            var adapter = DISPLAY_DEVICE.Create();
            if (!EnumDisplayDevices(null, index, ref adapter, 0)) break;
            if ((adapter.StateFlags & DisplayDeviceActive) == 0) continue;

            var mode = DEVMODE.Create();
            if (!EnumDisplaySettingsEx(adapter.DeviceName, EnumCurrentSettings, ref mode, 0)) continue;
            result.Add(new WindowsMonitor(
                adapter.DeviceName,
                adapter.DeviceString,
                adapter.DeviceID,
                (adapter.StateFlags & DisplayDevicePrimary) != 0,
                true,
                new DisplayTarget(
                    adapter.DeviceID.Length == 0 ? adapter.DeviceName : adapter.DeviceID,
                    adapter.DeviceName,
                    mode.dmPositionX,
                    mode.dmPositionY,
                    (int)mode.dmPelsWidth,
                    (int)mode.dmPelsHeight,
                    IsVdd(adapter))));
        }
        return result;
    }

    public DisplayTarget GetPrimary() =>
        GetAll().FirstOrDefault(x => x.IsPrimary)?.Target
        ?? throw new InvalidOperationException("Windows did not report an active primary monitor.");

    /// <summary>
    /// Includes disabled VDD outputs. Newly arrived VDD monitors are sometimes
    /// disabled by Windows until an application assigns them a desktop mode.
    /// </summary>
    public IReadOnlyList<WindowsMonitor> GetVddOutputs()
    {
        var result = new List<WindowsMonitor>();
        for (uint index = 0; ; index++)
        {
            var adapter = DISPLAY_DEVICE.Create();
            if (!EnumDisplayDevices(null, index, ref adapter, 0)) break;
            if (!IsVdd(adapter)) continue;

            var mode = DEVMODE.Create();
            var hasMode = EnumDisplaySettingsEx(adapter.DeviceName, EnumCurrentSettings, ref mode, 0)
                || EnumDisplaySettingsEx(adapter.DeviceName, 0, ref mode, 0);
            var active = (adapter.StateFlags & DisplayDeviceActive) != 0;
            result.Add(new WindowsMonitor(
                adapter.DeviceName,
                adapter.DeviceString,
                adapter.DeviceID,
                (adapter.StateFlags & DisplayDevicePrimary) != 0,
                active,
                new DisplayTarget(
                    adapter.DeviceID.Length == 0 ? adapter.DeviceName : adapter.DeviceID,
                    adapter.DeviceName,
                    mode.dmPositionX,
                    mode.dmPositionY,
                    hasMode ? (int)mode.dmPelsWidth : 0,
                    hasMode ? (int)mode.dmPelsHeight : 0,
                    true)));
        }
        return result;
    }

    public bool TrySetMode(
        string deviceName,
        int width,
        int height,
        int refreshRate,
        out string error,
        int? left = null,
        int? top = null)
    {
        var mode = DEVMODE.Create();
        if (!EnumDisplaySettingsEx(deviceName, EnumCurrentSettings, ref mode, 0) &&
            !EnumDisplaySettingsEx(deviceName, 0, ref mode, 0))
        {
            error = "The display's current mode could not be read.";
            return false;
        }
        mode.dmPelsWidth = (uint)width;
        mode.dmPelsHeight = (uint)height;
        mode.dmDisplayFrequency = (uint)refreshRate;
        if (left is not null) mode.dmPositionX = left.Value;
        if (top is not null) mode.dmPositionY = top.Value;
        mode.dmFields = DmPosition | DmPelsWidth | DmPelsHeight | DmDisplayFrequency;

        var result = ChangeDisplaySettingsEx(deviceName, ref mode, IntPtr.Zero,
            CdsUpdateRegistry | CdsNoReset, IntPtr.Zero);
        if (result == DispChangeSuccessful)
            result = ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
        error = result == DispChangeSuccessful ? string.Empty : $"ChangeDisplaySettingsEx returned {result}.";
        return result == DispChangeSuccessful;
    }

    private static bool IsVdd(DISPLAY_DEVICE adapter)
    {
        var identity = $"{adapter.DeviceString} {adapter.DeviceID}";
        return identity.Contains("Virtual Display Driver", StringComparison.OrdinalIgnoreCase)
            || identity.Contains("MttVDD", StringComparison.OrdinalIgnoreCase);
    }

    internal sealed record WindowsMonitor(
        string DeviceName,
        string FriendlyName,
        string DeviceId,
        bool IsPrimary,
        bool IsActive,
        DisplayTarget Target);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;

        public static DISPLAY_DEVICE Create() => new() { cb = Marshal.SizeOf<DISPLAY_DEVICE>() };
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DEVMODE
    {
        private const int CchDeviceName = 32;
        private const int CchFormName = 32;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CchDeviceName)] public string dmDeviceName;
        public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public uint dmFields;
        public int dmPositionX, dmPositionY;
        public uint dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CchFormName)] public string dmFormName;
        public ushort dmLogPixels;
        public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2;
        public uint dmPanningWidth, dmPanningHeight;

        public static DEVMODE Create() => new()
        {
            dmDeviceName = string.Empty,
            dmFormName = string.Empty,
            dmSize = (ushort)Marshal.SizeOf<DEVMODE>()
        };
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplayDevices(string? device, uint index, ref DISPLAY_DEVICE displayDevice, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplaySettingsEx(string deviceName, int modeNum, ref DEVMODE devMode, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int ChangeDisplaySettingsEx(string? deviceName, ref DEVMODE devMode, IntPtr hwnd, uint flags, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")]
    private static extern int ChangeDisplaySettingsEx(string? deviceName, IntPtr devMode, IntPtr hwnd, uint flags, IntPtr lParam);
}
