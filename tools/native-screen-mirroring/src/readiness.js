// The stock iPhone protocol has no foreground bit. Require playback feedback.
export class ReadinessGuard {
  constructor(onFailure, { timeoutMs = 10000, schedule = setTimeout, cancel = clearTimeout } = {}) {
    this.onFailure = onFailure; this.timeoutMs = timeoutMs;
    this.schedule = schedule; this.cancel = cancel;
  }
  start() {
    this.stop();
    this.timer = this.schedule(() => {
      this.timer = undefined;
      this.onFailure();
    }, this.timeoutMs);
  }
  observe(message) {
    if (message.type === 'stats' && Number.isFinite(message.fps) && message.fps > 0) {
      this.stop(); return true;
    }
    return false;
  }
  stop() { if (this.timer !== undefined) this.cancel(this.timer); this.timer = undefined; }
}
