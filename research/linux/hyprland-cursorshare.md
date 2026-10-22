# Draft upstream report: cursor capture session always copies an empty sprite

Status: **draft, not filed.** Whether and where to file (issue vs.
discussion, per Hyprland's bug template) is the maintainer's call. Written
2026-10-20 from the v0.56.2 sources and a nested-Hyprland run with
`od-sender dev cursor-test --save-raw`.

---

**Title:** ext-image-copy-capture cursor session never contains the cursor
image (copies are always clear, or black when the pointer is elsewhere)

### Hyprland version

0.56.2 (`efb50993`), aquamarine 0.15.1, Arch Linux aarch64 (Asahi). The code
below is unchanged on `main` as of 2026-10-20.

### What's the bug?

A client that captures the pointer through
`ext_image_copy_capture_manager_v1.create_pointer_cursor_session` →
`ext_image_copy_capture_cursor_session_v1.get_capture_session` gets correct
`enter`/`leave`/`position`/`hotspot` events, and the image session advertises
sensible constraints (here `buffer_size` 24x24, `shm_format` ARGB8888). But
every frame it captures is either:

* fully transparent (all bytes zero) when the pointer is over the captured
  output, or
* opaque black (every pixel `00 00 00 ff`) when it is not,

never the cursor image. This happens with theme cursors (xcursor/hyprcursor)
and with client-set cursor surfaces.

### How to reproduce

1. Start any client that opens a pointer cursor session for an output and
   captures one frame into a shm buffer of the advertised size and format
   while the pointer is over that output. With OpenDisplay's sender:
   ```sh
   od-sender dev cursor-test --output <output> --seconds 10 \
     --save /tmp/cursor.png --save-raw /tmp/cursor-raw
   ```
   and move the pointer onto `<output>`.
2. Inspect the frame: `xxd /tmp/cursor-raw/frame-2.raw | head`. All bytes
   are zero. The first frame of a session opened while the pointer is on
   another output is all `00 00 00 ff`.

Log of that run (pointer started on another output, then moved over the
captured one; the second session is opened by the tool once the pointer
is over the output, which makes Hyprland copy at once):

```
session: SessionOpened { reason: "start" }
session: Constraints { size: (24, 24), formats: ["Value(Argb8888)"] }
session: Ready { hotspot: (0, 0), kind: Placeholder }      # all 00 00 00 ff
session: SessionOpened { reason: "refresh sprite" }
session: Ready { hotspot: (3, 1), kind: Clear }            # all zero
```

### Cause

`src/managers/screenshare/CursorshareSession.cpp`, `CCursorshareSession::render()`
(lines 115-142 in v0.56.2):

```cpp
if (PERM != PERMISSION_RULE_ALLOW_MODE_ALLOW || !overlaps) {
    // render black when not allowed
    g_pHyprRenderer->draw(CClearPassElement::SClearData{Colors::BLACK});
} else if (!cursorImage.pBuffer || !cursorImage.surface || !cursorImage.bufferTex) {
    // render clear when cursor is probably hidden
    g_pHyprRenderer->draw(CClearPassElement::SClearData{{0, 0, 0, 0}});
} else {
    // render cursor
    g_pHyprRenderer->draw(CTexPassElement::SRenderData{.tex = cursorImage.bufferTex, ...});
}
```

The cursor branch requires `pBuffer` **and** `surface` **and** `bufferTex`,
but `CPointerManager` never holds a buffer and a surface at the same time
(`src/pointer/PointerManager.cpp`):

* `setCursorBuffer()` (line 127, theme cursors) calls `resetCursorImage()`
  and sets only `pBuffer`;
* `setCursorSurface()` (line 156, client cursors) calls `resetCursorImage()`
  and sets only `surface`;
* `resetCursorImage()` (line 241) clears the surface if there is one,
  otherwise the buffer;
* `bufferTex` is created lazily only by `getCurrentCursorTexture()` (line 950).

So the middle branch is always taken. Related: `calculateConstraints()`
(line 50) returns early without a `pBuffer`, so a client-set cursor surface
never gets constraints of its own.

### Suggested fix

Draw whatever texture the pointer manager would use for the hardware or
software cursor:

```cpp
} else if (const auto TEX = Pointer::mgr()->getCurrentCursorTexture(); !TEX) {
    g_pHyprRenderer->draw(CClearPassElement::SClearData{{0, 0, 0, 0}});
} else {
    g_pHyprRenderer->draw(CTexPassElement::SRenderData{.tex = TEX, .box = {{}, TEX->m_size}});
}
```

and take `calculateConstraints()`'s size and format from the surface's
current buffer when there is no `pBuffer`.

Two smaller points the same run showed, worth mentioning in the report:

* The first frame of a session is copied immediately (`m_constraintsChanged`
  starts true); later frames only on `cursorChanged`. A session opened while
  the pointer is elsewhere therefore keeps a black placeholder until the
  cursor *image* changes, even after the pointer enters. Copying again on
  `enter` would avoid it.
* `position` and `hotspot` are sent in logical (layout) units
  (`CImageCopyCaptureCursorSession::sendCursorEvents`:
  `Pointer::mgr()->position() - sourceBox.pos()` with the logical box), but
  the protocol defines `position` in the main buffer's pixels and `hotspot`
  in the cursor buffer's. On a scale-2 output a client sees half the
  expected coordinates.

### Not in this report, but related

On 0.56.2 a cursor capture frame left pending when its output is removed
crashes Hyprland on the next cursor change. That is fixed on `main` by
8010b4e5c ("screenshare: fix crash in cursor capture after monitor removal",
#16533), so nothing to file. A 0.56.x point release with that fix would help.

### What OpenDisplay does meanwhile

`od-sender` does not use cursor sessions on Hyprland (the backend reports no
cursor metadata) and keeps the cursor painted into the video
(`linux/cursor`, ee4c5ef).
