# Draft: the 2026-10-06 abort in `CScreenshareFrame::transform`

Status: **draft, not filed.** Conclusion first: **already fixed on Hyprland
`main`, not in 0.56.2.** There is no new bug to report. At most, ask for a
0.56.x point release (or cite the fix if someone else hits it). The trigger
below is read from the v0.56.2 sources and the local core dump; it has not
been reproduced on purpose.

## What happened

`coredumpctl info 1183` (2026-10-06 14:44, Hyprland 0.56.2, aarch64), main
thread:

```
#2  abort (libc.so.6)
#3  Hyprland + 0x2b6aac                         <- Hyprland's crash handler
#4  linux-vdso.so.1 + 0x848                     <- signal frame
#6  Screenshare::CScreenshareFrame::transform() const
```

A fault inside `transform()` (signal delivered through the vdso trampoline)
that Hyprland's handler turned into `abort()`. At the time two `od-sender`
processes drove the same headless output: the second adopted and
reconfigured the first one's `od-…` output, and one of them removed it on
exit.

## Cause (v0.56.2)

`src/managers/screenshare/ScreenshareFrame.cpp`, lines 510-517:

```cpp
wl_output_transform CScreenshareFrame::transform() const {
    switch (m_session->m_type) {
        case SHARE_REGION:
        case SHARE_MONITOR: return m_session->monitor()->m_transform;   // no null check
        ...
```

`CScreenshareSession::monitor()` (`ScreenshareSession.cpp` 163-168) returns
`nullptr` once the session's monitor reference has expired, i.e. once the
`CMonitor` object is gone. The session itself is only *stopped* on the
monitor's `disconnect` event; it stays alive.

The caller is the `ext_image_copy_capture_frame_v1` constructor,
`src/protocols/ImageCopyCapture.cpp` 340-424, which ends with

```cpp
m_resource->sendTransform(m_frame->transform());     // line 423, unconditional
```

The constructor only returns early when the session's buffer size changed.
A stopped session with an unchanged size goes on to `sendTransform`.

So the trigger is: **a client sends `create_frame` on an output capture
session after that output's `CMonitor` has been freed**, before the client
has processed the session's `stopped` event (or while ignoring it). An
output reconfiguration alone cannot do it, because the monitor object
survives. Output removal alone usually does not either: the client has to
send `create_frame` in the window after the monitor is freed. That is
consistent with the nested runs, where `hyprctl output remove` and mode
changes under capture did not crash.

How a capture client lands in that window. The session handler's
`create_frame` (`ImageCopyCapture.cpp` 23-34) has no "stopped" check, and
`stopped` is sent to the client synchronously when the monitor disconnects.
So the exposure is a `create_frame` already in flight, or sent before the
client dispatched `stopped`:

* `od-sender`'s capture loop (`wayland/capture.rs`, `capture_shm`) sends
  `create_frame` + `capture` immediately after every `ready`. If the output
  is removed and its `CMonitor` freed while that request is in flight, the
  constructor dereferences null. The window is small, but a sender at 60-120
  fps opens it constantly.
* The same loop treats a frame `failed` with reason `stopped` like any other
  failure and creates a new frame on the next iteration, unless `stopped`
  for the session arrived in the same dispatch. Usually it does, but nothing
  guarantees it.

With two senders on one output, the sender that did not remove the output
was such a client, capturing at full rate while the other removed the output
on exit.

## Already fixed upstream

* `901881c9f` "render: always render in normal transform" (#15714,
  2026-08-04, on `main`, not on the v0.56.2 tag): `transform()` returns
  `WL_OUTPUT_TRANSFORM_NORMAL` and no longer touches the monitor.
* `212902547` "screenshare: fix potential crash on stale monitors" (#16451,
  2026-10-02, ref. discussion #16127, a sibling null `monitor()` dereference
  in `CScreenshareSession::init()`): sessions on a gone monitor are created
  stopped, and new screencopy/toplevel-export frames on a stopped session
  fail right away.

## If a report is wanted anyway

Title: "0.56.2: SIGSEGV in CScreenshareFrame::transform when a capture client
creates a frame after its output was removed (fixed on main by 901881c9f)".
Body: the version, the stack above, the two source locations, the trigger,
and a request to include 901881c9f/212902547 in a 0.56.x point release.
Minimal repro: open an `ext_image_copy_capture` session on a headless output,
`hyprctl output remove` it, wait about a second, then send `create_frame`
on the old session without processing `stopped` first.

## What OpenDisplay should do on 0.56.2 (independent of any report)

1. Never reconfigure or remove an output while any capture of it is in
   flight: already structural in `CapturedDisplay`, and the per-output lock
   keeps a second sender off it.
2. In `capture_shm`, treat a frame failing with reason `stopped` as the end
   of the session: do not create another frame. That closes the remaining
   window when *someone else* removes the output under us. A one-line change
   in `wayland/capture.rs`; not made here because `linux/zero-copy`
   (opendisplay-2) is editing that file.
