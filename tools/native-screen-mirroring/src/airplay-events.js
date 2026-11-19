import net from 'node:net';
import { spawnSync } from 'node:child_process';

export function panelSize(message) {
  const panel = message.panel || message;
  const width = panel.pixelsWide ?? panel.width ?? message.pixelsWide;
  const height = panel.pixelsHigh ?? panel.height ?? message.pixelsHigh;
  if (![width, height].every(n => Number.isInteger(n) && n >= 320 && n <= 8192)) return null;
  return { width: Math.floor(width / 4) * 4, height: Math.floor(height / 4) * 4 };
}

export function encodeEvent(value, sequence) {
  const converted = spawnSync('/usr/bin/plutil', ['-convert', 'binary1', '-o', '-', '--', '-'], {
    input: JSON.stringify(value), maxBuffer: 1024 * 1024,
  });
  if (converted.status !== 0 || converted.stdout.subarray(0, 8).toString() !== 'bplist00')
    throw new Error('Could not encode AirPlay event plist');
  const header = `POST /command RTSP/1.0\r\nCSeq: ${sequence}\r\nContent-Type: application/x-apple-binary-plist\r\nContent-Length: ${converted.stdout.length}\r\n\r\n`;
  return Buffer.concat([Buffer.from(header), converted.stdout]);
}

export class AirPlayEvents {
  constructor({ width = 1288, height = 2796, debounceMs = 300, onChange = () => {}, onError = () => {} } = {}) {
    this.baseline = `${width}x${height}`;
    this.lastSent = this.baseline;
    this.debounceMs = debounceMs;
    this.onChange = onChange; this.onError = onError;
    this.sequence = 0; this.active = false;
    this.server = net.createServer(socket => this.accept(socket));
  }
  start() {
    return new Promise((resolve, reject) => {
      this.server.once('error', reject);
      this.server.listen(0, '::', () => resolve(this.server.address().port));
    });
  }
  accept(socket) {
    // Match the native receiver's same-Mac restriction, including IPv6 zones.
    if (socket.remoteAddress?.split('%')[0] !== socket.localAddress?.split('%')[0]) return socket.destroy();
    this.socket?.destroy(); this.socket = socket;
    let pending = Buffer.alloc(0);
    socket.on('error', error => this.onError(error.message));
    socket.on('close', () => { if (this.socket === socket) this.socket = undefined; });
    socket.on('data', bytes => {
      pending = Buffer.concat([pending, bytes]);
      if (pending.length > 1024 * 1024) return socket.destroy();
      while (pending.length) {
        const end = pending.indexOf('\r\n\r\n');
        if (end < 0) { if (pending.length > 16384) socket.destroy(); return; }
        const headers = pending.subarray(0, end).toString();
        const length = Number(headers.match(/Content-Length:\s*(\d+)/i)?.[1] || 0);
        if (length > 1024 * 1024) return socket.destroy();
        if (pending.length < end + 4 + length) return;
        if (!/^RTSP\/1.0 200\b/.test(headers)) this.onError('Mac rejected the display update');
        pending = pending.subarray(end + 4 + length);
      }
    });
    this.schedule();
  }
  observeHello(message) {
    const size = panelSize(message);
    if (!size) return;
    if (size.width === this.desired?.width && size.height === this.desired?.height) return;
    this.desired = size; this.schedule();
  }
  setActive(active) {
    this.active = active;
    if (active) this.schedule();
    else {
      clearTimeout(this.timer); this.desired = undefined; this.lastSent = this.baseline;
      this.socket?.destroy(); this.socket = undefined;
    }
  }
  schedule() {
    clearTimeout(this.timer);
    if (!this.active || !this.socket || !this.desired) return;
    this.timer = setTimeout(() => this.flush(), this.debounceMs);
  }
  flush() {
    if (!this.active || !this.socket || this.socket.destroyed || !this.desired) return;
    const { width, height } = this.desired;
    const key = `${width}x${height}`;
    if (key === this.lastSent) return;
    try {
      const packet = encodeEvent({ type: 'updateDisplayInfo', displays: [{
        uuid: 'e0ff8a27-6738-3d56-8a16-cc53aacee925',
        width, height, widthPixels: width, heightPixels: height,
        widthPhysical: 0, heightPhysical: 0, rotation: false,
        refreshRate: 1 / 60, maxFPS: 60, overscanned: false, features: 14,
      }] }, ++this.sequence);
      this.socket.write(packet); this.lastSent = key;
      this.onChange({ width, height });
    } catch (error) { this.onError(error.message); }
  }
  requestKeyframe() {
    if (!this.active || !this.socket || this.socket.destroyed) return;
    try { this.socket.write(encodeEvent({ type: 'forceKeyFrame' }, ++this.sequence)); }
    catch (error) { this.onError(error.message); }
  }
  close() {
    this.setActive(false); this.server.close();
  }
}
