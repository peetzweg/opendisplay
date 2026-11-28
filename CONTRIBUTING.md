# Contributing to OpenDisplay

OpenDisplay is a production app. Thousands of people use it every day as part
of how they work, and most of them get updates automatically: Sparkle on the
Mac, the App Store and Google Play on their devices. A regression reaches all
of them at once, so every change, small or large, is held to the same bar.

## The bar

1. **Existing setups keep working exactly as before.** Unless the user opts in
   or a newer peer asks for it, a change must not alter resolution, codec,
   bitrate, latency, display arrangement or input behaviour for anyone. Say
   which setups you checked; "works on my device" is not enough.

2. **Mixed versions are the normal case.** Senders and receivers update on
   different schedules (see [COMPATIBILITY.md](COMPATIBILITY.md)). A new sender
   must work with every shipped receiver, and a new receiver with every shipped
   sender. Ignore unknown messages, fall back to today's behaviour when a field
   is missing, and never assume a capability a peer did not advertise. A change
   to the wire protocol updates [PROTOCOL.md](PROTOCOL.md) and COMPATIBILITY.md
   in the same PR.

3. **Every platform the change touches.** Code and rules are shared:
   - `Shared/` builds into the iOS receiver, the Mac receiver and parts of the
     Mac sender.
   - The protocol is implemented in Swift (Mac, iOS), Kotlin (`Android/`) and
     Rust (`linux/crates/opendisplay-proto`, which the Windows builds use too).
   - The Mac sender (`Mac/`) and the Linux sender (`linux/crates/od-sender`)
     must make the same decisions for the same receiver.

   Change a rule in one place and check the others, with tests where they
   exist. If you could not check a platform, say so in the PR.

4. **Tests at the right level.** Unit tests for logic (`MacTests`,
   `Android/app/src/test`, `cargo test` in `linux/`). A run on real hardware
   for anything that touches capture, encoding, decoding, presentation,
   transport or display configuration. Put what you connected and the numbers
   (fps, latency, memory) in the PR. A PR without them for the platforms it
   touches is not ready to merge.

5. **Check for overlapping work.** Search open PRs and issues for the same
   files and feature before you start, and link them. `Mac/MacSender.swift` in
   particular has many open PRs: keep changes there small and mechanical so
   others can rebase, and don't reformat or rename unrelated code.

6. **Long-running behaviour counts.** The sender runs for days. Nothing may grow
   per reconnect, sleep/wake, capture restart or display change: sessions,
   buffers, timers, observers. Recurring work uses a cancellable handle, never
   a self-rescheduling `asyncAfter` chain.

7. **People can find out about it.** A user-visible change updates the info
   material in the same PR, or before the release that ships it: the README
   (features, FAQ, comparison), the website (`src/App.tsx`), the docs
   (`content/docs/`), and any sentence that no longer holds. Claim only what
   was measured.

## Practicalities

- One topic per PR. Describe what changes, why, and how you tested it.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org)
  (`feat:`, `fix:`, `docs:`, ...); release-please builds the changelog and the
  releases from them.
- Local setup (Debug bundle IDs, permissions, test hosts, the Linux workspace)
  is in [AGENTS.md](AGENTS.md).
- Release PRs get a release impact record ([RELEASING.md](RELEASING.md)).
