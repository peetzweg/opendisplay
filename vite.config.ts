import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"

// The site is served from https://peetzweg.github.io/opensidecar/ via GitHub Pages
// (Pages "deploy from branch" → /docs). Relative base keeps asset URLs working
// under the /opensidecar/ subpath without hardcoding it, and the build emits
// straight into docs/ so the published folder stays the same.
export default defineConfig({
  base: "./",
  plugins: [react()],
  build: {
    outDir: "docs",
    emptyOutDir: true,
  },
})
