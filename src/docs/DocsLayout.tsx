import SiteFooter from "../components/SiteFooter"

// Layout for the prerendered /docs pages (tools/docs.mjs renders the markdown
// and calls renderDoc() from src/entry-server.tsx). Pure static markup: no
// client JS, no hydration. Every href is relative to `base` (the path back to
// the site root), so the pages also work when served from a subpath.

export type DocLink = { title: string; route: string }
export type DocNavNode = DocLink & { children: DocNavNode[] }
export type DocHeading = { id: string; depth: number; text: string }

export type DocPageProps = {
  base: string
  route: string
  title: string
  description: string
  html: string
  /** The page's ## and ### headings, in order. */
  toc: DocHeading[]
  nav: DocNavNode
  breadcrumbs: DocLink[]
  prev?: DocLink
  next?: DocLink
  editUrl: string
  updated?: string
}

const GITHUB_URL = "https://github.com/peetzweg/opendisplay"

function href(base: string, route: string) {
  return base + route.replace(/^\//, "")
}

function NavTree({ node, base, route }: { node: DocNavNode; base: string; route: string }) {
  return (
    <ul>
      {node.children.map((child) => (
        <li key={child.route} className={child.children.length ? "group" : undefined}>
          <a
            href={href(base, child.route)}
            aria-current={child.route === route ? "page" : undefined}
          >
            {child.title}
          </a>
          {child.children.length > 0 && <NavTree node={child} base={base} route={route} />}
        </li>
      ))}
    </ul>
  )
}

function DocsNav({ nav, base, route }: { nav: DocNavNode; base: string; route: string }) {
  return (
    <nav className="docs-nav" aria-label="Documentation">
      <a
        className="docs-nav-root"
        href={href(base, nav.route)}
        aria-current={nav.route === route ? "page" : undefined}
      >
        {nav.title}
      </a>
      <NavTree node={nav} base={base} route={route} />
    </nav>
  )
}

function PageOutline({ toc }: { toc: DocHeading[] }) {
  return (
    <nav className="docs-toc" aria-label="On this page">
      <p className="docs-toc-title">On this page</p>
      <ul>
        {toc.map((h) => (
          <li key={h.id} className={h.depth > 2 ? "sub" : undefined}>
            <a href={`#${h.id}`}>{h.text}</a>
          </li>
        ))}
      </ul>
    </nav>
  )
}

export default function DocsLayout(p: DocPageProps) {
  const { base } = p
  // An outline earns its place once a page has a few sections.
  const outline = p.toc.filter((h) => h.depth === 2).length >= 3 ? p.toc : null
  return (
    <>
      <nav className="site-nav">
        <div className="wrap">
          <a className="brand" href={base || "./"}>
            <img className="nav-logo" src={`${base}logo.png`} alt="" width="43" height="43" />
            <span>OpenDisplay</span>
          </a>
          <div className="links docs-links">
            <a href={base || "./"}>Home</a>
            <a href={`${base}docs/`}>Docs</a>
            <a href={`${base}docs/linux/`}>Linux</a>
            <a href={`${base}docs/third-party/`}>Third-party</a>
            <a href={GITHUB_URL}>GitHub</a>
          </div>
        </div>
      </nav>

      <div className={outline ? "wrap docs has-toc" : "wrap docs"}>
        <aside className="docs-side">
          <DocsNav nav={p.nav} base={base} route={p.route} />
        </aside>

        <main className="docs-main">
          <details className="docs-menu">
            <summary>Docs menu</summary>
            <DocsNav nav={p.nav} base={base} route={p.route} />
          </details>

          <ol className="docs-crumbs" aria-label="Breadcrumb">
            {p.breadcrumbs.map((c, i) => (
              <li key={c.route}>
                {i < p.breadcrumbs.length - 1 ? (
                  <a href={href(base, c.route)}>{c.title}</a>
                ) : (
                  <span aria-current="page">{c.title}</span>
                )}
              </li>
            ))}
          </ol>

          <article className="doc">
            <h1>{p.title}</h1>
            {p.description && <p className="doc-lead">{p.description}</p>}
            {outline && (
              <details className="docs-toc-menu">
                <summary>On this page</summary>
                <PageOutline toc={outline} />
              </details>
            )}
            <div dangerouslySetInnerHTML={{ __html: p.html }} />
          </article>

          {(p.prev || p.next) && (
            <div className="docs-pager">
              {p.prev ? (
                <a className="prev" href={href(base, p.prev.route)} rel="prev">
                  <span>Previous</span>
                  {p.prev.title}
                </a>
              ) : (
                <span />
              )}
              {p.next && (
                <a className="next" href={href(base, p.next.route)} rel="next">
                  <span>Next</span>
                  {p.next.title}
                </a>
              )}
            </div>
          )}

          <p className="docs-meta">
            <a href={p.editUrl}>Edit this page on GitHub ↗</a>
            {p.updated && <> · Updated {p.updated}</>}
          </p>
        </main>

        {outline && (
          <aside className="docs-toc-side">
            <PageOutline toc={outline} />
          </aside>
        )}
      </div>

      <SiteFooter base={base} />
    </>
  )
}
