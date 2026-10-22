// Build step: render content/docs/**/*.md into static pages under docs/docs/
// (one index.html per page, e.g. content/docs/linux/install.md →
// docs/docs/linux/install/index.html → https://opendisplay.app/docs/linux/install/)
// and add every page to docs/sitemap.xml. Runs after `vite build` and the SSR
// build (see package.json), so it can reuse the built stylesheet and the
// DocsLayout component from dist-ssr. The pages need no client JS.
//
// See content/docs/README.md for the frontmatter fields.
import fs from "node:fs/promises"
import path from "node:path"
import { Marked } from "marked"
import YAML from "yaml"
import { renderDoc } from "../dist-ssr/entry-server.js"

const SITE = "https://opendisplay.app"
const CONTENT_DIR = "content/docs"
const OUT_DIR = "docs"
const EDIT_BASE = "https://github.com/peetzweg/opendisplay/edit/main/"
const HOME = { title: "OpenDisplay", route: "/" }

// ---- collect pages -------------------------------------------------------

async function walk(dir) {
  const out = []
  for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name)
    if (entry.isDirectory()) out.push(...(await walk(p)))
    else if (entry.name.endsWith(".md") && entry.name !== "README.md") out.push(p)
  }
  return out
}

function parseFrontmatter(src, file) {
  const m = src.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?/)
  if (!m) throw new Error(`docs: ${file} has no frontmatter (--- title/description ---)`)
  const data = YAML.parse(m[1]) ?? {}
  for (const key of ["title", "description"]) {
    if (typeof data[key] !== "string" || !data[key].trim()) {
      throw new Error(`docs: ${file} needs a "${key}" in its frontmatter`)
    }
  }
  if (data.updated instanceof Date) data.updated = data.updated.toISOString().slice(0, 10)
  return { data, body: src.slice(m[0].length) }
}

function routeFor(file) {
  // content/docs/linux/install.md → /docs/linux/install/
  const rel = path.relative(CONTENT_DIR, file).split(path.sep).join("/").replace(/\.md$/, "")
  const parts = rel.split("/")
  if (parts.at(-1) === "index") parts.pop()
  return "/" + ["docs", ...parts].join("/") + "/"
}

const files = await walk(CONTENT_DIR)
const pages = []
for (const file of files) {
  const { data, body } = parseFrontmatter(await fs.readFile(file, "utf8"), file)
  pages.push({
    file: file.split(path.sep).join("/"),
    route: routeFor(file),
    title: data.title.trim(),
    nav: (data.nav ?? data.title).trim(),
    description: data.description.trim(),
    order: Number.isFinite(data.order) ? data.order : 1000,
    updated: data.updated,
    body,
  })
}
const byRoute = new Map(pages.map((p) => [p.route, p]))
if (!byRoute.has("/docs/")) throw new Error("docs: content/docs/index.md is missing")

// ---- nav tree, breadcrumbs, prev/next --------------------------------------

function parentRoute(route) {
  if (route === "/docs/") return null
  return route.replace(/[^/]+\/$/, "")
}

for (const p of pages) {
  const parent = parentRoute(p.route)
  if (parent && !byRoute.has(parent)) {
    throw new Error(`docs: ${p.file} has no section page; add ${CONTENT_DIR}${parent.slice(5)}index.md`)
  }
}

function buildNode(route) {
  const page = byRoute.get(route)
  const children = pages
    .filter((p) => parentRoute(p.route) === route)
    .sort((a, b) => a.order - b.order || a.nav.localeCompare(b.nav))
    .map((p) => buildNode(p.route))
  return { title: page.nav, route, children }
}
const nav = buildNode("/docs/")

// Reading order: depth first, a section's own page before its children.
const order = []
;(function flatten(node) {
  order.push(node.route)
  node.children.forEach(flatten)
})(nav)

function breadcrumbs(route) {
  const crumbs = []
  for (let r = route; r; r = parentRoute(r)) {
    const p = byRoute.get(r)
    crumbs.unshift({ title: p.nav, route: r })
  }
  return crumbs
}

// ---- markdown --------------------------------------------------------------

function escapeHtml(s) {
  return String(s)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
}

