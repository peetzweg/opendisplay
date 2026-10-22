import SiteFooter from "../components/SiteFooter"

// Layout for the prerendered /docs pages (tools/docs.mjs renders the markdown
// and calls renderDoc() from src/entry-server.tsx). Pure static markup: no
// client JS, no hydration. Every href is relative to `base` (the path back to
// the site root), so the pages also work when served from a subpath.

export type DocLink = { title: string; route: string }
export type DocNavNode = DocLink & { children: DocNavNode[] }

export type DocPageProps = {
  base: string
  route: string
  title: string
  description: string
  html: string
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

export default function DocsLayout(p: DocPageProps) {
  const { base } = p
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
            <a href={GITHUB_URL}>GitHub</a>
          </div>
        </div>
      </nav>

      <div className="wrap docs">
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
      </div>

      <SiteFooter base={base} />
    </>
  )
}
