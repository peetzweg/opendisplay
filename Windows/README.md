# OpenDisplay for Windows

This directory models the Windows sender app corresponding to `Mac/`. It is a
.NET 8 WPF application written in C#. It connects to the existing iOS and
Android receivers and uses the same OpenDisplay wire protocol.

The project has not yet been compiled or exercised on Windows. The code is
deliberately split at platform boundaries so each piece can be validated and
replaced independently when a Windows development machine is available.

## Architecture

```text
iPhone / iPad / Android receiver
  advertises _opensidecar._tcp and listens on TCP :9000
                         |
                         | hello, touch, scroll, ping (framed JSON)
                         | H.264 Annex B access units (framed binary)
                         v
OpenDisplay.Windows (WPF / C#)
  ReceiverDiscovery       dependency-free mDNS discovery
  AdbDeviceWatcher        Android USB discovery and per-device forwarding
  StreamingSession        connection, protocol, lifecycle, stats
  WindowsInputInjector    normalized touch -> SendInput / SetCursorPos
  FfmpegCaptureEncoder    monitor capture -> h264_mf -> Annex B
                         |
                         v
VirtualDrivers/Virtual-Display-Driver (VDD / IddCx / UMDF 2)
  creates the real extended Windows monitor captured by the app
```

Mirror mode captures the primary physical monitor and does not require VDD.
Extend mode claims an active VDD monitor, changes it to the receiver's native
pixel dimensions, and captures that monitor.

## Prerequisites

You need the following on the Windows sender PC:

1. **Windows 10 build 19041 or newer.** Windows 11 is the primary target.
2. **The OpenDisplay receiver app** open in the foreground on an iPhone, iPad,
   or Android device. The receiver listens on TCP port `9000`.
3. **.NET 8.** Install the
   [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) to build the
   project. A packaged release will only need the .NET Desktop Runtime, unless
   it is published self-contained.
4. **FFmpeg** with all three of these components:
   `gdigrab`, the Media Foundation `h264_mf` encoder, and the `h264_metadata`
   bitstream filter. Put `ffmpeg.exe` beside `OpenDisplay.exe`, put it on
   `PATH`, or set `OPENDISPLAY_FFMPEG` to its full path.
5. **Virtual Display Driver for Extend mode.** Install a signed release of
   [VirtualDrivers/Virtual-Display-Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver).
   Mirror mode does not need VDD.
6. **Android Platform Tools for Android USB.** `adb.exe` is optional for WiFi
   and manual connections. OpenDisplay searches `ANDROID_SDK_ROOT`,
   `ANDROID_HOME`, `%LOCALAPPDATA%\Android\Sdk\platform-tools`, and `PATH`.

Check the FFmpeg features from PowerShell:

```powershell
ffmpeg -hide_banner -devices | Select-String gdigrab
ffmpeg -hide_banner -encoders | Select-String h264_mf
ffmpeg -hide_banner -bsfs | Select-String h264_metadata
```

The Windows Firewall may ask whether OpenDisplay can use private networks.
Allow private-network access for WiFi discovery and streaming. Manual and ADB
connections do not depend on multicast discovery, but the TCP connection must
still be permitted.

The VDD project is not vendored here. It is an independent MIT-licensed
dependency and has its own installer and update lifecycle.

## Configure VDD

VDD reads its monitor count and available modes from:

```text
C:\VirtualDisplayDriver\vdd_settings.xml
```

Configure at least one monitor. Add the native landscape and portrait modes
used by each receiver, for example:

```xml
<monitors>
  <count>2</count>
</monitors>
<resolutions>
  <resolution>
    <width>2732</width>
    <height>2048</height>
    <refresh_rate>60</refresh_rate>
  </resolution>
  <resolution>
    <width>2048</width>
    <height>2732</height>
    <refresh_rate>60</refresh_rate>
  </resolution>
</resolutions>
```

