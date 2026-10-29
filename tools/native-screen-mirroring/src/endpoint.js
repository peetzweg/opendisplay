import { isTailscaleAddress } from './tailscale.js';

// Bonjour setup verifies an IPv4 receiver. Keep hostname-based connections on
// that transport instead of selecting an unscoped link-local IPv6 address.
export function receiverEndpoint(host, port) {
  return /\.local\.?$/i.test(host)
    ? { host, port, family: 4, autoSelectFamily: false }
    : { host, port };
}

// The saved LAN target remains primary. A verified, explicitly configured VPN
// target is used only when the primary cannot complete the receiver handshake.
export class ReceiverRoute {
  constructor(primary, fallback) {
    if (fallback && !isTailscaleAddress(fallback)) throw new Error('Fallback must be a Tailscale address');
    this.primary = primary;
    this.fallback = fallback && fallback !== primary ? fallback : undefined;
    this.reset();
  }
  reset() { this.current = this.primary; }
  get canFallback() { return Boolean(this.fallback && this.current === this.primary); }
  advance() {
    if (!this.canFallback) return undefined;
    this.current = this.fallback; return this.current;
  }
}
