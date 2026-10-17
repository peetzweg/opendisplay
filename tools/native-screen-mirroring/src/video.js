// Gate reconnects on an IDR and repeat cached parameter sets on every IDR.
export class VideoGate {
  constructor() { this.reset(); this.sps = undefined; this.pps = undefined; }
  reset() { this.waiting = true; }
  accept(body) {
    const starts = [];
    for (let i = 0; i + 3 < body.length; i++) {
      if (body[i] !== 0 || body[i + 1] !== 0) continue;
      const prefix = body[i + 2] === 1 ? 3 : body[i + 2] === 0 && body[i + 3] === 1 ? 4 : 0;
      if (prefix && i + prefix < body.length) {
        starts.push({ offset: i, header: i + prefix }); i += prefix - 1;
      }
    }
    // OpenDisplay's stock receiver splits only four-byte start codes.
    const nalus = starts.map((start, index) => {
      const nal = body.subarray(start.offset, starts[index + 1]?.offset ?? body.length);
      return start.header - start.offset === 3 ? Buffer.concat([Buffer.from([0]), nal]) : nal;
    });
    const normalized = starts.some(start => start.header - start.offset === 3)
      ? Buffer.concat([body.subarray(0, starts[0].offset), ...nalus]) : body;
    let idr = false, hasSps = false, hasPps = false;
    starts.forEach((start, index) => {
      const nal = nalus[index];
      const type = body[start.header] & 31;
      if (type === 7) { this.sps = Buffer.from(nal); hasSps = true; }
      if (type === 8) { this.pps = Buffer.from(nal); hasPps = true; }
      if (type === 5) idr = true;
    });
    if (idr && this.sps && this.pps) this.waiting = false;
    if (this.waiting) return null;
    if (idr) return Buffer.concat([...(hasSps ? [] : [this.sps]), ...(hasPps ? [] : [this.pps]), normalized]);
    return normalized;
  }
}

// Replay a complete current GOP only during idle startup. Starting at an IDR
// and retaining every following packet preserves H.264 reference ordering.
export class StartupReplay {
  constructor({ maxBytes = 4 * 1024 * 1024, idleMs = 1000, now = Date.now } = {}) {
    this.maxBytes = maxBytes; this.idleMs = idleMs; this.now = now; this.clear();
  }
  clear() { this.packets = []; this.bytes = 0; this.lastVideo = undefined; }
  observe(body) {
    let idr = false;
    for (let i = 0; i + 4 < body.length; i++)
      if (body[i] === 0 && body[i + 1] === 0 && body[i + 2] === 0 && body[i + 3] === 1 && (body[i + 4] & 31) === 5) idr = true;
    if (idr) { this.packets = []; this.bytes = 0; }
    this.lastVideo = this.now();
    if (!idr && !this.packets.length) return;
    this.bytes += body.length;
    if (this.bytes > this.maxBytes) { this.packets = []; return; }
    this.packets.push(Buffer.from(body));
  }
  take() {
    if (this.lastVideo === undefined || this.now() - this.lastVideo < this.idleMs) return [];
    this.lastVideo = this.now();
    return this.packets;
  }
}
