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

- Windows 10 19041 or newer (Windows 11 is the primary target)
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
- `ffmpeg.exe` with `gdigrab`, `h264_mf`, and the `h264_metadata` bitstream
  filter. Put it beside `OpenDisplay.exe`, on `PATH`, or set
  `OPENDISPLAY_FFMPEG` to its full path.
- For Extend mode, install the signed release of
  [VirtualDrivers/Virtual-Display-Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver).

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

## Build (once a Windows machine is available)

```powershell
cd Windows
dotnet restore
dotnet build OpenDisplay.Windows.csproj
dotnet run --project OpenDisplay.Windows.csproj
```

Recommended first validation sequence:

1. Build with nullable warnings enabled and fix any Windows SDK projection or
   P/Invoke layout issues found by the compiler.
2. Start in Mirror mode with the receiver on WiFi.
3. Verify mDNS discovery and manual `IP:9000` connection.
4. Validate H.264 compatibility with both iOS and Android receivers.
5. Install VDD, add the exact receiver resolutions, then test Extend mode.
6. Measure capture, encode, network, decode, and input latency.

## What is implemented

- WPF control window with receiver, mode, quality, and multi-session UI
- `_opensidecar._tcp.local` multicast-DNS discovery without a NuGet dependency
- Manual IPv4/DNS endpoint fallback
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
- USB transport is not yet implemented on Windows. WiFi and manual TCP are the
  first milestone. iOS USB would require a supported usbmux client; Android USB
  can later mirror the existing ADB port-forwarding approach.
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
