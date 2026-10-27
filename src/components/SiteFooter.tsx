// Shared by the landing page and the prerendered docs pages. `base` is the
// relative path back to the site root ("" on the landing page, "../../" on
// /docs/linux/), so the links work on the custom domain and under a subpath.
export default function SiteFooter({ base = "" }: { base?: string }) {
  return (
    <footer>
      <div className="wrap">
        <div className="links">
          <a href="https://github.com/peetzweg/opendisplay">GitHub</a>
          <a href="https://github.com/peetzweg/opendisplay/releases/latest">Releases</a>
          <a href={`${base}docs/`}>Docs</a>
          <a href="https://github.com/peetzweg/opendisplay/issues">Issues</a>
          <a href="https://ko-fi.com/peetzweg">Support / Ko-fi</a>
          <a href={`${base}privacy.html`}>Privacy</a>
          <a href="https://github.com/peetzweg/opendisplay/blob/main/LICENSE">GPL-3.0 License</a>
        </div>
        <p className="fine">OpenDisplay — use your iPhone or iPad as a second monitor for your Mac. Free forever.</p>
      </div>
    </footer>
  )
}
