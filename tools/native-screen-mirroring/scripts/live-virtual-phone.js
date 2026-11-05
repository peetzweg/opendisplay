// Native AirPlay -> real bridge -> local H.264 decoder. Does not emulate iOS rendering.
import net from 'node:net';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { Decoder, frame } from '../src/protocol.js';
import { liveTestResult } from './live-test-result.js';
import { randomUUID } from 'node:crypto';

const root = fileURLToPath(new URL('..', import.meta.url));
const sockets = new Set(), decoders = new Set();
let bridge, packets = 0, decoded = 0, sessions = 0, closing = false, unexpectedDisconnects = 0, validatedRotations = 0;
function finish() {
  if (closing) return;
  closing = true;
  clearTimeout(deadline); clearInterval(summary);
  bridge?.kill();
  for (const socket of sockets) socket.destroy();
  for (const decoder of decoders) {
    decoder.stdin?.end(); decoder.kill();
    const forced = setTimeout(() => decoder.kill('SIGKILL'), 1000);
    forced.unref(); decoder.once('exit', () => clearTimeout(forced));
  }
  server.close();
  const metrics = { sessions, packets, decoded, unexpectedDisconnects, validatedRotations };
  if (process.env.LIVE_SELF_TEST !== '1') {
    const result = liveTestResult(metrics);
    process.exitCode ??= result.exitCode;
    console.log('LIVE-RESULT', JSON.stringify(result));
  }
  console.log('LIVE-FINAL', JSON.stringify(metrics));
}
const server = net.createServer(socket => {
  sockets.add(socket); sessions++;
  console.log('LIVE-PHONE connected', sessions);
  let sessionFrames = 0, pending = '', rotationTimer, expectedOrientation, decodeLog = '';
  const decoder = spawn(process.env.FFMPEG_BINARY || '/opt/homebrew/bin/ffmpeg', [
    '-hide_banner', '-loglevel', 'info', '-probesize', '32', '-analyzeduration', '0',
    '-f', 'h264', '-i', 'pipe:0', '-an', '-vf', 'showinfo', '-f', 'null', '-', '-progress', 'pipe:1', '-stats_period', '0.2',
  ], { stdio: ['pipe', 'pipe', 'pipe'] });
  decoders.add(decoder);
  decoder.stdin.on('error', error => console.error('LIVE-DECODE-INPUT', error.message));
  decoder.on('error', error => { console.error('LIVE-DECODE', error.message); finish(); process.exitCode = 1; });
  decoder.stderr.on('data', bytes => {
    decodeLog += bytes;
    const lines = decodeLog.split('\n'); decodeLog = lines.pop();
    for (const line of lines) {
      const dimensions = line.match(/Parsed_showinfo_.*\bn:\s*\d+ .*\bs:(\d+)x(\d+)/);
      if (dimensions && expectedOrientation) {
        const orientation = Number(dimensions[1]) > Number(dimensions[2]) ? 'landscape' : 'portrait';
        if (orientation === expectedOrientation) {
          validatedRotations++; expectedOrientation = undefined;
          console.log('LIVE-ROTATION-DECODED', orientation);
        }
      }
      if (/error|invalid|failed/i.test(line)) console.error('LIVE-DECODE', line);
    }
  });
  decoder.stdout.on('data', bytes => {
    pending += bytes;
    const lines = pending.split('\n'); pending = lines.pop();
    for (const line of lines) if (line.startsWith('frame=')) {
      const next = Number(line.slice(6).trim());
      if (next > sessionFrames) {
        decoded += next - sessionFrames; sessionFrames = next;
        // Feedback is grounded in FFmpeg output, not just received video packets.
        if (!socket.destroyed) socket.write(frame({ type: 'stats', fps: 1 }));
      }
    }
  });
  const sendHello = (width, height) => socket.write(frame({ type: 'hello', pv: 3,
    name: 'Virtual iPhone decoder', pixelsWide: width, pixelsHigh: height }));
  const protocol = new Decoder(body => {
    if (body[0] === 0) {
      packets++;
      if (!decoder.stdin.write(body)) socket.pause();
      if (process.env.LIVE_SELF_TEST === '1') decoder.stdin.end();
    } else {
      const message = JSON.parse(body);
      if (message.type === 'ping') socket.write(frame({ type: 'ping', t: message.t }));
      if (message.type === 'welcome') console.log('LIVE-WELCOME');
    }
  }, 16 * 1024 * 1024);
  decoder.stdin.on('drain', () => socket.resume());
  socket.on('data', bytes => { try { protocol.push(bytes); } catch (error) { console.error('LIVE-PROTOCOL', error.message); socket.destroy(); } });
  socket.on('error', error => console.error('LIVE-SOCKET', error.message));
  socket.on('close', () => {
    if (!closing) unexpectedDisconnects++;
    sockets.delete(socket); clearInterval(rotationTimer);
    decoder.stdin.end(); decoder.kill(); decoders.delete(decoder);
    console.log('LIVE-PHONE disconnected');
  });
  decoder.on('exit', (code, signal) => {
    decoders.delete(decoder);
    if (process.env.LIVE_SELF_TEST === '1' && !closing) {
      console.log('LIVE-SELF-TEST', code === 0 && decoded === 20 ? 'PASS' : 'FAIL');
      process.exitCode = code === 0 && decoded === 20 ? 0 : 1;
      finish(); return;
    }
    if (!socket.destroyed && !closing) { console.error('LIVE-DECODER-EXIT', code, signal); socket.destroy(); }
  });
  sendHello(1290, 2796);
  let landscape = false;
  rotationTimer = setInterval(() => {
    if (!sessionFrames || socket.destroyed) return;
    landscape = !landscape;
    expectedOrientation = landscape ? 'landscape' : 'portrait';
    sendHello(...(landscape ? [2796, 1290] : [1290, 2796]));
    console.log('LIVE-ROTATION', landscape ? 'landscape' : 'portrait');
  }, 10000);
});
server.on('error', error => { console.error(error.message); finish(); process.exitCode = 1; });
server.listen(0, '127.0.0.1', () => {
  if (process.env.LIVE_SELF_TEST === '1') {
    // Exercise the same phone TCP and FFmpeg decoding path with valid H.264.
    const source = spawn('/opt/homebrew/bin/ffmpeg', ['-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'testsrc=size=320x640:rate=10', '-t', '2', '-pix_fmt', 'yuv420p',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency', '-f', 'h264', 'pipe:1'],
    { stdio: ['ignore', 'pipe', 'inherit'] });
    decoders.add(source);
    const chunks = [];
    source.stdout.on('data', bytes => chunks.push(bytes));
    source.on('error', error => { console.error(error.message); process.exitCode = 1; finish(); });
    source.on('exit', code => {
      decoders.delete(source);
      if (code !== 0) { process.exitCode = 1; finish(); return; }
      const sender = net.createConnection({ host: '127.0.0.1', port: server.address().port });
      sockets.add(sender);
      sender.on('error', error => { console.error(error.message); process.exitCode = 1; finish(); });
      sender.on('data', () => {});
      sender.on('connect', () => sender.write(frame(Buffer.concat(chunks))));
    });
    return;
  }
  bridge = spawn(process.execPath, ['src/bridge.js'], { cwd: root,
    env: { ...process.env, IPHONE_HOST: '127.0.0.1', IPHONE_PORT: String(server.address().port),
      AIRPLAY_BINARY: fileURLToPath(new URL('../build/airplay-bridge', import.meta.url)),
      MIRROR_NAME: 'Virtual iPhone Test', MIRROR_DEVICE_ID: '02:49:50:48:4f:72',
      MIRROR_PAIRING_ID: randomUUID(),
      MIRROR_HOST_LABEL: 'opendisplay-virtual-phone-test', MIRROR_LOCAL_ONLY: '1', MIRROR_ERROR_BINARY: '/usr/bin/false' },
    stdio: ['ignore', 'ignore', 'pipe'] });
  bridge.stderr.on('data', bytes => process.stderr.write(bytes));
  bridge.on('error', error => { console.error(error.message); finish(); process.exitCode = 1; });
  bridge.on('exit', (code, signal) => {
    if (!closing) { console.error('LIVE-BRIDGE-EXIT', code, signal); finish(); process.exitCode = 1; }
  });
  console.log('LIVE-READY: select Virtual iPhone Test in native Screen Mirroring');
});
const summary = setInterval(() => console.log('LIVE-SUMMARY', JSON.stringify({ sessions, packets, decoded })), 5000);
const deadline = setTimeout(() => {
  if (process.env.LIVE_SELF_TEST === '1') process.exitCode = 1;
  finish();
}, Number(process.env.LIVE_TEST_DURATION_MS || 180000));
process.on('SIGINT', finish); process.on('SIGTERM', finish);
