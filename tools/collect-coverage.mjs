// One-off metadata refresher. It is deliberately not part of `pnpm build`:
// production builds must remain deterministic and must not depend on third-
// party sites being reachable. Review the printed values before copying them
// into src/content/coverage.ts.
import { readFile } from "node:fs/promises"

const decode = (value) => value.replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'")
const valueFor = (html, property) => {
  const escaped = property.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  const match = html.match(new RegExp(`<meta[^>]+(?:property|name)=["']${escaped}["'][^>]+content=["']([^"']+)["']`, "i"))
    ?? html.match(new RegExp(`<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']${escaped}["']`, "i"))
  return match?.[1] ? decode(match[1]) : undefined
}

const source = await readFile(new URL("../src/content/coverage.ts", import.meta.url), "utf8")
const urls = [...source.matchAll(/url: "(https:\/\/[^\"]+)"/g)].map(([, url]) => url).filter((url) => !url.includes("x.com"))

for (const url of urls) {
  try {
    const response = await fetch(url, { headers: { "user-agent": "OpenDisplay coverage metadata refresher" } })
    const html = await response.text()
    console.log(JSON.stringify({
      url,
      title: valueFor(html, "og:title") ?? valueFor(html, "twitter:title"),
      description: valueFor(html, "og:description") ?? valueFor(html, "description"),
      image: valueFor(html, "og:image") ?? valueFor(html, "twitter:image"),
    }, null, 2))
  } catch (error) {
    console.error(`Could not read ${url}: ${error.message}`)
  }
}
