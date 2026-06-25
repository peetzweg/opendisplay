# App Store Connect listing — reference

Canonical copy for the OpenSidecar iOS app's App Store Connect / TestFlight text
fields, kept in version control so we know what's live and can edit deliberately.

> **Privacy:** the **Feedback email** and any contact addresses are intentionally
> **not** stored here. Set/maintain those directly in App Store Connect.

When you change a field in App Store Connect, update it here too.

---

## App Information (applies to all versions)

**Name**
```
OpenSidecar
```

**Subtitle** _(max 30 chars)_
```
Second monitor for your Mac
```

**Copyright** _(format: year + rights holder; App Store Connect adds the © itself — do not type it)_
```
2026 Philip Poloczek
```

**Content Rights** — does the app contain, show, or access third-party content?
> **No.** The app only displays the user's own Mac screen over a direct connection;
> it bundles and streams no third-party content.

**Category:** Utilities (primary)

---

## Version metadata (per release)

**Promotional Text** _(max 170 chars; editable without a new build)_
```
Turn the iPhone or iPad you already own into a real second display for your Mac — free, open source, and private. Works over USB or Wi-Fi.
```

**Description**
```
OpenSidecar turns your iPhone or iPad into a second display for your Mac.

It's the free, open-source way to put your spare Apple device to work as a real extended monitor — drag windows onto it, keep chat, notes, or logs in view, and gain screen space anywhere you go. It's not a mirror: it's a genuine additional display your Mac treats like any other monitor.

• Real extended display — arrange it in your Mac's Display settings and drag windows across
• Connect over USB for the lowest latency, or over Wi-Fi with zero setup
• Retina-sharp, pixel-for-pixel rendering
• Touch and scroll — tap, drag, and two-finger scroll to control your Mac
• Works in portrait or landscape
• Private by design — a direct connection between your own devices, with no accounts, no servers, and no tracking

IMPORTANT: OpenSidecar requires the free companion OpenSidecar app for Mac, running on your computer on the same cable or Wi-Fi network. Get it at https://peetzweg.github.io/opensidecar — without it, this app has nothing to connect to.

OpenSidecar is open source under the GPL-3.0 license. Read the code, report issues, or contribute at https://github.com/peetzweg/opensidecar
```

**Keywords** _(max 100 chars; comma-separated, no spaces after commas)_
```
second monitor,external display,extend screen,monitor,display,screen,ipad as display,usb,wireless
```

**Support URL**
```
https://peetzweg.github.io/opensidecar
```

**Marketing URL** _(optional)_
```
https://peetzweg.github.io/opensidecar
```

**Privacy Policy URL**
```
https://peetzweg.github.io/opensidecar/privacy.html
```

---

## TestFlight

**Beta App Description**
```
OpenSidecar turns your iPhone or iPad into a second display for your Mac.

To use this beta you also need the free OpenSidecar app for Mac running on your computer, on the same USB cable or Wi-Fi network. Get it here:
https://peetzweg.github.io/opensidecar

Once both are running: connect over USB for the lowest latency or over Wi-Fi with no setup, drag windows onto the device, try touch and two-finger scroll, and rotate between portrait and landscape.

Please report anything that looks off — connection drops, latency, image sharpness, rotation, or touch accuracy. Thanks for testing!
```

**Feedback email** — _managed in App Store Connect; not stored here._

---

## Notes for future edits

- **Trademark caution:** keep Apple's feature name "Sidecar" and competitor brands
  ("Duet", "Luna") **out of the Description and Keywords** — Apple review often rejects
  metadata that uses them. Comparing to those products is fine on the website, not in
  store metadata. (The app *name* contains "Sidecar" — a separate, already-made call.)
- The Description states the **Mac-app requirement** on purpose; App Review needs to
  know the app is non-functional without the companion. Keep that line.
- Field limits: Subtitle ≤ 30, Promotional Text ≤ 170, Keywords ≤ 100 (whole string,
  commas included).