Restart the VDD device after changing its XML, then set its outputs to
"Extend these displays" in Windows Display Settings. OpenDisplay does not
currently edit VDD configuration or change its persistent monitor count.

This is intentional. The current upstream driver exposes
`\\.\pipe\MTTVirtualDisplayPipe` and accepts `SETDISPLAYCOUNT N`, but its reload
path reinitializes the adapter globally. Doing that when a stream starts could
rearrange every desktop and interfere with other software using VDD.

Configure one active VDD monitor for every concurrent receiver using Extend
mode. Two connected tablets require `<count>2</count>`. A Mirror session does
not consume a VDD monitor.

## Connect a receiver

Closing or minimizing the control window hides OpenDisplay to the Windows
notification area without stopping active sessions. Click or double-click the
tray icon to restore the window. Use **Exit** in the tray menu to stop sessions
and quit the application completely. Only one OpenDisplay instance runs at a
time; launching it again restores the existing window, including when it is
hidden in the notification area.

The Windows executable, control window, and notification-area icon reuse the
macOS application artwork from `Mac/Assets.xcassets/AppIcon.appiconset`.

### WiFi / automatic discovery

1. Put the Windows PC and receiver on the same local network.
2. Open the OpenDisplay receiver app and keep it in the foreground.
3. Start the Windows app. The device should appear with a `WiFi` label.
4. Select Mirror or Extend, choose a quality preset, and click **Connect**.

Discovery uses `_opensidecar._tcp.local` multicast DNS. Guest networks, VPNs,
and enterprise WiFi can filter multicast; use Manual mode in that case.
The Windows sender joins `224.0.0.251:5353` and sends its query on every active
IPv4 LAN interface rather than relying on Windows' default route.

If discovery is empty, expand **Diagnostics** after pressing **Refresh** and
inspect the `mDNS` line:

- `packets=0` means no multicast responses reached the app. Allow OpenDisplay
  through Windows Firewall on Private networks, temporarily disable VPNs, and
  confirm both devices are on the same non-guest LAN.
- A growing packet count with no OpenDisplay receiver usually means the
  receiver is not advertising `_opensidecar._tcp`. Keep the receiver app open
  in the foreground and grant its Local Network permission.
- The `interfaces=` list should contain the PC address on the receiver's
  subnet. For a receiver at `192.168.88.249`, expect a PC interface beginning
  with `192.168.88.`.

Manual connection remains a useful independent test: if
`192.168.88.249:9000` works while mDNS stays empty, capture and streaming are
fine and only multicast discovery is blocked.

### Android over USB / ADB

1. Install Android Platform Tools, or install Android Studio so `adb.exe` is in
   its standard SDK location.
2. On Android, enable Developer options and **USB debugging**.
3. Connect the device by USB and approve the PC's debugging key on the device.
4. Open the OpenDisplay Android receiver.

OpenDisplay runs `adb devices -l` every two seconds. Each authorized device
gets its own dynamically allocated forwarding rule equivalent to:

```powershell
adb -s DEVICE_SERIAL forward tcp:0 tcp:9000
```

The allocated loopback endpoint appears with an `ADB` label. Select it and
click **Start sharing** to connect; detecting or plugging in an ADB device never
starts a session automatically. Unauthorized and offline devices remain visible
with an actionable status instead of silently disappearing. App-owned
forwarding rules are removed when OpenDisplay exits; ADB also removes them when
the device disconnects.

ADB device serials are associated with the receiver's installation ID after
the first `hello`. If the same Android device is also discovered over WiFi,
OpenDisplay prefers the cable and suppresses or closes the WiFi duplicate.

For a portable development build, `adb.exe` may also be placed beside
`OpenDisplay.exe`; its companion Platform Tools DLLs must remain beside it.

### Manual host or IP address

Use the Manual address field when multicast discovery is unavailable. Accepted
formats are:

