# OpenDisplay docs content

Markdown here becomes https://opendisplay.app/docs/ at build time
(`tools/docs.mjs`, run by `pnpm build`). This README is not published.

## Add a page

Create `content/docs/<section>/<slug>.md` with frontmatter; it is published at
`/docs/<section>/<slug>/` and appears in the left nav, prev/next links and
`sitemap.xml` automatically. A new section needs an `index.md` in its folder.

```md
---
title: Install the Linux sender      # <h1> and <title>
nav: Install                         # optional: shorter label for nav and breadcrumbs
description: One or two sentences.   # meta description, social cards, lead paragraph
order: 1                             # position among its siblings (lower first)
updated: 2026-10-22                  # optional: shown on the page and used as sitemap lastmod
---

## First heading (start at ##; the title is the h1)
```

## Writing notes

- Link other pages site-absolute with a trailing slash: `[Install](/docs/linux/install/)`.
  The build rewrites these to relative links so they work on any host path.
- Headings get ids from their text (`## Start on login` → `#start-on-login`);
  renaming a heading breaks links to it.
- Plain GitHub-flavoured markdown: tables, fenced code blocks, lists. Code is
  shown as is, without highlighting. No HTML-only features or client JS.
- Check the result with `npx pnpm@10.33.0 build` and `python3 -m http.server -d docs`,
  then open http://localhost:8000/docs/.
