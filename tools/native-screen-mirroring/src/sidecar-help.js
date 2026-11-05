import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

// Sidecar rejects before contacting our receiver. Observe only its specific
// rejection; never change routes, displays, or the active phone connection.
export const sidecarPredicate = '(process == "SidecarDisplayAgent" OR process == "ControlCenter") AND (eventMessage CONTAINS "SidecarErrorDisplayAirPlayBusy" OR eventMessage CONTAINS "Sidecar is not available while AirPlay Screen is active")';

export function isSidecarBusy(event) {
  return typeof event?.processImagePath === 'string'
    && ['SidecarDisplayAgent', 'ControlCenter'].includes(event.processImagePath.split('/').pop())
    && typeof event.eventMessage === 'string'
    && /\bSidecarErrorDisplayAirPlayBusy\b|Sidecar is not available while AirPlay Screen is active/.test(event.eventMessage);
}

export class SidecarHelp {
  constructor({ show, run = spawn, now = Date.now, onError = () => {} }) {
    Object.assign(this, { show, run, now, onError });
    this.lastShown = -Infinity;
  }

  setActive(active) {
    if (!active) { this.close(); return; }
    if (this.child) return;
    try {
      const child = this.run('/usr/bin/log', ['stream', '--style', 'ndjson', '--level', 'info', '--predicate', sidecarPredicate],
        { stdio: ['ignore', 'pipe', 'ignore'] });
      this.child = child;
      this.lines = createInterface({ input: child.stdout });
      this.lines.on('error', error => { if (this.child === child) this.onError(error.message); });
      this.lines.on('line', line => {
        if (this.child !== child) return;
        let event;
        try { event = JSON.parse(line); } catch { return; }
        if (!isSidecarBusy(event) || this.now() - this.lastShown < 30000) return;
        this.lastShown = this.now();
        this.show();
      });
      child.on('error', error => { if (this.child === child) this.onError(error.message); });
      child.on('exit', () => { if (this.child === child) this.close(); });
    } catch (error) { this.close(); this.onError(error.message); }
  }

  close() {
    const child = this.child;
    this.child = undefined;
    this.lines?.close(); this.lines = undefined;
    child?.kill();
  }
}
