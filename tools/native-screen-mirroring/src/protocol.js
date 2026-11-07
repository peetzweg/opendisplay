export function frame(payload) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(JSON.stringify(payload));
  const header = Buffer.alloc(4);
  header.writeUInt32BE(body.length);
  return Buffer.concat([header, body]);
}

export class Decoder {
  #pending = Buffer.alloc(0);
  constructor(onFrame, maxLength = 1024 * 1024 - 1) {
    this.onFrame = onFrame;
    this.maxLength = maxLength;
  }
  push(chunk) {
    this.#pending = Buffer.concat([this.#pending, chunk]);
    while (this.#pending.length >= 4) {
      const length = this.#pending.readUInt32BE(0);
      if (!length || length > this.maxLength) throw new Error('Invalid frame length');
      if (this.#pending.length < length + 4) return;
      const payload = this.#pending.subarray(4, length + 4);
      this.#pending = this.#pending.subarray(length + 4);
      this.onFrame(payload);
    }
  }
}
