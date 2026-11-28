<!--
OpenDisplay is a production app used daily by thousands of people, most of
whom update automatically. Please read CONTRIBUTING.md before opening a PR.
-->

Fixes #

**What and why:**

**How:**

**Testing:**
<!-- Devices, OS versions, transport (USB, Wi-Fi, cable) and numbers (fps, latency, memory). Say what you only reasoned through. -->

### Checklist

- [ ] Existing setups behave exactly as before, unless the user opts in or a newer peer asks for it
- [ ] Works with shipped versions of the other side (new sender with old receivers, old sender with new receivers)
- [ ] Every platform this touches is updated and checked (Mac sender, Linux sender, iOS, iPad, Android, Mac and Linux receivers, Rust protocol crate), or the PR says which were not
- [ ] PROTOCOL.md and COMPATIBILITY.md updated if the wire protocol changed
- [ ] Unit tests added or updated, and a run on real hardware for capture, codec, presentation, transport or display changes
- [ ] Nothing grows per reconnect, sleep/wake or capture restart
- [ ] Searched open PRs and issues for overlapping work and linked them
- [ ] User-visible change: README, website and docs updated (or not user-visible)
