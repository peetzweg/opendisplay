# Changelog

## [1.12.0](https://github.com/peetzweg/opendisplay/compare/v0.11.0...v1.12.0) (2026-07-12)


### Features

* **ios:** add remote-config force-update gate ([#135](https://github.com/peetzweg/opendisplay/issues/135)) ([b4133f2](https://github.com/peetzweg/opendisplay/commit/b4133f25e27c6f8937b4cbf4b3985b82265068f7))
* **mac:** seamless transport switching between USB and WiFi ([8fecc3c](https://github.com/peetzweg/opendisplay/commit/8fecc3c4147da4778ce0111c55eb1aecd6bde22a))
* **protocol:** add version handshake on the wire ([#132](https://github.com/peetzweg/opendisplay/issues/132)) ([d506e6c](https://github.com/peetzweg/opendisplay/commit/d506e6cfc9c8ac43b5e56093ea5665df9426d86b))
* **web:** add four community posts to demo showcase ([3f13f9c](https://github.com/peetzweg/opendisplay/commit/3f13f9c0ef71fe666fadd46b48fe14887cba42c1))
* **web:** add Ko-fi support nudge banner under downloads ([10bfcdc](https://github.com/peetzweg/opendisplay/commit/10bfcdcceda08d6a948f14fed7e070cee717aba0))
* **web:** center hero Ko-fi nudge, move second to end of demo section ([d2256d4](https://github.com/peetzweg/opendisplay/commit/d2256d43e48292a4d4dd5297a8ece1b035430fdf))
* **web:** drop side borders on mobile Ko-fi nudge, keep top/bottom band ([2dd6b26](https://github.com/peetzweg/opendisplay/commit/2dd6b267514333394ffb4c8d54b0aa79ed17bc61))
* **web:** extract Ko-fi nudge into repeatable borderless SupportNudge section ([b12e00b](https://github.com/peetzweg/opendisplay/commit/b12e00b6202a5ec13995b5d9c278ce3f8db029e8))
* **web:** move Ko-fi nudge above downloads, drop hero support hint ([ca37938](https://github.com/peetzweg/opendisplay/commit/ca37938dc05767ffafd388dd223dab8a17ddd855))
* **web:** place sticky Ko-fi bar between hero and downloads section ([7c0f1e7](https://github.com/peetzweg/opendisplay/commit/7c0f1e776a41ef938a422e7c962dc9e5ee6a685a))
* **web:** revert Ko-fi nudge to centered bordered pill (drop full-width bar) ([a3e2b1d](https://github.com/peetzweg/opendisplay/commit/a3e2b1d1a12a9de5db57ea21485bf70341e6f111))
* **web:** show Ko-fi nudge both above (left) and below (centered) downloads ([66c1923](https://github.com/peetzweg/opendisplay/commit/66c192395f83e4c887fbbdc9d3870b5bd9a0ec91))
* **web:** single full-width sticky Ko-fi bar above downloads; unsticks at support; pointer cursor on support button ([2523672](https://github.com/peetzweg/opendisplay/commit/25236724858b49eac37b066571258f9fc449b6d2))
* **web:** sticky Ko-fi support nudge between hero and downloads ([15a18e7](https://github.com/peetzweg/opendisplay/commit/15a18e771303648563e968b2778895ac361fdc03))


### Bug Fixes

* **mac:** cancel virtual display retry on disconnect ([a131076](https://github.com/peetzweg/opendisplay/commit/a131076892780d0a9dcdc12aa9047d1240598999))
* **mac:** generation-guard the reconnect dial ([79452c7](https://github.com/peetzweg/opendisplay/commit/79452c7bef3e9b356d5e72b7401a8d4d9025cad2))
* **mac:** latest arrangement wins across orientation flips ([ad7800d](https://github.com/peetzweg/opendisplay/commit/ad7800dcb12a4557bd07a8481f7913da3b762fdd))
* **mac:** remember virtual display arrangement across reconnects ([72d4578](https://github.com/peetzweg/opendisplay/commit/72d45781c05ce9cf43e38476460e3b32977e17b6)), closes [#116](https://github.com/peetzweg/opendisplay/issues/116)
* **mac:** retry virtual display creation while a stale serial lingers ([8acc36c](https://github.com/peetzweg/opendisplay/commit/8acc36c3690351cd74541e0cf583c80c578435ef))


### Miscellaneous Chores

* release 1.12.0 ([5dc7b31](https://github.com/peetzweg/opendisplay/commit/5dc7b31ed6b3d6c19a4bebabe7e8ffa1981eafc4))

## [0.11.0](https://github.com/peetzweg/opendisplay/compare/v0.10.1...v0.11.0) (2026-07-07)


### Features

* **web:** full-bleed showcase strip with ad-blocker-proof tweet fallbacks ([26879c2](https://github.com/peetzweg/opendisplay/commit/26879c28f7c2912e8fc86b7c24ea3de7c58ac3d1))
* **web:** replace live X embeds with self-hosted static post cards ([9415b37](https://github.com/peetzweg/opendisplay/commit/9415b37ba2639ced50707b52efae921f5b2d84d2))
* **web:** showcase community tweets alongside the demo video ([9d95a94](https://github.com/peetzweg/opendisplay/commit/9d95a94cb56dcb4b99b630204610576cc4e8ec47))
* **web:** showcase community tweets alongside the demo video ([b32a4d1](https://github.com/peetzweg/opendisplay/commit/b32a4d1f2327e7d06166f4892acd6d70a70137dd))


### Bug Fixes

* **mac:** force extend-mode virtual display out of system mirror sets ([84f7dee](https://github.com/peetzweg/opendisplay/commit/84f7dee8e22f80c7b7a5d1e3bc23cb933fa56817))
* **mac:** force extend-mode virtual display out of system mirror sets ([#100](https://github.com/peetzweg/opendisplay/issues/100)) ([e3fca0e](https://github.com/peetzweg/opendisplay/commit/e3fca0e0869faafe9af9e3bd617ed9e8c936b64a))

## [0.10.1](https://github.com/peetzweg/opendisplay/compare/v0.10.0...v0.10.1) (2026-07-03)


### Bug Fixes

* **ci:** appcast never publishes on first release (untracked file) ([090144c](https://github.com/peetzweg/opendisplay/commit/090144cd195acf2397d804ddf5e5538ed7ece1ac))
* **ci:** publish appcast on first release (detect untracked file) ([db16008](https://github.com/peetzweg/opendisplay/commit/db16008ef3c9176b33ba3b8c319cc843547155c1))

## [0.10.0](https://github.com/peetzweg/opendisplay/compare/v0.9.0...v0.10.0) (2026-07-03)


### Features

* **mac:** scaffold Sparkle auto-update with Pages-hosted appcast ([42415f8](https://github.com/peetzweg/opendisplay/commit/42415f802485136b7bf4261705aae47863430787))
* **mac:** Sparkle auto-update with Pages-hosted appcast (rebase of [#70](https://github.com/peetzweg/opendisplay/issues/70)) ([1d52c29](https://github.com/peetzweg/opendisplay/commit/1d52c298cb3ed125e340fd6d9f115521a2404370))
* **web:** activate App Store download link for iOS receiver ([9ae421e](https://github.com/peetzweg/opendisplay/commit/9ae421ee079b558bb1ad095dab35a007eabb1b5b))
* **web:** add demo video section ([6a5a358](https://github.com/peetzweg/opendisplay/commit/6a5a358730e7844f528dcb9fcabf2b14a36c6e01))
* **web:** add hero app-icon logo with animated navbar handoff ([c4b2997](https://github.com/peetzweg/opendisplay/commit/c4b29971778905c1e29606a7d51f63c3d281f3e7))
* **web:** add multi-screen feature, tweak Ko-fi iPad wording ([279a39d](https://github.com/peetzweg/opendisplay/commit/279a39dd12dc58b6dbff9f78c9c8ac234fd40e37))
* **web:** add Plausible analytics and iOS Smart App Banner ([5504d91](https://github.com/peetzweg/opendisplay/commit/5504d91d46fbd6f4d41e964df5733eea9855eab5))
* **web:** add social share image and FAQPage structured data ([3fe0915](https://github.com/peetzweg/opendisplay/commit/3fe0915d25381a3f3276d61d88e4df5e463dc97c))
* **web:** align download secondary links, add older-version link, iPadOS, mobile step order ([1d59277](https://github.com/peetzweg/opendisplay/commit/1d59277bc1402f609a47d5fa184c93ee5351f34c))
* **web:** refine feature copy and reorder the grid ([a4e0799](https://github.com/peetzweg/opendisplay/commit/a4e0799a4ce6e2bb3ddd896e8113e1136f6df03f))
* **web:** reorder sections, Ko-fi branding, cost transparency, scroll-spy ([36105d3](https://github.com/peetzweg/opendisplay/commit/36105d3b1624f869ba7ce2fea29227281ceb7468))
* **web:** serve site from opendisplay.app custom domain ([712918f](https://github.com/peetzweg/opendisplay/commit/712918f21ca03c9a457a75766165896b2f7c99a2))


### Bug Fixes

* **ci:** guard Sparkle appcast step via env, not secrets context ([acd23b5](https://github.com/peetzweg/opendisplay/commit/acd23b5ca0fb087908494ada816cb3cb16ecf197))
* **ci:** release workflow fails at startup (secrets in if:) ([ff2e82f](https://github.com/peetzweg/opendisplay/commit/ff2e82f31f96973aee70674f648d56b4c47c2788))

## [0.9.0](https://github.com/peetzweg/opendisplay/compare/v0.8.0...v0.9.0) (2026-06-30)


### Features

* rename app to OpenDisplay ([07d9962](https://github.com/peetzweg/opendisplay/commit/07d9962ef83ffab8628a263f978e98d5f1cd1d94))

## [0.8.0](https://github.com/peetzweg/opensidecar/compare/v0.7.2...v0.8.0) (2026-06-29)


### Features

* **site:** improve landing-page SEO (robots, sitemap, meta) ([757983c](https://github.com/peetzweg/opensidecar/commit/757983c33d2d310dd9b32749b3cf8827d8b99eeb))
* **site:** improve landing-page SEO (robots, sitemap, meta) ([d1e63c9](https://github.com/peetzweg/opensidecar/commit/d1e63c902fcdbf462b49e1eef441087b459cab05)), closes [#59](https://github.com/peetzweg/opensidecar/issues/59)


### Bug Fixes

* **mac:** guard liveness monitors against double-start ([#75](https://github.com/peetzweg/opensidecar/issues/75) hardening) ([0c96e65](https://github.com/peetzweg/opensidecar/commit/0c96e65f75d6de1de980dc9b80fc7a57728e5da0))
* **mac:** stop CPU leak that creeps up across sleep/wake ([#75](https://github.com/peetzweg/opensidecar/issues/75)) ([c365668](https://github.com/peetzweg/opensidecar/commit/c365668e1a45e9dfbde44b1256ea9b4982270638))
* **mac:** stop cursor-image poll leak across sleep/wake ([#75](https://github.com/peetzweg/opensidecar/issues/75)) ([0e8a959](https://github.com/peetzweg/opensidecar/commit/0e8a9591cc6e2d73507c355ce84178344b0fcfae))

## [0.7.2](https://github.com/peetzweg/opensidecar/compare/v0.7.1...v0.7.2) (2026-06-23)


### Bug Fixes

* cd the DMG shell block to the repo root instead of expanding paths ([557bbf9](https://github.com/peetzweg/opensidecar/commit/557bbf9f5d7f9d75cd32b763a3c1347a843d6fa5))

## [0.7.1](https://github.com/peetzweg/opensidecar/compare/v0.7.0...v0.7.1) (2026-06-23)


### Bug Fixes

* use absolute paths when packaging the macOS DMG ([04860c7](https://github.com/peetzweg/opensidecar/commit/04860c7cf3549cbfb5b2e881cd017a3493df8c6e))

## [0.7.0](https://github.com/peetzweg/opensidecar/compare/v0.6.16...v0.7.0) (2026-06-23)


### Features

* **iOS:** first-run onboarding hint that the Mac app is required ([3d012f3](https://github.com/peetzweg/opensidecar/commit/3d012f30024f946b04064716f143bdf60762820a)), closes [#49](https://github.com/peetzweg/opensidecar/issues/49)
* new app icon + branding (laptop + display, happy-Mac faces) ([65dabce](https://github.com/peetzweg/opensidecar/commit/65dabce97541a0c470f5eadd3942e09eae664190))
* ship notarized .dmg + wire TestFlight link ([#48](https://github.com/peetzweg/opensidecar/issues/48)) ([1c10ce9](https://github.com/peetzweg/opensidecar/commit/1c10ce964a62180a4aea427ecf8965ab706b9045))
* ship notarized .dmg, wire TestFlight link ([#48](https://github.com/peetzweg/opensidecar/issues/48)) ([e902f14](https://github.com/peetzweg/opensidecar/commit/e902f14f30404f0b84600bb307591c7c6491af70))


### Bug Fixes

* **docs:** restore horizontal padding on mobile for hero and table ([7b10044](https://github.com/peetzweg/opensidecar/commit/7b100441433b94680972fd8e2473e66ddb36240e))

## [0.6.16](https://github.com/peetzweg/opensidecar/compare/v0.6.15...v0.6.16) (2026-06-15)


### Bug Fixes

* inject release version and unique build number into app builds ([924b464](https://github.com/peetzweg/opensidecar/commit/924b464f43d1170808b77e48448b6e2ecdd61ab4))

## [0.6.15](https://github.com/peetzweg/opensidecar/compare/v0.6.14...v0.6.15) (2026-06-15)


### Bug Fixes

* use full explicit iOS app icon set for TestFlight validation ([42569e3](https://github.com/peetzweg/opensidecar/commit/42569e381538eceaf8c8c070332b4939788d0338))

## [0.6.14](https://github.com/peetzweg/opensidecar/compare/v0.6.13...v0.6.14) (2026-06-15)


### Bug Fixes

* add CFBundleIcons with both IconName and IconFiles to resolve 90022/90023 ([271bd7a](https://github.com/peetzweg/opensidecar/commit/271bd7a5edf4277730dc3da4cc7f73c3f9398848))
* move legacy icons to iOS/ root, drop CFBundleIcons ([10e5b51](https://github.com/peetzweg/opensidecar/commit/10e5b51a1d313f8b43ff49efe4ed5f7e5f42ef3a))

## [0.6.13](https://github.com/peetzweg/opensidecar/compare/v0.6.12...v0.6.13) (2026-06-15)


### Bug Fixes

* add standalone legacy icon PNGs to fix altool 90022/90023/90713 ([783ecdd](https://github.com/peetzweg/opensidecar/commit/783ecddc5c214e8b385399159b935262af0fbb6f))

## [0.6.12](https://github.com/peetzweg/opensidecar/compare/v0.6.11...v0.6.12) (2026-06-15)


### Bug Fixes

* try universal/ios without size or rendering-intent ([d3fa276](https://github.com/peetzweg/opensidecar/commit/d3fa2769ee607b3c6803810aa549c769803b5778))

## [0.6.11](https://github.com/peetzweg/opensidecar/compare/v0.6.10...v0.6.11) (2026-06-15)


### Bug Fixes

* combined icon format with rendering-intent + CFBundleIconName ([9b606c1](https://github.com/peetzweg/opensidecar/commit/9b606c1646626cac1d48bd6b73344281cbb7e63f))

## [0.6.10](https://github.com/peetzweg/opensidecar/compare/v0.6.9...v0.6.10) (2026-06-15)


### Bug Fixes

* use Xcode 26 icon format with rendering-intent template ([1169c57](https://github.com/peetzweg/opensidecar/commit/1169c57c4ec1b84bae0ae73ea6bae96f00cb6358))

## [0.6.9](https://github.com/peetzweg/opensidecar/compare/v0.6.8...v0.6.9) (2026-06-15)


### Bug Fixes

* add universal ios-marketing icon alongside per-size entries ([0075d95](https://github.com/peetzweg/opensidecar/commit/0075d95ba31c8286106e106a0591fc48ecbc6dd8))

## [0.6.8](https://github.com/peetzweg/opensidecar/compare/v0.6.7...v0.6.8) (2026-06-15)


### Bug Fixes

* use Xcode 16+ universal app icon format for iOS ([fdcf118](https://github.com/peetzweg/opensidecar/commit/fdcf11894f4962d288fd54e1a6b3c16c8a551e5a))

## [0.6.7](https://github.com/peetzweg/opensidecar/compare/v0.6.6...v0.6.7) (2026-06-15)


### Bug Fixes

* add iPad icon sizes and switch CI to macos-26 for iOS 26 SDK ([2e0ad58](https://github.com/peetzweg/opensidecar/commit/2e0ad589ee80c039fb6fed7c18b286d67336e599))

## [0.6.6](https://github.com/peetzweg/opensidecar/compare/v0.6.5...v0.6.6) (2026-06-15)


### Bug Fixes

* pass explicit app_identifier to upload_to_testflight ([8bd61c4](https://github.com/peetzweg/opensidecar/commit/8bd61c4dad87333a8db276e48672f51db4d0bf64))

## [0.6.5](https://github.com/peetzweg/opensidecar/compare/v0.6.4...v0.6.5) (2026-06-15)


### Bug Fixes

* add setup_ci for keychain and correct Mac profile name ([c29944c](https://github.com/peetzweg/opensidecar/commit/c29944c3073967418801eb63c1656d441922612c))

## [0.6.4](https://github.com/peetzweg/opensidecar/compare/v0.6.3...v0.6.4) (2026-06-14)


### Bug Fixes

* wire match profiles to xcodebuild via update_code_signing_settings ([ea0fcdd](https://github.com/peetzweg/opensidecar/commit/ea0fcddad566170d892391287dc1c83d349d5b71))

## [0.6.3](https://github.com/peetzweg/opensidecar/compare/v0.6.2...v0.6.3) (2026-06-14)


### Bug Fixes

* use manual code signing for iOS Release to work with match ([200f665](https://github.com/peetzweg/opensidecar/commit/200f66571f159aff875543cbf87db3f5ffbc0752))

## [0.6.2](https://github.com/peetzweg/opensidecar/compare/v0.6.1...v0.6.2) (2026-06-14)


### Bug Fixes

* add explicit schemes to project.yml and restore SSH deploy key workflow ([9262883](https://github.com/peetzweg/opensidecar/commit/9262883fb656062054887479fa9fee7496dec1cd))

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
