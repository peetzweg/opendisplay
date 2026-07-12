# VirtualDrivers VDD integration notes

Target dependency:
[VirtualDrivers/Virtual-Display-Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)
(MIT license).

These notes are based on inspection of the upstream source in July 2026. They
record the assumptions used by `VddVirtualDisplayProvider` so a future upstream
change is easy to audit.

## Identity

- INF device name: `Virtual Display Driver`
- Hardware IDs: `Root\MttVDD` and `MttVDD`
- Manufacturer string: `MikeTheTech`
- UMDF service/DLL: `MttVDD`
- Named pipe: `\\.\pipe\MTTVirtualDisplayPipe`
- Default configuration: `C:\VirtualDisplayDriver\vdd_settings.xml`

The app recognizes active display adapters by the `Virtual Display Driver`
friendly name or `MttVDD` identity. It then retains the current `\\.\DISPLAYn`
name because that is what the Win32 display APIs accept. The deliberately
narrow match avoids accidentally leasing Parsec or another virtual adapter.

## Pipe protocol

The pipe server uses message mode, accepts one client command, then disconnects.
Commands are UTF-16LE strings. Current commands include:

```text
PING
RELOAD_DRIVER
SETDISPLAYCOUNT <integer>
GETSETTINGS
LOGGING true|false
LOG_DEBUG true|false
HARDWARECURSOR true|false
SETGPU "<friendly name>"
```

OpenDisplay sends `PING` as a presence probe. When an Extend receiver needs a
mode or output that does not yet exist, it appends the receiver's exact
width/height/refresh tuple to the settings XML and then uses `RELOAD_DRIVER`.
When an extra output is needed, it uses `SETDISPLAYCOUNT N`, which persists the
larger count and reloads VDD.

## Monitor lifecycle

At adapter initialization VDD:

1. Reads `<monitors><count>` and all configured resolution/refresh tuples.
2. Sets `IDDCX_ADAPTER_CAPS.MaxMonitorsSupported` to that count.
3. Creates one `IDDCX_MONITOR` per connector index.
4. Calls `IddCxMonitorArrival` for every created monitor.
5. Accepts an IddCx swap chain for each active output and processes its frames.

VDD generates a new monitor container GUID with `CoCreateGuid` when a monitor
is created. OpenDisplay therefore must not persist that GUID as a stable
receiver identity. Receiver identity stays in the OpenDisplay `hello.id`; VDD
outputs are leased only for the current process lifetime.

## Resolution lifecycle

VDD has no pipe command to add a mode. Modes are parsed from
`vdd_settings.xml` at adapter initialization. OpenDisplay can select a mode
already exposed to Windows with `ChangeDisplaySettingsEx`, but adding a new
receiver-native mode requires editing the XML and restarting/reloading VDD.

`SETDISPLAYCOUNT` edits the XML and invokes the global adapter reload path.
OpenDisplay uses it only before it owns a VDD output; it refuses to reload VDD
while another OpenDisplay Extend session is active because:

- it persists a product-wide setting rather than leasing one monitor;
- re-enumeration can rearrange the user's desktop;
- it can disrupt Sunshine, OBS, or another application using VDD;
- the current reload implementation should be tested against a signed release
  before an unattended app relies on it.

## Capture ownership

The VDD named pipe is a control/logging channel, not a frame channel. VDD owns
the IddCx swap chain needed to make Windows render the desktop. OpenDisplay
captures the resulting `\\.\DISPLAYn` using a standard Windows capture API (the
prototype uses FFmpeg `gdigrab`). This keeps OpenDisplay independent from VDD's
internal D3D device and swap-chain implementation.

## Future tighter integration

If seamless per-receiver hot-plug becomes necessary, prefer contributing a
small, stable lease API upstream:

```text
ACQUIRE width height refresh receiver-id -> lease-id / display identity
RELEASE lease-id
```

The driver/control service—not the WPF process—should own monitor arrival,
departure, EDID identity, and crash recovery. Until such an API exists, the
safe contract is to use user-configured persistent VDD outputs.
