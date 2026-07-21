import { useEffect, useRef, useState } from "react"

// Ko-fi nudge pill that jumps to #support. Sits in flow between the hero and the
// downloads and pins under the sticky nav once you scroll past it (position:
// sticky). It lives inside <div class="nudge-scope"> in App — that box ends
// where #support begins, so the pill stops sticking once the real support
// section is reached. A centered, bordered pill (blurb + CTA), not a full bar.
//
// Once pinned it drops its own top border (the .is-stuck class) so it doesn't
// double up against the nav's bottom border. "Stuck" can't be detected in pure
// CSS, so an IntersectionObserver watches the pill against the 60px nav line:
// the -61px top root margin makes it clip by 1px exactly when it pins, dropping
// intersectionRatio below 1.
export default function SupportNudge() {
  const ref = useRef<HTMLAnchorElement>(null)
  const [stuck, setStuck] = useState(false)

  useEffect(() => {
    const el = ref.current
    if (!el || typeof IntersectionObserver === "undefined") return
    const io = new IntersectionObserver(
      ([entry]) => setStuck(entry.intersectionRatio < 1),
      { threshold: [1], rootMargin: "-61px 0px 0px 0px" }
    )
    io.observe(el)
    return () => io.disconnect()
  }, [])

  return (
    <a
      ref={ref}
      className={stuck ? "support-nudge is-stuck" : "support-nudge"}
      href="#support"
    >
      <span className="kofi-banner-left">
        <img className="kofi-mark" src="kofi-mark.webp" alt="" width="24" height="24" />
        <span className="kofi-banner-text">Free, and built by one person.</span>
      </span>
      <span className="kofi-banner-cta">
        Buy Me a Coffee<span className="kofi-banner-arrow">↓</span>
      </span>
    </a>
  )
}
