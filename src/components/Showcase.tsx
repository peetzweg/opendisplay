import { useEffect, useRef, useState } from "react"
import { COVERAGE } from "../content/coverage"

type ShowcaseItem =
  | { kind: "youtube"; id: string; title: string }
  | (typeof COVERAGE)[number]

const ITEMS: ShowcaseItem[] = [
  {
    kind: "youtube",
    id: "wyEUkMgH3zw",
    title: "OpenDisplay demo — use your iPad as a second monitor for your Mac",
  },
  {
    kind: "youtube",
    id: "W3dGq8yXOcA",
    title: "OpenDisplay demo",
  },
  ...COVERAGE,
]

function ExternalLinkIcon() {
  return (
    <svg className="coverage-external" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M14 3h7v7h-2V6.41l-9.29 9.3-1.42-1.42L17.59 5H14V3ZM5 5h6v2H7v10h10v-4h2v6H5V5Z" />
    </svg>
  )
}

export default function Showcase() {
  const trackRef = useRef<HTMLDivElement>(null)
  const autoScrollFrame = useRef<number>(0)
  const isAutoScrolling = useRef(false)
  const pauseUntil = useRef(0)
  const [canPrev, setCanPrev] = useState(false)
  const [canNext, setCanNext] = useState(true)

  useEffect(() => {
    const el = trackRef.current
    if (!el) return
    const sync = () => {
      setCanPrev(el.scrollLeft > 8)
      setCanNext(el.scrollLeft < el.scrollWidth - el.clientWidth - 8)
    }
    sync()
    const onScroll = () => {
      sync()
      // Give manual scrolling room before the gentle tour resumes.
      if (!isAutoScrolling.current) pauseUntil.current = performance.now() + 4000
    }
    el.addEventListener("scroll", onScroll, { passive: true })
    window.addEventListener("resize", sync)
    return () => {
      el.removeEventListener("scroll", onScroll)
      window.removeEventListener("resize", sync)
    }
  }, [])

  useEffect(() => {
    const el = trackRef.current
    if (!el || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return

    let previous = performance.now()
    const tick = (now: number) => {
      const isPaused = now < pauseUntil.current || el.matches(":hover") || el.matches(":focus-within")
      if (!isPaused) {
        const max = el.scrollWidth - el.clientWidth
        if (el.scrollLeft >= max - 1) {
          isAutoScrolling.current = true
          el.scrollTo({ left: 0, behavior: "auto" })
          isAutoScrolling.current = false
        } else {
          isAutoScrolling.current = true
          el.scrollLeft += (now - previous) * 0.012
          isAutoScrolling.current = false
        }
      }
      previous = now
      autoScrollFrame.current = requestAnimationFrame(tick)
    }
    autoScrollFrame.current = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(autoScrollFrame.current)
  }, [])

  const nudge = (dir: 1 | -1) => {
    const el = trackRef.current
    if (el) el.scrollBy({ left: dir * Math.round(el.clientWidth * 0.85), behavior: "smooth" })
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
            <a key={item.url} className={`showcase-item is-coverage${item.post ? " is-post" : ""}`} href={item.url} target="_blank" rel="noreferrer">
              {item.post ? (
                <>
                  <div className="post-head">
                    <span className="post-monogram" aria-hidden="true">{item.post.author.slice(0, 1)}</span>
                    <div><strong>{item.post.author}</strong><span>@{item.post.handle}</span></div>
                    <span className="post-x">𝕏</span>
                  </div>
                  <p className="post-quote">{item.post.text}</p>
                  <span className="post-date">{item.post.date}</span>
                </>
              ) : item.image ? <img className="coverage-image" src={item.image} alt="" loading="lazy" /> : <div className="coverage-placeholder" aria-hidden="true" />}
              <div className="coverage-body">
                {!item.post && <><div className="coverage-site"><span>{item.site}</span><ExternalLinkIcon /></div><h3>{item.title}</h3><p>{item.description}</p></>}
                <span className="coverage-cta">{item.site === "X" ? "View post ↗" : "Read coverage ↗"}</span>
              </div>
            </a>
          )
        )}
      </div>
      <div className="showcase-nav">
        <button type="button" aria-label="Scroll back" disabled={!canPrev} onClick={() => nudge(-1)}>←</button>
        <button type="button" aria-label="Scroll forward" disabled={!canNext} onClick={() => nudge(1)}>→</button>
      </div>
    </div>
  )
}
