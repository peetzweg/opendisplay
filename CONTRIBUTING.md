# Contributing

Contributions are welcome when they keep the fork focused: Android receiver
support, Chinese localization, local Mac/iOS usability, protocol clarity, and
stability fixes.

## Branch And Project Rules

- Keep work on feature branches, not directly on `main`.
- If `project.yml` changes, run `./generate.sh` before building in Xcode.
- Do not commit generated build products, APK files, DerivedData, logs, or
  local signing configuration.
- Prefer small changes that can be reviewed independently.
- Preserve GPL-3.0 license notices and upstream attribution.

## Coding Guidelines

- Follow the existing Swift style for Mac and iOS code.
- Keep Android receiver classes narrow and platform-idiomatic.
- Keep protocol changes backward compatible where possible.
- Avoid blocking the Android UI thread with network writes.
- Keep user-facing copy concise, clear, and consistent across platforms.

## Documentation Guidelines

- README should explain project value and scope.
- Platform-specific details belong in the platform folder.
- Architecture and protocol decisions belong in `ARCHITECTURE.md`.
- Future work belongs in `ROADMAP.md`, not in scattered TODO comments.
- Avoid promising store releases, notarization, or encryption until they exist.

## Verification Expectations

Use the smallest checks that prove the change:

```bash
xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecarMac -configuration Debug -derivedDataPath build-run -clonedSourcePackagesDirPath build-run/SourcePackages build
```

```bash
xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecariOS -configuration Debug -sdk iphonesimulator -derivedDataPath build-verify-ios -clonedSourcePackagesDirPath build-verify-ios/SourcePackages build CODE_SIGNING_ALLOWED=NO
```

```bash
AndroidReceiver/scripts/build_debug_apk.sh
```

For Android protocol or input changes, also run the protocol self-test.

## Good Issue Reports

Useful reports include:

- macOS version and Mac model
- iOS/iPadOS or Android version
- receiver device model
- mirror or extend mode
- USB or WiFi
- whether VPN TUN mode is enabled
- what permissions are granted
- relevant logs or exact error text

See [SUPPORT.md](SUPPORT.md) for more detail.
