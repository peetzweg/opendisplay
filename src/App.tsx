import { useEffect, useState } from "react"
import TextRotate from "./components/TextRotate"

const HERO_WORDS = [
  "iPhone",
  "girlfriend's iPad",
  "mother's iPad",
  "partner's iPad",
  "kid's iPad",
  "dusty iPad",
  "iPad",
]

export default function App() {
  const [macVer, setMacVer] = useState<string | null>(null)
  const [starCount, setStarCount] = useState<string | null>(null)

  // Progressive enhancement: current release version + live star count.
  // Fails silent (offline / rate-limited) — the page works without it.
  useEffect(() => {
    fetch("https://api.github.com/repos/peetzweg/opendisplay/releases/latest", {
      headers: { Accept: "application/vnd.github+json" },
    })
      .then((r) => (r.ok ? r.json() : null))
      .then((data) => {
        if (data && data.tag_name) setMacVer(data.tag_name)
      })
      .catch(() => {})

    fetch("https://api.github.com/repos/peetzweg/opendisplay", {
      headers: { Accept: "application/vnd.github+json" },
    })
      .then((r) => (r.ok ? r.json() : null))
      .then((data) => {
        if (data && typeof data.stargazers_count === "number") {
          setStarCount(data.stargazers_count.toLocaleString())
        }
      })
      .catch(() => {})
  }, [])

  return (
    <>
      <nav>
        <div className="wrap">
          <a className="brand" href="./">
            <img src="icon-256.png" alt="" /> OpenDisplay
          </a>
          <div className="links">
            <a href="#features">Features</a>
            <a href="#contribute">Contribute</a>
            <a href="#why">Compare</a>
            <a href="#faq">FAQ</a>
            <a href="#support">Support</a>
            <a
              className="gh"
              href="https://github.com/peetzweg/opendisplay"
              title="Star OpenDisplay on GitHub"
            >
              <svg className="gh-logo" viewBox="0 0 16 16" aria-hidden="true">
                <path
                  fillRule="evenodd"
                  d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"
                />
              </svg>
              {starCount && (
                <span className="gh-stars">
                  <span>{starCount}</span>
                </span>
              )}
            </a>
          </div>
        </div>
      </nav>

      <section>
        <div className="wrap hero">
          <p className="eyebrow">Free &amp; open source · macOS + iOS</p>
          <h1>
            <span className="l1">
              Use your{" "}
              <TextRotate
                as="span"
                texts={HERO_WORDS}
                mainClassName="rotator-pill"
                splitLevelClassName="rotator-line"
                staggerFrom="last"
                staggerDuration={0.025}
                rotationInterval={2200}
                transition={{ type: "spring", damping: 30, stiffness: 400 }}
                initial={{ y: "100%", opacity: 0 }}
                animate={{ y: 0, opacity: 1 }}
                exit={{ y: "-120%", opacity: 0 }}
              />
            </span>
            <span className="l2">as your Mac's <span className="u">second monitor</span>.</span>
          </h1>
          <p className="tagline">
            A free, open-source alternative to Apple Sidecar, Duet Display and Luna Display.
            Use your iPhone and iPad as a second — and even a third — screen for your Mac.
            A true extended display, not a mirror: USB or WiFi, Retina-sharp, with touch and
            scroll. No subscription. No dongle. No account.
          </p>
          <p className="meta">macOS 14+ &nbsp;·&nbsp; iOS 17+ &nbsp;·&nbsp; GPL-3.0</p>
          <p className="hero-support">
            <a href="#support">Like it? Support the project →</a>
          </p>

          <p className="needs-both">
            OpenDisplay is <strong>two apps that work together</strong> — install both to get going.
          </p>
          <div className="downloads">
            <div>
              <div className="dl-head">
                <span className="step">Step 1</span> On your Mac{" "}
                <span className="ver">{macVer}</span>
              </div>
              <p className="dl-sub">The sender — captures a virtual display and streams it.</p>
              <a
                className="btn primary"
                href="https://github.com/peetzweg/opendisplay/releases/latest/download/OpenDisplay.dmg"
              >
                Download for Mac
              </a>
              <p className="note">
                Signed &amp; notarized — opens normally on macOS&nbsp;14+. Prefer to compile it yourself?{" "}
                <a href="https://github.com/peetzweg/opendisplay#quick-start">Build from source ↗</a>
              </p>
            </div>
            <div>
              <div className="dl-head">
                <span className="step">Step 2</span> On your iPhone &amp; iPad
              </div>
              <p className="dl-sub">The receiver — displays the stream and sends touch back.</p>
              <div className="ios-row">
                <a
                  className="badge-wrap"
                  href="https://apps.apple.com/app/id6780264891"
                >
                  <img
                    className="appstore-badge"
                    src="app-store-badge.svg"
                    alt="Download on the App Store"
                    width="120"
                    height="40"
                  />
                </a>
              </div>
              <p className="sub">
                Want early builds? <a id="testflight" href="https://testflight.apple.com/join/3NYaY11c">
                  Join the TestFlight beta
                </a>
                ,<br />
                or{" "}
                <a href="https://github.com/peetzweg/opendisplay#quick-start">
                  compile it from source ↗
                </a>
                .
              </p>
            </div>
          </div>
        </div>
      </section>

      <section id="support">
        <div className="wrap sec support">
          <p className="eyebrow">Support the project</p>
          <h2>If OpenDisplay saved you a monitor, consider buying me a coffee.</h2>
          <p>
            Free, open source, and funded out of my own pocket — including the Apple Developer
            membership behind signed, one-click installs. If it helps you, a tip keeps it going.
          </p>
          <a className="btn primary" href="https://ko-fi.com/peetzweg">Support on Ko-fi</a>
        </div>
      </section>

      <section id="features">
        <div className="wrap sec">
          <p className="eyebrow">Features</p>
          <h2>A true extended display, the way it should be.</h2>
          <div className="fgrid">
            <div className="fcell"><span className="n">001</span><h3>No account, ever</h3><p>No sign-up, no email, no login. And unlike Apple Sidecar — which only works between devices on the <em>same</em> Apple ID — OpenDisplay pairs across different Apple IDs, so you can use a partner's or friend's iPad. Download both apps and go.</p></div>
            <div className="fcell"><span className="n">002</span><h3>Low-latency pipeline</h3><p>Up to 60 FPS over USB. Hardware H.264 (VideoToolbox real-time mode), TCP_NODELAY, and frame-dropping backpressure with instant keyframe recovery keep it responsive.</p></div>
            <div className="fcell"><span className="n">003</span><h3>Retina sharp</h3><p>Native Retina resolution — the virtual display matches your device panel pixel-for-pixel at HiDPI (@2x), so text looks exactly like it should.</p></div>
            <div className="fcell"><span className="n">004</span><h3>True extension</h3><p>macOS treats your phone as a real monitor via a virtual display — arrange it in System Settings, drag windows onto it. Mirroring is available too.</p></div>
            <div className="fcell"><span className="n">005</span><h3>USB-wired, lowest latency</h3><p>Streams over your charging cable via usbmux. No network, no jitter — and your phone charges while it works.</p></div>
            <div className="fcell"><span className="n">006</span><h3>WiFi, zero config</h3><p>The phone advertises itself with Bonjour; pick it from a dropdown. No IP addresses to type.</p></div>
            <div className="fcell"><span className="n">007</span><h3>Touch &amp; scroll</h3><p>Tap to click, drag to drag, two-finger pan to scroll. A tiny touchscreen for your Mac.</p></div>
            <div className="fcell"><span className="n">008</span><h3>Portrait mode</h3><p>Rotate the phone and the virtual display rebuilds as a vertical monitor — perfect for chat, logs, or docs.</p></div>
            <div className="fcell"><span className="n">009</span><h3>Private by design</h3><p>One direct TCP connection between your devices. No servers, no accounts, no telemetry. Read the code.</p></div>
          </div>
        </div>
      </section>

      <section id="contribute">
        <div className="wrap sec">
          <p className="eyebrow">Contribute</p>
          <h2>Open source, and built in the open.</h2>
          <p style={{ color: "var(--muted)", maxWidth: "72ch", marginTop: "8px" }}>
            OpenDisplay is GPL-3.0 and developed entirely on GitHub — the whole stack, from Mac
            capture and H.264 encoding to the iOS receiver, is yours to read, build, and improve.
            Bug reports, feature ideas, and pull requests are all welcome. Build-and-run instructions
            live in the README.
          </p>
          <div className="btn-row">
            <a className="btn primary" href="https://github.com/peetzweg/opendisplay">View on GitHub ↗</a>
            <a className="btn ghost" href="https://github.com/peetzweg/opendisplay/issues">Open an issue ↗</a>
          </div>
          <p className="sub">
            New here? Start with the{" "}
            <a href="https://github.com/peetzweg/opendisplay#quick-start">README quick-start</a>{" "}
            to build both apps, or browse the{" "}
            <a href="https://github.com/peetzweg/opendisplay/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22">good first issues</a>.
          </p>
        </div>
      </section>

      <section id="why">
        <div className="wrap sec">
          <p className="eyebrow">Why OpenDisplay</p>
          <h2>The device you already own becomes a real additional display.</h2>
          <div className="compare">
            <div className="row">
              <div className="name"><a href="https://support.apple.com/en-us/HT210380">Apple Sidecar</a></div>
              <p>Free, but iPad-only, requires both devices on the same Apple&nbsp;ID, and only on
              blessed hardware pairs. iPhones need not apply.</p>
            </div>
            <div className="row">
              <div className="name"><a href="https://www.duetdisplay.com/">Duet Display</a></div>
              <p>Pioneered the idea — now behind a subscription.</p>
            </div>
            <div className="row">
              <div className="name"><a href="https://astropad.com/product/lunadisplay/">Luna Display</a></div>
              <p>Great latency, but you're buying a hardware dongle.</p>
            </div>
            <div className="row highlight">
              <div className="name">OpenDisplay</div>
              <p>Free, open source, auditable. The device you already own becomes a real additional
              display. If you were about to build your own — contribute here instead.</p>
            </div>
          </div>

          <h3 className="tbl-head">How it stacks up</h3>
          <div className="tbl-scroll">
            <table>
              <thead>
                <tr><th></th><th className="os">OpenDisplay</th><th>Apple Sidecar</th><th>Duet</th><th>Luna</th></tr>
              </thead>
              <tbody>
                <tr><td>Price</td><td className="mark-yes os">Free &amp; open source</td><td>Free</td><td className="mark-no">Subscription</td><td className="mark-no">$$$ + dongle</td></tr>
                <tr><td>iPhone as display</td><td className="mark-yes os">✓</td><td className="mark-no">✕</td><td className="mark-yes">✓</td><td className="mark-yes">✓</td></tr>
                <tr><td>Different Apple IDs</td><td className="mark-yes os">✓</td><td className="mark-no">✕</td><td className="mark-yes">✓</td><td className="mark-yes">✓</td></tr>
                <tr><td>No account / sign-up</td><td className="mark-yes os">✓</td><td>Apple&nbsp;ID</td><td className="mark-no">✕</td><td>—</td></tr>
                <tr><td>Wired USB</td><td className="mark-yes os">✓</td><td className="mark-yes">✓</td><td className="mark-yes">✓</td><td className="mark-no">✕</td></tr>
                <tr><td>Self-hosted / auditable</td><td className="mark-yes os">✓</td><td>—</td><td className="mark-no">✕</td><td className="mark-no">✕</td></tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section id="faq">
        <div className="wrap sec">
          <p className="eyebrow">FAQ</p>
          <h2>Questions, answered.</h2>
          <div className="faq">
            <details>
              <summary>How does it actually work?</summary>
              <p>The Mac creates a virtual display with the private <code>CGVirtualDisplay</code> API
              (the same technique used by BetterDisplay and DeskPad), captures it with ScreenCaptureKit,
              hardware-encodes H.264 with VideoToolbox, and streams it over a single TCP connection —
              through the USB cable via usbmux, or over WiFi. The phone decodes and renders with
              <code>AVSampleBufferDisplayLayer</code> and sends touch coordinates back, which the Mac
              injects as mouse events.</p>
            </details>
            <details>
              <summary>Is this on the App Store?</summary>
              <p>Yes — the iPhone &amp; iPad receiver is{" "}
              <a href="https://apps.apple.com/app/id6780264891">live on the App Store</a>. The Mac
              app ships as a signed, notarized direct download rather than through the Mac App Store
              because it relies on <code>CGVirtualDisplay</code>, a private API — that's the deal for
              every virtual-display product: use it or ship a dongle. You can also build either app
              from source with your own (free) Apple developer account in a few minutes.</p>
            </details>
            <details>
              <summary>Why do I see the purple screen-recording indicator on my Mac?</summary>
              <p>macOS shows that privacy indicator for <em>every</em> app that captures the screen —
              Duet, Luna, OBS and Zoom included. Apple Sidecar avoids it only because it's built into
              the OS. It's a feature, not a bug: you always know a capture is running.</p>
            </details>
            <details>
              <summary>WiFi mode can't find my iPhone — why?</summary>
              <p>WiFi discovery needs the <strong>Local Network</strong> permission on <em>both</em>
              sides, and macOS/iOS deny it silently if the prompt was missed: check System Settings →
              Privacy &amp; Security → Local Network on the Mac, and Settings → Privacy &amp; Security →
              Local Network on the iPhone. Both devices must be on the same WiFi and the iPhone app
              must be open. The Mac app shows a live permission panel, and the iPhone app has a settings
              screen (shake the phone) that links straight there. USB mode needs none of this.</p>
            </details>
            <details>
              <summary>iPad support?</summary>
              <p>The receiver is a universal iOS app — it runs on iPad today. Run the Mac, an iPhone
              <em>and</em> an iPad at once for a second and a third screen. iPad-specific features
              (Apple Pencil, pressure) are on the roadmap.</p>
            </details>
            <details>
              <summary>Is any of my screen data sent to a server?</summary>
              <p>No. One direct TCP connection between your Mac and your device. No accounts, no
              analytics, no cloud. The full story — what the apps store locally, which permissions they
              use and why, and the one current caveat about unencrypted WiFi transport — is on the{" "}
              <a href="privacy.html">privacy page</a>.</p>
            </details>
            <details>
              <summary>What's the license? Can I fork it or use it commercially?</summary>
              <p>OpenDisplay is licensed under{" "}
              <a href="https://github.com/peetzweg/opendisplay/blob/main/LICENSE">GPL-3.0</a>. You can
              use, study, and adapt it freely — including commercially. If you distribute a modified
              version, it must remain open source under the same license with the original attribution
              intact, so improvements flow back to everyone instead of into closed forks. (Releases up
              to v0.4.x were MIT-licensed and remain available under those terms.)</p>
            </details>
          </div>
        </div>
      </section>

      <footer>
        <div className="wrap">
          <div className="links">
            <a href="https://github.com/peetzweg/opendisplay">GitHub</a>
            <a href="https://github.com/peetzweg/opendisplay/releases/latest">Releases</a>
            <a href="https://github.com/peetzweg/opendisplay/issues">Issues</a>
            <a href="https://ko-fi.com/peetzweg">Support / Ko-fi</a>
            <a href="privacy.html">Privacy</a>
            <a href="https://github.com/peetzweg/opendisplay/blob/main/LICENSE">GPL-3.0 License</a>
          </div>
          <p className="fine">OpenDisplay — use your iPhone or iPad as a second monitor for your Mac. Free forever.</p>
        </div>
      </footer>
    </>
  )
}
