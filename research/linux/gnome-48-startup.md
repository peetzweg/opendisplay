# GNOME 48 virtual monitor startup (v1.30.2 investigation)

## Evidence and diagnosis

The checkout was clean at `v1.30.2`. The original error is at
`linux/crates/od-sender/src/backend/gnome/mutter.rs:345` in that tag.

Original ordering:

1. Read DisplayConfig connectors (baseline).
2. Create RemoteDesktop session; read its string SessionId.
3. Create ScreenCast session with remote-desktop-session-id.
4. RecordVirtual with cursor-mode (u), is-platform (b), modes (aa{sv}).
5. Subscribe to PipeWireStreamAdded **before** starting RemoteDesktop.
6. Receive PipeWire node ID; poll GetCurrentState 20 times, 50 ms apart.
7. Only after monitor detection and arrangement, start the PipeWire consumer
   in GnomeDisplay::start_capture.

Mutter 48.7 creates the virtual monitor in
`meta_screen_cast_virtual_stream_src_notify_params_updated` ->
`ensure_virtual_monitor` -> `create_virtual_monitor`. Its width, height and
refresh rate come from the negotiated SPA video format. Consequently step 6
cannot complete on this path until step 7 has happened. Node announcement
means the PipeWire node exists, not that a monitor exists. A longer monitor
wait alone cannot fix this dependency cycle.

Primary sources (version pinned):

- https://github.com/GNOME/mutter/blob/48.7/src/backends/meta-screen-cast-virtual-stream-src.c#L535-L613
- https://github.com/GNOME/mutter/blob/48.7/data/dbus-interfaces/org.gnome.Mutter.ScreenCast.xml

GNOME 48's XML supports the linked sessions, RecordVirtual, cursor-mode,
is-platform and PipeWireStreamAdded used here. It has no `modes` property;
that hint cannot create a fixed-size monitor on 48. The supplied trace shows
RecordVirtual accepting the request. The private API promises no cross-version
compatibility; its Version property is not a sufficient modes-capability test.

The detector compares connector names with the baseline; it does **not**
require a `Meta-` prefix, a particular vendor/product, or a stream Parameters
`output-name` (the XML only guarantees that key for monitor streams).
Placement needs a mode with `is-current=true`; if no logical monitor matches,
existing placement code defaults to (0,0), scale 1. No MonitorsChanged signal is
used, so missing that signal is not the direct cause. After an error, Drop
stops RemoteDesktop and removes its monitor; observing only eDP-1 after exit
cannot distinguish failure to create from cleanup after creation.

A concurrent hotplug can still make connector-difference attribution ambiguous.
This patch does not claim to solve stream-to-connector attribution generally.

## Change

Connect the consumer immediately after PipeWireStreamAdded, before polling
DisplayConfig. Retain that same consumer through arrangement and delivery;
start/stop_capture attach/detach the frame sink. This avoids a second negotiation
when delivery starts. Discard early frames, retain early stream errors, and
release capture before stopping the Mutter session on close/reconfigure/error.

Use a 5-second monitor deadline after connecting, with diagnostics containing
node, state serial, baseline/new connectors, modes and logical monitors.
Check all new connectors for a current mode (an inactive first connector must
not hide an active subsequent connector).

## Validation and real-session procedure

Do not install over ~/.local/bin/od-sender. From the repository root:

```sh
cargo fmt --manifest-path linux/Cargo.toml --all -- --check
git diff --check
cargo build --manifest-path linux/Cargo.toml --locked -p od-sender --target-dir build/gnome-48-fix
cargo test --manifest-path linux/Cargo.toml --locked -p od-sender --target-dir build/gnome-48-fix
```

Build/test require the existing project's native development dependencies
(including PipeWire, FFmpeg and libclang). The first attempts stopped at
missing libpipewire-0.3.pc. A subsequent build succeeded using Debian development
packages downloaded and extracted into `build/gnome-deps/root`, with local
pkg-config paths and libclang headers. No system packages were installed or
changed. `build/gnome-deps/env.sh` contains the local build environment.

The complete default-feature sender build passed. Output:
`build/gnome-48-fix/debug/od-sender` (`od-sender 1.30.2`). Runtime library
resolution, `--version` and `run --help` passed without the build environment.
The original ~/.local/bin/od-sender SHA-256 remained
`c0686fe3d01bccc6be01119f7de55a69cdd0645bf1afa6bcb9f35c09d62bd2ac`.

All **156 sender tests passed** using a writable private XDG_RUNTIME_DIR.
Initial tests using /run/user/1000 failed because the sandbox makes that path
read-only. Reproduce the successful run from the repository root:

```sh
source build/gnome-deps/env.sh
mkdir -p build/gnome-48-fix/test-runtime
chmod 700 build/gnome-48-fix/test-runtime
XDG_RUNTIME_DIR="$PWD/build/gnome-48-fix/test-runtime" \
  cargo test --offline --manifest-path linux/Cargo.toml --locked -p od-sender \
  --target-dir build/gnome-48-fix
```

Logs: `build/gnome-48-fix/build.log` and
`build/gnome-48-fix/test-local-runtime.log`.

`bash linux/testbench/gnome-api-tests.sh` also passed all 10 Mutter/layout unit
tests, including two new monitor-readiness tests. This smaller harness does not
exercise a live D-Bus service or PipeWire. Formatting and git diff checks passed.

In the GNOME user's terminal, start monitoring **before** the sender:

```sh
gdbus monitor --session --dest org.gnome.Mutter.DisplayConfig
```

In another terminal, first test without an iPad:

```sh
RUST_LOG=info,od_sender::backend::gnome=debug,od_sender::pipewire=debug \
  ./build/gnome-48-fix/debug/od-sender dev smoke --backend gnome \
  --size 2360x1640 --scale 1 --frames 30 --timeout 30
```

Expected: PipeWire node announcement, consumer state/format logs, a new
connector with a current 2360x1640 mode, virtual display info, then
`smoke ok: 30 frames captured`. MonitorsChanged should accompany creation and
removal. Repeat with --scale 2; inspect effective scale and size.

With the iPad receiver running:

```sh
RUST_LOG=info,od_sender::backend::gnome=debug,od_sender::pipewire=debug \
  ./build/gnome-48-fix/debug/od-sender run --backend gnome \
  --scale 1 --max-fps 30 --no-reconnect
```

Repeat with --scale 2. While connected, inspect GNOME Displays and move a
window onto the iPad: it must show a separate extended desktop, not a mirror.
Check pointer input and reconnection/reconfiguration, and check that the
virtual monitor disappears on exit. Native monitor settings must survive.

If it fails, distinguish these cases from logs while the session is alive:

- No negotiated `pipewire format`: inspect PipeWire state errors and linking
  policy; node announcement alone is insufficient.
- Negotiated format, but no new connector: inspect Mutter journal for
  `Failed to create virtual monitor with size ...`; this is creation failure.
- New connector, but no is-current mode: monitor exists but is inactive;
  inspect modes/logical monitors in the diagnostic, rather than treating it as
  absence of a monitor.
- New current mode/virtual display logged, but no iPad video: monitor creation
  succeeded; investigate subsequent capture/encode/transport separately.

Real GNOME 48.7 + iPad validation has not been performed in this workspace.