function slugify(text) {
  return (
    text
      .toLowerCase()
      .replace(/<[^>]+>/g, "")
      .replace(/&[a-z#0-9]+;/g, "")
      .replace(/[^\p{L}\p{N}\s-]/gu, "")
      .trim()
      .replace(/\s+/g, "-")
      .replace(/-+/g, "-") || "section"
  )
}

function renderMarkdown(md, base, file) {
  const used = new Map()
  const marked = new Marked({ gfm: true })
  marked.use({
    renderer: {
      heading({ tokens, depth }) {
        if (depth === 1) throw new Error(`docs: ${file} uses a # heading; the title comes from frontmatter, start at ##`)
        const inner = this.parser.parseInline(tokens)
        let id = slugify(inner)
        const n = used.get(id) ?? 0
        used.set(id, n + 1)
        if (n) id = `${id}-${n}`
        return `<h${depth} id="${id}"><a class="h-anchor" href="#${id}">${inner}</a></h${depth}>\n`
      },
      link({ href, title, tokens }) {
        // Site-absolute links ("/docs/linux/install/") become relative to the
        // page, so they work on the custom domain and under a subpath.
        let target = href
        if (target.startsWith("/") && !target.startsWith("//")) target = base + target.slice(1)
        const external = /^https?:\/\//.test(target)
        const t = title ? ` title="${escapeHtml(title)}"` : ""
        return `<a href="${escapeHtml(target)}"${t}${external ? ' rel="noopener"' : ""}>${this.parser.parseInline(tokens)}</a>`
      },
    },
  })
  return marked
    .parse(md)
    .replaceAll("<table>", '<div class="tbl-scroll"><table>')
    .replaceAll("</table>", "</table></div>")
}

// ---- page shell ------------------------------------------------------------

const indexHtml = await fs.readFile(path.join(OUT_DIR, "index.html"), "utf8")
const cssHrefs = [...indexHtml.matchAll(/<link rel="stylesheet"[^>]*href="\.\/([^"]+\.css)"/g)].map((m) => m[1])
if (!cssHrefs.length) throw new Error("docs: no stylesheet link found in docs/index.html")

function jsonLd(obj) {
  return JSON.stringify(obj, null, 2).replaceAll("<", "\\u003c")
}

function pageHtml(page, i) {
  const base = "../".repeat(page.route.split("/").filter(Boolean).length)
  const url = SITE + page.route
  const crumbs = breadcrumbs(page.route)
  const prev = i > 0 ? byRoute.get(order[i - 1]) : undefined
  const next = i < order.length - 1 ? byRoute.get(order[i + 1]) : undefined
  const fullTitle = page.route === "/docs/" ? "OpenDisplay Docs" : `${page.title} · OpenDisplay Docs`

  const body = renderDoc({
    base,
    route: page.route,
    title: page.title,
    description: page.description,
    html: renderMarkdown(page.body, base, page.file),
    nav,
    breadcrumbs: crumbs,
    prev: prev && { title: prev.nav, route: prev.route },
    next: next && { title: next.nav, route: next.route },
    editUrl: EDIT_BASE + page.file,
    updated: page.updated,
  })

  const article = {
    "@context": "https://schema.org",
    "@type": "TechArticle",
    headline: page.title,
    description: page.description,
    url,
    mainEntityOfPage: url,
    inLanguage: "en",
    ...(page.updated && { dateModified: page.updated }),
    image: `${SITE}/og.png`,
    author: { "@type": "Person", name: "peetzweg", url: "https://github.com/peetzweg" },
    publisher: { "@type": "Organization", name: "OpenDisplay", url: `${SITE}/`, logo: `${SITE}/icon.png` },
    about: { "@type": "SoftwareApplication", name: "OpenDisplay", url: `${SITE}/` },
    isPartOf: { "@type": "WebSite", name: "OpenDisplay", url: `${SITE}/` },
  }
  const breadcrumbList = {
    "@context": "https://schema.org",
    "@type": "BreadcrumbList",
    itemListElement: [HOME, ...crumbs].map((c, n) => ({
      "@type": "ListItem",
      position: n + 1,
      name: c.title,
      item: SITE + c.route,
    })),
  }

  const t = escapeHtml(fullTitle)
  const d = escapeHtml(page.description)
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${t}</title>
  <meta name="description" content="${d}" />
  <link rel="canonical" href="${url}" />
  <link rel="icon" type="image/png" href="${base}icon-256.png" />
${cssHrefs.map((h) => `  <link rel="stylesheet" href="${base}${h}" />`).join("\n")}
  <meta property="og:type" content="article" />
  <meta property="og:site_name" content="OpenDisplay" />
  <meta property="og:locale" content="en_US" />
  <meta property="og:title" content="${t}" />
  <meta property="og:description" content="${d}" />
  <meta property="og:url" content="${url}" />
  <meta property="og:image" content="${SITE}/og.png" />
  <meta property="og:image:width" content="1200" />
  <meta property="og:image:height" content="630" />
${page.updated ? `  <meta property="article:modified_time" content="${page.updated}" />\n` : ""}  <meta name="twitter:card" content="summary_large_image" />
  <meta name="twitter:title" content="${t}" />
  <meta name="twitter:description" content="${d}" />
  <meta name="twitter:image" content="${SITE}/og.png" />
  <meta name="theme-color" content="#ffffff" />
  <script type="application/ld+json">
${jsonLd(article)}
  </script>
  <script type="application/ld+json">
${jsonLd(breadcrumbList)}
  </script>
  <link rel="preconnect" href="https://analytics.drdrip.xyz" crossorigin />
  <script defer data-domain="opendisplay.app" src="https://analytics.drdrip.xyz/js/script.hash.outbound-links.js"></script>
</head>
<body class="docs-page">
${body}
</body>
</html>
`
}

for (const [i, route] of order.entries()) {
  const page = byRoute.get(route)
  const outFile = path.join(OUT_DIR, ...route.split("/").filter(Boolean), "index.html")
  await fs.mkdir(path.dirname(outFile), { recursive: true })
  await fs.writeFile(outFile, pageHtml(page, i))
}

// ---- sitemap ---------------------------------------------------------------

const sitemapFile = path.join(OUT_DIR, "sitemap.xml")
let sitemap = await fs.readFile(sitemapFile, "utf8")
const entries = order
  .filter((route) => !sitemap.includes(`<loc>${SITE}${route}</loc>`))
  .map((route) => {
    const p = byRoute.get(route)
    const lastmod = p.updated ? `\n    <lastmod>${p.updated}</lastmod>` : ""
    return `  <url>\n    <loc>${SITE}${route}</loc>${lastmod}\n    <changefreq>monthly</changefreq>\n    <priority>${route === "/docs/" ? "0.7" : "0.6"}</priority>\n  </url>\n`
  })
  .join("")
sitemap = sitemap.replace("</urlset>", `${entries}</urlset>`)
await fs.writeFile(sitemapFile, sitemap)

console.log(`docs: rendered ${order.length} pages into ${OUT_DIR}/docs/ and added them to sitemap.xml`)
