# Build iOS With A Free Apple ID

This fork does not publish a ready-to-install iOS app package. iOS builds need
to be signed by the person installing them. The simplest path is to open the
project in Xcode and let Xcode sign the app with your own Apple ID.

## What You Need

- A Mac with Xcode installed
- An Apple ID signed in to Xcode
- An iPhone or iPad connected by USB
- This repository checked out locally

You do not need a paid Apple Developer Program membership for personal
development testing, but free Apple ID signing has limits. Apple states that
Personal Team provisioning profiles expire after 7 days, so you may need to
rebuild and reinstall the app periodically.

## Recommended Xcode Flow

1. Open `OpenSidecar.xcodeproj` in Xcode.
2. Select the `OpenSidecariOS` target.
3. Open **Signing & Capabilities**.
4. Choose your Apple ID team under **Team**.
5. Change the bundle identifier if Xcode says it is already taken.
6. Select your connected iPhone or iPad as the run destination.
7. Press **Run**.
8. On the iPhone or iPad, trust the developer profile if iOS asks.

The iOS app must stay open while receiving the Mac display stream.

## If You Changed `project.yml`

This repository uses XcodeGen. If `project.yml` changes, regenerate the Xcode
project before building:

```bash
./generate.sh
```

Then reopen `OpenSidecar.xcodeproj` in Xcode.

## Why There Is No Unsigned IPA

An unsigned iOS `.app` or `.ipa` is not directly installable on a normal iPhone
or iPad. Each user still needs their own certificate, provisioning profile,
bundle identifier, and registered device. For most users, building from source
in Xcode is clearer and less fragile than downloading an unsigned iOS package
and trying to re-sign it manually.

## Paid Developer Account

A paid Apple Developer Program account is only needed if you want broader iOS
distribution options such as TestFlight, App Store distribution, or ad hoc
distribution to registered devices. This fork currently focuses on local
development builds.
