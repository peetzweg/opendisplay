// Ko-fi nudge pill that jumps to #support. Sits in flow between the hero and the
// downloads and pins under the sticky nav once you scroll past it (position:
// sticky). It lives inside <div class="nudge-scope"> in App — that box ends
// where #support begins, so the pill stops sticking once the real support
// section is reached. A centered, bordered pill (blurb + CTA), not a full bar.
export default function SupportNudge() {
  return (
    <a className="support-nudge" href="#support">
      <span className="kofi-banner-left">
        <img className="kofi-mark" src="kofi-mark.webp" alt="" width="24" height="24" />
        <span className="kofi-banner-text">Free, and built by one person.</span>
      </span>
      <span className="kofi-banner-cta">
        Support me<span className="kofi-banner-arrow">↓</span>
      </span>
    </a>
  )
}
