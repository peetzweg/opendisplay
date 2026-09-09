# Issue #9 — Resolution & Quality Settings: Design

Status: proposed | Depends on: #26 (done), #116 (done) | Constrained by: #29 (OPEN, unresolved), #25 (findings)
Audience: contributor implementing #9. Read #25 and #29 fully first — this doc assumes them.

---

## 1. The bug (your pain)

Changing the display resolution in System Settings → Displays (e.g. picking "More Space" / a scaled mode) reverts to default within ~2s.

Root cause: `Mac/VirtualDisplay.swift` publishes ONE mode and runs a lifetime enforcement loop that re-asserts that single `@2x` mode every 2s. Any mode that isn't it → forced back.

```swift
settings.modes = [ CGVirtualDisplayMode(width: pointsWide, height: pointsHigh, refreshRate: 60) ]  // only one

// loop, every 2s:
if current.width != hidpi.width || current.pixelWidth != hidpi.pixelWidth {
    CGConfigureDisplayWithDisplayMode(..., hidpi, ...)   // revert to default
}
```

## 2. Why you CANNOT just delete enforcement (#29 is the trap)

The enforcement loop was added in #26 to fix REAL bugs, documented in #29:

- macOS **asynchronously restores stale saved modes** seconds after display creation.
- Those relapses manifest as:
  - **1x mode** → blurry (instead of @2x HiDPI)
  - **wrong-orientation mode** → framebuffer pillarboxed into the stream (bars on device after rotation)

#29 explicitly says: *"Mode enforcement itself fixed real bugs… Keep it; tame its recovery path."*

So "not @2x" is ambiguous:
- a USER-picked scaled mode we published → must be LEFT ALONE (the fix)
- a macOS 1x / wrong-orientation relapse → must be RE-ASSERTED (don't regress #29)

The fix is **discrimination**, not removal.

## 3. Design

### 3.1 Publish multiple modes (the heart of #9)

In `VirtualDisplay`, build a mode list instead of one:

- `native` = `(pointsWide × pointsHigh)` @2x (the current default)
- `scaled` variants = downscaled HiDPI modes, e.g. 0.85×, 0.75×, 0.67× of native points, each still @2x framebuffer where possible. These map to System Settings' "More Space" options.
- Keep `hiDPI = 1`.

```swift
static func buildModes(pointsWide: Int, pointsHigh: Int) -> [CGVirtualDisplayMode] {
    let steps: [CGFloat] = [1.0, 0.85, 0.75, 0.67]
    return steps.map { s in
        CGVirtualDisplayMode(width: UInt(CGFloat(pointsWide) * s).rounded(),
                             height: UInt(CGFloat(pointsHigh) * s).rounded(),
                             refreshRate: 60)
    }
}
settings.modes = Self.buildModes(pointsWide: pointsWide, pointsHigh: pointsHigh)
```

### 3.2 Discriminating enforcement (replaces the blind revert)

Extract the decision into a pure, testable predicate:

```swift
/// True => re-assert our published mode this tick.
/// - bad state: current mode not in our published set
///   (covers macOS 1x relapse + wrong-orientation restore → #29 protection)
/// - good state: current mode IS one we published → leave it (fixes the revert bug)
func shouldReassert(current: CGDisplayMode,
                    published: [CGVirtualDisplayMode],
                    settled: Bool,
                    missingTicks: Int) -> Bool
```

Rules:
1. `current ∈ published` → **false** (user choice stands). This is the bug fix.
2. `current ∉ published` AND `!settled` → **true** (startup race, still settling).
3. `current ∉ published` AND `settled` → only **true** after the @2x mode has been
   missing for N consecutive ticks (N=3 ≈ 6s, per #29 fix-plan point 2). Transient
   wipes during a neighbor's reconfiguration heal on their own — don't fire.
4. recovery republish (`display.apply(settings)`) only when rule 3 triggers.

This preserves #26/#29 protection (1x/pillarbox relapses still caught) while letting
legitimate scaled modes stick.

### 3.3 Persist per-device choice (#9 "persist per device")

Key by the install id already threaded through #26 (#116 arrangement memory uses the same key).

```swift
// UserDefaults key: "resolution.<deviceId>"
// store the chosen mode index/identity
DisplayResolution.save(mode: chosen, device: arrangementKey)
DisplayResolution.load(device: arrangementKey)  // nil if never set
```

On `setupExtend`, after creating the display, if a saved mode exists and is in the published set, select it (instead of always forcing native). On user change in System Settings (detected via the existing origin/arrangement observation path or a display-config notification), persist the new choice.

### 3.4 Optional UI (nice-to-have, ties to #9's "respect user's choice")

System Settings → Displays already lets the user pick a published mode at runtime; the enforcement change makes that real. A Mac-app picker is optional sugar — #9 lists it but the runtime fix is the core. Defer UI unless owner wants it.

## 4. DO NOT regress #29 (critical)

- The enforcement recovery (`display.apply(settings)`) generates display-reconfiguration events. After 3.2, it only fires on genuine bad states, so it stops amplifying the rebuild loop.
- `scheduleCaptureRecovery` (MacSender ~line 483) STILL does a full `reconfigure(hello)` (destroy+create) on stream death — #29 is unfixed. Do NOT add any new display destroy/create here. If you touch recovery, follow #29 fix-plan point 1 (re-attach to existing display, don't rebuild) — but that's #29's scope, not #9's. Keep #9 focused.
- Re-assertion must use `.permanently` for mode (like today) — not session-scoped — so the choice survives.

## 5. Verification (no iPad required)

Tier 1 — pure logic (no display):
- `buildModes` returns N>1 modes, native first.
- `shouldReassert`:
  - current=native, settled → false
  - current=scaled(published), settled → **false**  ← proves revert bug fixed
  - current=1x(not published), !settled → true
  - current=1x, settled, missingTicks<3 → false (debounce)
  - current=1x, settled, missingTicks>=3 → true (recover)
- persistence round-trip (save/load keyed by device id).

Tier 2 — headless VirtualDisplay on YOUR Mac (no iPhone needed):
- Create display with multiple modes.
- Assert `CGDisplayCopyAllDisplayModes` returns >1 mode (proves modes published).
- Select a scaled mode, run one enforcement tick, assert NOT reverted to native.
- Simulate 1x (configure to a 1x mode not in set), run ≥3 ticks, assert re-asserted to @2x (proves #29 protection intact).
- Tear down.
- ⚠️ Must run on a logged-in GUI session (WindowServer). Xcode or a signed CLI on desktop.

Tier 3 — visual (needs your iPhone):
- Build → connect iPhone → System Settings → Displays → pick scaled mode → confirm it stays across 10s + disconnect/reconnect.

## 6. PR shape (repo conventions)

- Branch `feat/mac-resolution-settings` (or `fix/mac-respect-display-resolution`).
- Conventional commits: `feat(mac): publish multiple display modes and respect user choice`, `test(mac): predicate for mode re-assertion`, `fix(mac): persist per-device resolution`.
- Reference #9 and #29 in the PR body.
- External PRs ARE accepted (see open PRs from gcobc12677, ayufan, lotgood…). No CLA, GPL-3.0.

## 7. Open questions for the owner

- Exact scaled-step list (0.85/0.75/0.67 vs Apple's "More Space" presets)?
- UI picker yes/no, or System Settings only?
- Should per-device resolution auto-drop when device count hits the #25 encoder ceiling (lever #2)? Out of scope for v1, note as follow-up.
