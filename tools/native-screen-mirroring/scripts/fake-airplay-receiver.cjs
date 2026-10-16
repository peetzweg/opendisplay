#!/usr/bin/env node
// Test fixture: drive native session events through the same fd 3 channel.
const fs = require('node:fs');
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
  setTimeout(() => {
    const video = Buffer.from([0, 0, 0, 1, 7, 0x88, 0, 0, 0, 1, 8, 0x88, 0, 0, 0, 1, 5, 0x88]);
    const length = Buffer.alloc(4); length.writeUInt32BE(video.length);
    process.stdout.write(Buffer.concat([length, video]));
  }, 30);
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
  if (!active) { awaitingApproval = false; emit({ active: false }); }
  else if (process.env.SESSION_PREFLIGHT === '1') { awaitingApproval = true; emit({ preflight: true }); }
  else stream();
}, 20);
console.error('FIXTURE-READY');
