// Minimal classnames joiner — stands in for clsx/tailwind-merge. We don't use
// Tailwind, so we only need to flatten and join truthy class strings.
export function cn(...inputs: unknown[]): string {
  const out: string[] = []
  const walk = (v: unknown) => {
    if (!v) return
    if (Array.isArray(v)) {
      v.forEach(walk)
      return
    }
    if (typeof v === "string") out.push(v)
  }
  inputs.forEach(walk)
  return out.join(" ")
}
