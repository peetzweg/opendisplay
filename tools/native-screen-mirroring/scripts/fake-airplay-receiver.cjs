#!/usr/bin/env node
// Test fixture: drive native session events through the same fd 3 channel.
const fs = require('node:fs');
const net = require('node:net');
let eventPeer;
let videoTimer;
let blocked = false;
process.stdout.on('drain', () => { blocked = false; });
function video() {
  if (blocked) return;
  const body = process.env.SESSION_VIDEO_FILE ? fs.readFileSync(process.env.SESSION_VIDEO_FILE)
    : Buffer.from([0, 0, 0, 1, 7, 0x88, 0, 0, 0, 1, 8, 0x88, 0, 0, 0, 1, 5, 0x88]);
  const length = Buffer.alloc(4); length.writeUInt32BE(body.length);
  if (!process.stdout.write(Buffer.concat([length, body]))) {
    blocked = true; console.error('FIXTURE-VIDEO-BACKPRESSURE');
  }
}
let previous;
let awaitingApproval = false;
function emit(message) {
  const body = Buffer.from(JSON.stringify(message));
  const header = Buffer.alloc(4); header.writeUInt32BE(body.length);
  fs.writeSync(3, Buffer.concat([header, body]));
}
function stream() {
  emit({ active: true });
  console.error('FIXTURE-STREAM-STARTED');
  if (process.env.SESSION_VIDEO_INTERVAL_MS)
    videoTimer = setInterval(video, Number(process.env.SESSION_VIDEO_INTERVAL_MS));
  if (process.env.SESSION_KEYFRAME_VIDEO === '1') {
    eventPeer = net.createConnection({ host: '127.0.0.1', port: Number(process.env.MIRROR_EVENT_PORT) });
    let pending = Buffer.alloc(0);
    eventPeer.on('error', () => {});
    eventPeer.on('data', bytes => {
      pending = Buffer.concat([pending, bytes]);
      while (pending.length) {
        const end = pending.indexOf('\r\n\r\n');
        if (end < 0) return;
        const header = pending.subarray(0, end).toString();
        const length = Number(header.match(/Content-Length: (\d+)/)[1]);
        if (pending.length < end + 4 + length) return;
        const body = pending.subarray(end + 4, end + 4 + length);
        pending = pending.subarray(end + 4 + length);
        eventPeer.write(`RTSP/1.0 200 OK\r\nCSeq: ${header.match(/CSeq: (\d+)/)[1]}\r\nContent-Length: 0\r\n\r\n`);
        if (body.includes(Buffer.from('updateDisplayInfo'))) {
          const decoded = require('node:child_process').spawnSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '--', '-'], { input: body });
          if (decoded.status !== 0) throw new Error('Fixture could not decode display event');
          console.error('FIXTURE-DISPLAY', decoded.stdout.toString().trim());
        }
        if (body.includes(Buffer.from('forceKeyFrame'))) video();
      }
    });
  } else setTimeout(video, 30);
}
if (process.env.SESSION_PREFLIGHT === '1') {
  const input = fs.createReadStream(null, { fd: 4, autoClose: false });
  input.on('data', bytes => {
    if (awaitingApproval && previous && bytes.includes(1)) { awaitingApproval = false; stream(); }
  });
}
setInterval(() => {
  const active = fs.readFileSync(process.env.SESSION_CONTROL_FILE, 'utf8') === 'true';
  if (active === previous) return;
  previous = active;
  if (!active) { clearInterval(videoTimer); eventPeer?.destroy(); awaitingApproval = false; emit({ active: false }); }
  else if (process.env.SESSION_PREFLIGHT === '1') { awaitingApproval = true; emit({ preflight: true }); }
  else stream();
}, 20);
console.error('FIXTURE-READY');
