// Post-build static prerender: inject the SSR-rendered <App/> markup into the
// built docs/index.html so the shipped page is fully crawlable (SEO parity with
// the old hand-written static site). The client still boots React on top and
// runs the animation; this only fills the initial markup.
import fs from "node:fs/promises"
import { render } from "../dist-ssr/entry-server.js"

const html = render()
const file = "docs/index.html"
const src = await fs.readFile(file, "utf8")
if (!src.includes('<div id="root"></div>')) {
  throw new Error('prerender: could not find empty <div id="root"></div> to inject into')
}
const out = src.replace('<div id="root"></div>', `<div id="root">${html}</div>`)
await fs.writeFile(file, out)
console.log(`prerendered ${html.length} chars into ${file}`)
