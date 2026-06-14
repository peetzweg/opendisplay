# Changelog

## [0.6.1](https://github.com/peetzweg/opensidecar/compare/v0.6.0...v0.6.1) (2026-06-14)


### Bug Fixes

* trigger release build with split CI jobs ([99100a6](https://github.com/peetzweg/opensidecar/commit/99100a6087d41db461bf45b674f84f60a94ddb81))

## [0.6.0](https://github.com/peetzweg/opensidecar/compare/v0.5.0...v0.6.0) (2026-06-14)


### Features

* fastlane release pipeline for iOS TestFlight and notarized Mac builds ([d940685](https://github.com/peetzweg/opensidecar/commit/d940685d9a515a0f11fe248c1f85e95e67a8d39d))

## [0.5.0](https://github.com/peetzweg/opensidecar/compare/v0.4.0...v0.5.0) (2026-06-11)


### Features

* auto-connect the -host/-port manual endpoint alongside devices ([e3dfc0f](https://github.com/peetzweg/opensidecar/commit/e3dfc0f7db6de8a1aaa39c4afedd6d2db4df9830))
* dedupe USB/WiFi sessions to the same physical device ([3228256](https://github.com/peetzweg/opensidecar/commit/3228256139ab80e658c7f0d019b30f91346ee854))
* multi-device sessions — one virtual display per connected device ([272a794](https://github.com/peetzweg/opensidecar/commit/272a794d20946dd8133cdb673104c589ed87c81b))
* multiple devices as simultaneous extended displays ([bc6b869](https://github.com/peetzweg/opensidecar/commit/bc6b869a321a964656d9c30c249c558c1afe8d99))
* one row per physical device, no automatic transport handover ([1cf5745](https://github.com/peetzweg/opensidecar/commit/1cf57450a09c632388fbb4f833f701e8aed89c54))
* per-display test patterns + multi-device docs and test tool ([d04a4ce](https://github.com/peetzweg/opensidecar/commit/d04a4cec233a061d1b6ef0d9fb12b27094b35cc5))
* relicense from MIT to GPL-3.0 ([22607a7](https://github.com/peetzweg/opensidecar/commit/22607a760afe0589f1f2485743b0a972b5f71804))


### Bug Fixes

* enforce HiDPI mode continuously, orientation-specific display serials ([300330e](https://github.com/peetzweg/opensidecar/commit/300330ea05d8ab0b99d9a3822bf745b33a2d28a7))
* real event source + clickState on injected clicks ([ede0ce4](https://github.com/peetzweg/opensidecar/commit/ede0ce4c11a0da2385109222338398216676d248))
* size the cursor sprite against the live display mode ([b494081](https://github.com/peetzweg/opensidecar/commit/b49408116d320655e2a13d0dbec5b45d220fb64a))
* user clicks take over dying sessions; recover vanished [@2x](https://github.com/2x) modes ([0b74810](https://github.com/peetzweg/opensidecar/commit/0b74810acf013116e8343bcebea422da661f262d))

## [0.4.0](https://github.com/peetzweg/opensidecar/compare/v0.3.0...v0.4.0) (2026-06-11)


### Features

* built-in USB connectivity (drop the iproxy requirement) ([3ab674a](https://github.com/peetzweg/opensidecar/commit/3ab674acc15f271dd36d3001abee927aff762c41))
* built-in USB connectivity over usbmuxd, drop the iproxy requirement ([79e07a5](https://github.com/peetzweg/opensidecar/commit/79e07a5bf011ad341a45c3f0de4fb7eac3002463))
* editable device name for the WiFi connection picker ([eb6f036](https://github.com/peetzweg/opensidecar/commit/eb6f036f062954cdd43f0159763e50431a692de1))
* editable device name for the WiFi picker ([a470abc](https://github.com/peetzweg/opensidecar/commit/a470abc74a18b84194507669b645423f76c5b6f9))


### Bug Fixes

* cursor disappears after a reconnect ([288e3b1](https://github.com/peetzweg/opensidecar/commit/288e3b10b1e0538034e39715f99a869036d6b51e))
* device-name field needed two taps to edit ([0855813](https://github.com/peetzweg/opensidecar/commit/0855813fafb457f04cec8710617c0de9ef24dc91))
* re-send the cursor sprite to a reconnecting receiver ([2c13082](https://github.com/peetzweg/opensidecar/commit/2c130820deb94cebadada633a08c934e16d5c7db))
* wrap the performance overlay so it fits in portrait ([809368c](https://github.com/peetzweg/opensidecar/commit/809368cc8bdff47e6c59a732aac8df59f9431ba5))

## [0.3.0](https://github.com/peetzweg/opensidecar/compare/v0.2.0...v0.3.0) (2026-06-10)


### Features

* app presentation modes and menu bar panel sizing fix ([cc7caa5](https://github.com/peetzweg/opensidecar/commit/cc7caa593b99c1f2cecc2eb5e5fa55ecc6fd6fbe))
* end session when the device disconnects, rename Phone target to iOS ([5b99719](https://github.com/peetzweg/opensidecar/commit/5b99719cb5a630b3bfc103aca5844d4e82513456))
* experimental Metal renderer with true glass-time latency metric ([e9b784c](https://github.com/peetzweg/opensidecar/commit/e9b784c6b444c86b6527889827db0cd111d9e7f4))
* local cursor echo — pointer rendered on-device off the video path ([f043be5](https://github.com/peetzweg/opensidecar/commit/f043be5da9263fa3e5e86ca4f8d9b3759eee8f6e))
* menu bar app, true latency telemetry, quality presets, low-latency encoder ([d826668](https://github.com/peetzweg/opensidecar/commit/d826668f189078287682148744eeb341a50e32c0))
* transport badge and expanded debug overlay, Release deployment ([547355d](https://github.com/peetzweg/opensidecar/commit/547355d51f55c7eeaa07ffce4a7e336e6159617f))


### Bug Fixes

* Metal renderer A/B verdict — system layer wins, Metal stays opt-in ([49b4b8d](https://github.com/peetzweg/opensidecar/commit/49b4b8d83d59d780fb5059575dd8c13ab7afd041))
* rebuild the capture pipeline when the stream dies ([bc0f9d8](https://github.com/peetzweg/opensidecar/commit/bc0f9d8416d1fa301ed5e6859978738af64f06bb))


### Performance Improvements

* sustain true 60fps capture and cut input latency ([964d567](https://github.com/peetzweg/opensidecar/commit/964d5678e891055ea126b2ffa10fba97ade6a283))

## [0.2.0](https://github.com/peetzweg/opensidecar/compare/v0.1.0...v0.2.0) (2026-06-10)


### Features

* Arrange Displays shortcut in the Mac app ([c64bdec](https://github.com/peetzweg/opensidecar/commit/c64bdec442499408811ff64badaaae5954e129d5))
* opt-in performance overlay on the iPhone ([770b5d1](https://github.com/peetzweg/opensidecar/commit/770b5d1609aeda27e082e01cf7c5ee1dcf0df82f))
* permission status UI, iOS settings screen, system light/dark mode ([f5a4131](https://github.com/peetzweg/opensidecar/commit/f5a41311ed8bc2cd749f6168b37d8ed5339ff7f9))
* rebrand to a neutral Apple white-and-blue palette ([d2543a0](https://github.com/peetzweg/opensidecar/commit/d2543a067afd3ae286b451b95672200d5e47b3ef))


### Bug Fixes

* automatic recovery from stale and half-open connections ([8b49ccb](https://github.com/peetzweg/opensidecar/commit/8b49ccb540ee4e335d486472d470857dd8324808))

## 0.1.0 (2026-06-10)


### Features

* automated releases with downloadable macOS and iOS builds ([377b5d3](https://github.com/peetzweg/opensidecar/commit/377b5d3621b8cf826cc7f74ff3fdc23607577d08))