```text
192.168.1.42          # defaults to port 9000
tablet.local:9000
[2001:db8::42]:9000
2001:db8::42          # bare IPv6, defaults to port 9000
```

Press Enter or click the Manual **Connect** button. Successfully submitted
addresses are remembered but never auto-connected, because a stale address
would otherwise retry indefinitely. Select a remembered Manual entry and use
**Forget** to remove it.

Manual mode is plain TCP. It is not the same as Android USB forwarding and it
does not provide encryption or pairing.

## Install dependencies and build on Windows

This is a native Windows-only workflow. The project targets `net8.0-windows`
and WPF, and release artifacts should be built and run on Windows.

Windows 10 and Windows 11 include WinGet through Microsoft's App Installer.
Open Command Prompt or PowerShell and run:

```bat
cd Windows
scripts\deps.bat
```

`deps.bat` installs or confirms these exact WinGet packages:

| Purpose | WinGet package |
|---|---|
| Compile the WPF app | `Microsoft.DotNet.SDK.8` |
| FFmpeg capture and H.264 Media Foundation encoding | `Gyan.FFmpeg` |
| Android USB / ADB | `Google.PlatformTools` |
| VDD native runtime dependency | `Microsoft.VCRedist.2015+.x64` |
| True extended virtual monitor | `VirtualDrivers.Virtual-Display-Driver` |

WinGet may show a UAC prompt for machine-wide dependencies and the display
driver. After installation, close and reopen the terminal so updated `PATH`
entries for `dotnet`, `ffmpeg`, and `adb` are visible.

Build a Release or Debug configuration:

```bat
cd Windows
scripts\build.bat Release
scripts\build.bat Debug
```

`Release` is the default when the argument is omitted. Output is written to
`Windows\build\Release` or `Windows\build\Debug`.

`Windows\global.json` pins SDK selection to the latest installed stable .NET 8
feature band. This prevents a .NET 9/10 preview SDK from taking over the WPF
build. If `dotnet --version` still prints a preview version, confirm that the
command is being run through `scripts\build.bat` and that
`Microsoft.DotNet.SDK.8` installed successfully.

After a successful build:

```bat
build\Release\OpenDisplay.exe
```

To use a non-standard .NET installation:

```bat
set DOTNET=C:\Tools\dotnet\dotnet.exe
scripts\build.bat Release
```

### Direct `dotnet` commands

The scripts are equivalent to:

```powershell
cd Windows
dotnet restore OpenDisplay.Windows.csproj -p:EnableWindowsTargeting=true
dotnet build OpenDisplay.Windows.csproj --no-restore --configuration Release -p:EnableWindowsTargeting=true
```

If restore reports `NETSDK1100`, confirm that `EnableWindowsTargeting` remains
enabled in the project and command line. If it reports `NU1301`, allow access
to NuGet or configure the required targeting packs in your offline package
source.

The project disables all implicit source, resource, and WPF item globs and
explicitly lists its C# and XAML inputs. This avoids literal-wildcard failures
such as `BG1002: File '**/*.xaml' cannot be found` and
`MSB3552: Resource file '**/*.resx' cannot be found`, which can occur on some
preview SDK or mapped/network-drive configurations.

## Diagnostics and crash logs

OpenDisplay writes a timestamped log as soon as the process starts. It first
tries to create the file beside the executable:

```text
<OpenDisplay.exe directory>\OpenDisplay.log
```

If that directory is read-only, such as under `Program Files`, it falls back
to:

```text
%LOCALAPPDATA%\OpenDisplay\OpenDisplay.log
```

The log rotates to `OpenDisplay.log.1` at 5 MiB. The app's **Diagnostics**
expander shows the actual path and has an **Open log location** button.

The diagnostics report checks:

- .NET runtime, Windows version, architecture, and application directory;
- the resolved `ffmpeg.exe` path;
- FFmpeg's `gdigrab`, `h264_mf`, and `h264_metadata` capabilities;
- active Windows displays and active VDD outputs;
- the `MTTVirtualDisplayPipe` VDD control channel;
- the optional ADB executable used for Android USB.

