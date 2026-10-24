# GNOME backend: Mutter's D-Bus APIs, not the portal

Status: spike done 2026-10-20, branch `linux/portal-backend`. Verified on a
headless Mutter 51.1 (Arch Linux ARM packages, unpacked, isolated; see
`linux/testbench/gnome-smoke.sh`). Not yet run on a real GNOME session or
against a real receiver.

## Recommendation

Use Mutter's private `org.gnome.Mutter.ScreenCast` + `org.gnome.Mutter.RemoteDesktop`
APIs (what gnome-remote-desktop uses) for the GNOME backend. Keep the
xdg-desktop-portal route for later, for sandboxed builds (Flatpak) only.

| | Mutter D-Bus (implemented) | Portal (ScreenCast `VIRTUAL` + RemoteDesktop) |
|---|---|---|
| Dialog | none for an unsandboxed process | GNOME's chooser on first use: the user must pick "Virtual Monitor" (and allow input); a restore token (`persist_mode` 2) skips it afterwards |
| Size | `RecordVirtual` `modes` (size, refresh, preferred) since Mutter 50; before that the PipeWire format the consumer negotiates sizes the monitor | from the PipeWire format the consumer negotiates (xdp-gnome passes no `modes`) |
| Scale | Mutter picks (1.0 on the bench); a PipeWire stream tag `org.gnome.preferred-scale` sets it (not done yet) | same |
| Input | RemoteDesktop session linked to the stream: absolute motion in stream pixels, buttons, smooth axis | the same Mutter calls behind the RemoteDesktop portal |
| Lifetime | Mutter removes the monitor when the session stops or our bus connection closes (also on `kill -9`): nothing to clean | same, via the portal session |
| Sandbox | needs the real session bus: not from Flatpak | works from Flatpak |
| Stability | private API ("may change"); version property is 4 from Mutter 44 to 51 | public, stable |
| Automated test | yes (headless Mutter, no UI) | no: the first run needs a click in the chooser |

## Facts (from source, Mutter `main` 2026-10-20 and tags)

* Access: `MetaDbusAccessChecker` guards only the a11y manager. ScreenCast and
  RemoteDesktop sessions check only that later calls come from the creating
  connection (`check_permission` compares the sender with `peer_name`).
* `RecordVirtual` properties: `cursor-mode` (0 hidden, 1 embedded, 2
  metadata), `is-platform` (treat as a real monitor, not "screen shared"),
  `modes` (`aa{sv}`: `size (uu)`, `refresh-rate d`, `is-preferred b`; exactly
  one preferred). `modes` is in the D-Bus XML from 50.0 on, not in 49.0.
  Older Mutter ignores unknown keys, so passing `modes` is always safe.
* Without `modes`, `MetaStreamSourceVirtual::notify_params_updated` creates
  (or re-modes) the virtual monitor from the negotiated
  `spa_video_info_raw.size` and `max_framerate`. The consumer therefore
  offers the wanted size as its preferred `VideoSize`.
* `PipeWireStreamAdded(u node_id)` on the stream after
  `RemoteDesktop.Session.Start`. The node lives on the session's PipeWire
  daemon (no remote fd needed).
* `NotifyPointerMotionAbsolute(s stream, d x, d y)`: the stream path is a
  string, coordinates in stream pixels. `NotifyPointerAxis(d dx, d dy, u
  flags)`: 10.0 is one wheel detent; flags 1 finish, 2 wheel, 4 finger, 8
  continuous. `Version` properties are `i`, not `u`.
* The xdg-desktop-portal-gnome chooser shows a "Virtual Monitor" entry
  when `VIRTUAL` is requested; its restore data records the choice.

## What the backend does

`backend/gnome/`: RemoteDesktop.CreateSession, then ScreenCast.CreateSession
linked by `remote-desktop-session-id`, then RecordVirtual with
`{cursor-mode: embedded, is-platform: true, modes: [WxH@Hz]}`, then Start. It
waits for PipeWireStreamAdded and finds the new connector in
`DisplayConfig.GetCurrentState` (mode, position, scale). Frames come from
`src/pipewire.rs` (shared with KDE), input goes through RemoteDesktop on its
own thread. A new size is a new monitor (a `modes` stream has a fixed size).
Detection: `XDG_CURRENT_DESKTOP` containing `GNOME` (also `ubuntu:GNOME`),
or `--backend gnome`; the D-Bus probe runs when the backend starts and
`doctor` prints the API versions.

## Open

* Run on a real GNOME 50/51 session with an iPhone; check the top-bar
  screen-sharing indicator with `is-platform` true.
* Scale: set `org.gnome.preferred-scale` on the stream (PipeWire tag param)
  from `DisplaySpec.scale`; until then Mutter's default applies.
* Cursor: `cursor-mode` metadata gives the cursor side channel its sprite
  and position for free (PipeWire `SPA_META_Cursor`); `--cursor off` should
  map to hidden.
* Mutter < 50 is untested (no `modes`; size via negotiation).
* Portal backend for Flatpak: the same PipeWire source with the portal's
  `OpenPipeWireRemote` fd (`PwSource.remote_fd`, untested).
