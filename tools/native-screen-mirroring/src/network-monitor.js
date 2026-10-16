import { networkInterfaces } from 'node:os';

export function networkSignature(interfaces = networkInterfaces()) {
  return JSON.stringify(Object.entries(interfaces).flatMap(([name, addresses]) =>
    (addresses || []).filter(address => !address.internal)
      .map(address => `${name}:${address.family}:${address.address}:${address.scopeid || 0}`)).sort());
}

// Recreate the native mDNS sockets after address changes or waking from sleep.
// Defer until idle so a working display is never torn down by this monitor.
export class NetworkMonitor {
  constructor({ read = networkSignature, now = Date.now, isActive, onRefresh, settleMs = 3000, wakeMs = 15000 }) {
    Object.assign(this, { read, now, isActive, onRefresh, settleMs, wakeMs });
    this.signature = read();
    this.lastTick = now();
    this.pendingSince = null;
  }

  tick() {
    const time = this.now(), signature = this.read();
    if (signature !== this.signature || time - this.lastTick > this.wakeMs) {
      this.signature = signature;
      this.pendingSince = time;
    }
    this.lastTick = time;
    if (this.pendingSince !== null && time - this.pendingSince >= this.settleMs && !this.isActive()) {
      this.pendingSince = null;
      this.onRefresh();
    }
  }

  start() { this.timer = setInterval(() => this.tick(), 2000); }
  close() { clearInterval(this.timer); }
}