FFmpeg stderr and its exit code are preserved in the log and surfaced in the
session status instead of being discarded. Unexpected UI, task, startup, and
process exceptions are also logged. A fatal-error dialog includes the log path
before the application closes.

When reporting a crash, include `OpenDisplay.log`, the expanded Diagnostics
text, the selected Mirror/Extend mode, and whether the receiver used WiFi, ADB,
or a manual address. Screen contents are not written to the log.

Recommended first validation sequence:

1. Build with nullable warnings enabled and fix any Windows SDK projection or
   P/Invoke layout issues found by the compiler.
2. Start in Mirror mode with the receiver on WiFi.
3. Verify mDNS discovery and manual IPv4, DNS, and IPv6 parsing.
4. Verify authorized, unauthorized, offline, attach, detach, and multiple-device
   ADB behavior, including forward cleanup on exit.
5. Validate H.264 compatibility with both iOS and Android receivers.
6. Install VDD, add the exact receiver resolutions, then test Extend mode.
7. Measure capture, encode, network, decode, and input latency.

## What is implemented

- WPF control window with receiver, mode, quality, and multi-session UI
- `_opensidecar._tcp.local` multicast-DNS discovery without a NuGet dependency
- Manual IPv4, DNS, bracketed IPv6, and bare IPv6 targets, with persistence
- Android ADB discovery, device-state UI, per-device dynamic port forwarding,
  automatic wired connection, cleanup, and WiFi deduplication
- Existing four-byte big-endian OpenDisplay framing
- Receiver `hello`, touch, scroll, keyframe, and ping/pong handling
- VDD named-pipe probe using the upstream pipe and UTF-16 command format
- Detection and reservation of active VDD monitor outputs
- Display mode selection through `ChangeDisplaySettingsEx`
- Primary-monitor mirror target
- FFmpeg `gdigrab` capture and Media Foundation `h264_mf` encoding
- H.264 access-unit parsing using inserted AUD NAL units
- Windows mouse injection using `SetCursorPos` and `SendInput`
- Best / Balanced / Fast stream scaling and bitrate presets matching the Mac app

## Known limitations / next implementation steps

- The project has not been compiled on Windows yet.
- The FFmpeg backend is the fastest way to validate the full product, but it is
  not the final low-latency architecture. Replace it behind the same session
  boundary with Windows.Graphics.Capture or Desktop Duplication plus an
  in-process Media Foundation encoder.
- `gdigrab` behavior for monitors positioned at negative desktop coordinates
  must be tested. Windows.Graphics.Capture avoids that limitation.
- A keyframe request currently restarts FFmpeg. The native encoder should force
  an IDR without rebuilding capture.
- Receiver orientation changes require restarting the session after the VDD
  portrait/landscape mode has been configured. Live target switching is still
  to be added.
- VDD outputs are persistent, user-managed displays. Disconnecting an
  OpenDisplay session releases the output inside the app but does not remove or
  disable it in Windows.
- Android USB works through ADB. iPhone/iPad USB is not implemented on Windows;
  it requires a Windows-supported usbmux client and Apple device drivers.
- Cursor is currently captured in the video. A native backend should exclude
  it and send `cursor` / `cursorImg` controls like the Mac app for lower
  perceived pointer latency.
- Pairing and transport encryption remain protocol-wide future work.

## Why VDD is separate

Windows only treats a software monitor as a true extended display when an
Indirect Display Driver reports it through IddCx. That driver is a native WDK
UMDF component; a C# desktop app alone cannot create an equivalent monitor.
VDD already provides the signed IddCx layer, while OpenDisplay supplies the
receiver-aware transport and interaction layer.

See [Driver/VirtualDisplayDriver.md](Driver/VirtualDisplayDriver.md) for the
source-level integration notes.
