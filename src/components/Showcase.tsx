import { useEffect, useRef, useState } from "react"

// The demo section's media strip: the YouTube demo plus posts from people
// using OpenDisplay in the wild. Posts render as self-contained static cards
// (photos + avatars live in public/showcase/) instead of live X embeds —
// widgets.js renders unreliably under ad blockers and browser privacy
// features, and a third-party tracking script sits badly on a page that
// advertises "no telemetry" anyway. To showcase a new post, add an entry to
// ITEMS and drop its media into public/showcase/.
type ShowcaseItem =
  | { kind: "youtube"; id: string; title: string }
  | {
      kind: "post"
      url: string
      author: string
      handle: string
      avatar: string
      date: string
      text: string[] // paragraphs/lines of the post
      image: { src: string; alt: string; width: number; height: number }
    }

const ITEMS: ShowcaseItem[] = [
  {
    kind: "youtube",
    id: "wyEUkMgH3zw",
    title: "OpenDisplay demo — use your iPad as a second monitor for your Mac",
  },
  {
    kind: "post",
    url: "https://x.com/eduwass/status/2071902710597583300",
    author: "Edu Wass",
    handle: "@eduwass",
    avatar: "showcase/avatar-eduwass.jpg",
    date: "Jun 30, 2026",
    text: [
      "@peetzweg here's the setup I've been testing OpenSidecar on 😅",
      "- LG Ultrawide",
      "- Macbook Pro M1 (built-in screen)",
      "- iPad Pro 12.9 x3",
      "working like a champ",
    ],
    image: {
      src: "showcase/tweet-eduwass.jpg",
      alt: "Desk with an LG ultrawide, a MacBook Pro and three iPad Pros all running as displays",
      width: 1200,
      height: 675,
    },
  },
  {
    kind: "post",
    url: "https://x.com/peetzweg/status/2074416821738815692",
    author: "peetzweg/",
    handle: "@peetzweg",
    avatar: "showcase/avatar-peetzweg.jpg",
    date: "Jul 7, 2026",
    text: ["How the magic is happening today. Obviously using OpenDisplay for my Mactendo DS™ setup."],
    image: {
      src: "showcase/tweet-peetzweg.jpg",
      alt: "MacBook with an iPhone perched above its screen as a second display — the Mactendo DS setup",
      width: 1200,
      height: 900,
    },
  },
]

// X logomark, shown in the card corner as the "view on X" affordance.
function XLogo() {
  return (
    <svg className="post-x" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
    </svg>
  )
}

export default function Showcase() {
  const trackRef = useRef<HTMLDivElement>(null)
  const [canPrev, setCanPrev] = useState(false)
  const [canNext, setCanNext] = useState(true)

  // Keep the arrows honest: disable the one pointing at an edge we're on.
  useEffect(() => {
    const el = trackRef.current
    if (!el) return
    const sync = () => {
      setCanPrev(el.scrollLeft > 8)
      setCanNext(el.scrollLeft < el.scrollWidth - el.clientWidth - 8)
    }
    sync()
    el.addEventListener("scroll", sync, { passive: true })
    window.addEventListener("resize", sync)
    return () => {
      el.removeEventListener("scroll", sync)
      window.removeEventListener("resize", sync)
    }
  }, [])

  const nudge = (dir: 1 | -1) => {
    const el = trackRef.current
    if (!el) return
    el.scrollBy({ left: dir * Math.round(el.clientWidth * 0.85), behavior: "smooth" })
  }

  return (
    <div className="showcase">
      <div className="showcase-track" ref={trackRef}>
        {ITEMS.map((item) =>
          item.kind === "youtube" ? (
            <div key={item.id} className="showcase-item is-video">
              <div className="video-embed">
                <iframe
                  src={`https://www.youtube-nocookie.com/embed/${item.id}`}
                  title={item.title}
                  loading="lazy"
                  allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
                  allowFullScreen
                />
              </div>
            </div>
          ) : (
            <a key={item.url} className="showcase-item is-post" href={item.url}>
              <div className="post-head">
                <img className="post-avatar" src={item.avatar} alt="" width="48" height="48" loading="lazy" />
                <div className="post-who">
                  <span className="post-author">{item.author}</span>
                  <span className="post-handle">{item.handle}</span>
                </div>
                <XLogo />
              </div>
              {item.text.map((line) => (
                <p key={line} className="post-text">{line}</p>
              ))}
              <img
                className="post-photo"
                src={item.image.src}
                alt={item.image.alt}
                width={item.image.width}
                height={item.image.height}
                loading="lazy"
              />
              <span className="post-date">{item.date} · View on X ↗</span>
            </a>
          )
        )}
      </div>
      <div className="showcase-nav">
        <button type="button" aria-label="Scroll back" disabled={!canPrev} onClick={() => nudge(-1)}>
          ←
        </button>
        <button type="button" aria-label="Scroll forward" disabled={!canNext} onClick={() => nudge(1)}>
          →
        </button>
      </div>
    </div>
  )
}
