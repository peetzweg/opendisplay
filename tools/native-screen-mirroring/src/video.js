// Gate reconnects on an IDR and repeat cached parameter sets on every IDR.
export class VideoGate {
  constructor() { this.reset(); this.sps = undefined; this.pps = undefined; }
  reset() { this.waiting = true; }
  accept(body) {
    const starts = [];
    for (let i = 0; i + 4 < body.length; i++) {
      if (body.readUInt32BE(i) === 1) { starts.push(i); i += 3; }
    }
    let idr = false, hasSps = false, hasPps = false;
    starts.forEach((start, index) => {
      const nal = body.subarray(start, starts[index + 1] ?? body.length);
      const type = nal[4] & 31;
      if (type === 7) { this.sps = Buffer.from(nal); hasSps = true; }
      if (type === 8) { this.pps = Buffer.from(nal); hasPps = true; }
      if (type === 5) idr = true;
    });
    if (idr && this.sps && this.pps) this.waiting = false;
    if (this.waiting) return null;
    if (idr) return Buffer.concat([...(hasSps ? [] : [this.sps]), ...(hasPps ? [] : [this.pps]), body]);
    return body;
  }
}
