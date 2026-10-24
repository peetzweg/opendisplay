import { renderToStaticMarkup } from "react-dom/server"
import App from "./App"
import DocsLayout, { type DocPageProps } from "./docs/DocsLayout"

// Used at build time by tools/prerender.mjs to produce the static HTML that gets
// injected into docs/index.html. Effects (the GitHub fetches) don't run here, so
// the prerendered markup reflects the initial, pre-fetch state — same as the old
// static page before its inline script ran.
export function render(): string {
  return renderToStaticMarkup(<App />)
}

// Used by tools/docs.mjs: the <body> markup of one /docs page. The docs pages
// are static (no hydration), so this is the whole page.
export function renderDoc(props: DocPageProps): string {
  return renderToStaticMarkup(<DocsLayout {...props} />)
}
