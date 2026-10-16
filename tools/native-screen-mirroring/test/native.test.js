import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import net from 'node:net';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { Decoder } from '../src/protocol.js';

test('closed phone fails fast and releases the real native approval wait', {
  skip: process.env.RUN_NATIVE_TESTS !== '1', timeout: 10000,
}, async () => {
  const reservation = net.createServer();
  reservation.listen(0, '127.0.0.1'); await once(reservation, 'listening');
  const phonePort = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  const child = spawn(process.execPath, [fileURLToPath(new URL('../src/bridge.js', import.meta.url))], {
    stdio: ['ignore', 'ignore', 'pipe'],
    env: { ...process.env, IPHONE_HOST: '127.0.0.1', IPHONE_PORT: String(phonePort),
      AIRPLAY_BINARY: fileURLToPath(new URL('../build/airplay-bridge', import.meta.url)),
      MIRROR_DEVICE_ID: '02:49:50:48:4f:63', MIRROR_NAME: 'iPhone Fast Failure Test', MIRROR_ERROR_BINARY: '/usr/bin/false' },
  });
  let socket, log = '';
  try {
    const port = await new Promise((resolve, reject) => {
      child.stderr.on('data', bytes => {
        log += bytes;
        const match = log.match(/AIRPLAY-READY .* port=(\d+)/);
        if (match) resolve(Number(match[1]));
      });
      child.once('error', reject);
      child.once('exit', code => reject(new Error(`Bridge exited ${code}: ${log}`)));
    });
    socket = net.createConnection({ host: '127.0.0.1', port });
    socket.on('error', () => {});
    await once(socket, 'connect');
    const exited = once(child, 'exit');
    const started = performance.now();
    socket.write('SETUP rtsp://127.0.0.1/session RTSP/1.0\r\nCSeq: 2\r\nContent-Length: 0\r\n\r\n');
    await exited;
    assert.ok(performance.now() - started < 2500, `Native shutdown must not wait for the ten-second approval timeout: ${log}`);
    assert.equal((log.match(/IPHONE: connect ECONNREFUSED/g) || []).length, 2);
    assert.match(log, /receiver refused the connection/);
    assert.match(log, /skipping duplicate dialog/);
    assert.doesNotMatch(log, /AIRPLAY-SESSION started/);
  } finally {
    socket?.destroy();
    if (child.exitCode === null && child.signalCode === null) {
      const ended = once(child, 'exit'); child.kill(); await ended;
    }
  }
});

test('native AirPlay receiver returns a complete RTSP capability plist', {
  skip: process.env.RUN_NATIVE_TESTS !== '1', timeout: 15000,
}, async () => {
  const binary = process.env.AIRPLAY_TEST_BINARY || fileURLToPath(new URL('../build/airplay-bridge', import.meta.url));
  const child = spawn(binary, ['iPhone Smoke Test'], { stdio: ['ignore', 'ignore', 'pipe'], env: { ...process.env, MIRROR_DEVICE_ID: '02:49:50:48:4f:60' } });
  let socket;
  try {
    const port = await new Promise((resolve, reject) => {
      let log = '';
      child.stderr.on('data', bytes => {
        log += bytes;
        const match = log.match(/AIRPLAY-READY .* port=(\d+)/);
        if (match) resolve(Number(match[1]));
      });
      child.once('error', reject);
      child.once('exit', code => reject(new Error(`Receiver exited ${code}: ${log}`)));
    });
    socket = net.createConnection({ host: '127.0.0.1', port });
    socket.setTimeout(5000, () => socket.destroy(new Error('RTSP timeout')));
    await once(socket, 'connect');
    socket.write('GET /info RTSP/1.0\r\nCSeq: 1\r\n\r\n');
    const result = await new Promise((resolve, reject) => {
      let bytes = Buffer.alloc(0);
      socket.on('error', reject);
      socket.on('data', chunk => {
        bytes = Buffer.concat([bytes, chunk]);
        const end = bytes.indexOf('\r\n\r\n');
        if (end < 0) return;
        const headers = bytes.subarray(0, end).toString();
        const length = Number(headers.match(/Content-Length:\s*(\d+)/i)?.[1]);
        if (length > 0 && bytes.length >= end + 4 + length) resolve({ headers, body: bytes.subarray(end + 4, end + 4 + length) });
      });
    });
    assert.match(result.headers, /^RTSP\/1.0 200 OK/);
    assert.match(result.headers, /CSeq: 1/i);
    assert.equal(result.body.subarray(0, 8).toString(), 'bplist00');
    assert.ok(result.body.includes(Buffer.from('displays')));
    assert.ok(result.body.includes(Buffer.from('iPhone Smoke Test')));
    const model = spawnSync('/usr/bin/plutil', ['-extract', 'model', 'raw', '-o', '-', '--', '-'], { input: result.body });
    assert.equal(model.status, 0, model.stderr.toString());
    assert.equal(model.stdout.toString().trim(), 'AppleTV6,2');
    for (const [key, expected] of Object.entries({ width: 1288, height: 2796, maxFPS: 60 })) {
      const parsed = spawnSync('/usr/bin/plutil', ['-extract', `displays.0.${key}`, 'raw', '-o', '-', '--', '-'], { input: result.body });
      assert.equal(parsed.status, 0, parsed.stderr.toString());
      assert.equal(Number(parsed.stdout.toString()), expected);
    }
    const discovery = new Promise((resolve, reject) => {
      let bytes = Buffer.alloc(0);
      const receive = chunk => {
        bytes = Buffer.concat([bytes, chunk]);
        const end = bytes.indexOf('\r\n\r\n');
        if (end < 0) return;
        const length = Number(bytes.subarray(0, end).toString().match(/Content-Length:\s*(\d+)/i)?.[1]);
        if (length > 0 && bytes.length >= end + 4 + length) {
          socket.off('data', receive);
          resolve(bytes.subarray(end + 4, end + 4 + length));
        }
      };
      socket.on('data', receive);
      socket.once('error', reject);
    });
    socket.write('GET /info?txtAirPlay RTSP/1.0\r\n\r\n');
    assert.ok((await discovery).includes(Buffer.from('model=AppleTV6,2')), 'Bonjour TXT uses the working receiver discovery model');
  } finally {
    socket?.destroy();
    const ended = once(child, 'exit');
    child.kill('SIGTERM');
    await ended;
  }
});

for (const approved of [false, true]) test(`native SETUP ${approved ? 'accepts an approved phone' : 'rejects an unavailable phone before starting the display'}`, {
  skip: process.env.RUN_NATIVE_TESTS !== '1', timeout: 15000,
}, async () => {
  const binary = process.env.AIRPLAY_TEST_BINARY || fileURLToPath(new URL('../build/airplay-bridge', import.meta.url));
  const child = spawn(binary, ['iPhone Preflight Test'], {
    stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'],
    env: { ...process.env, MIRROR_EVENTS: '1', MIRROR_DEVICE_ID: approved ? '02:49:50:48:4f:62' : '02:49:50:48:4f:61' },
  });
  let socket;
  let log = '';
  try {
    const port = await new Promise((resolve, reject) => {
      child.stderr.on('data', bytes => {
        log += bytes;
        const match = log.match(/AIRPLAY-READY .* port=(\d+)/);
        if (match) resolve(Number(match[1]));
      });
      child.once('error', reject);
      child.once('exit', code => reject(new Error(`Receiver exited ${code}: ${log}`)));
    });
    const events = [];
    const decoder = new Decoder(payload => {
      const event = JSON.parse(payload);
      events.push(event);
      if (event.preflight) child.stdio[4].write(Buffer.from([approved ? 1 : 0]));
    });
    child.stdio[3].on('data', bytes => decoder.push(bytes));
    socket = net.createConnection({ host: '127.0.0.1', port });
    socket.setTimeout(5000, () => socket.destroy(new Error('RTSP timeout')));
    await once(socket, 'connect');
    const response = new Promise((resolve, reject) => {
      let result = '';
      socket.on('error', reject);
      socket.on('data', bytes => {
        result += bytes.toString();
        if (result.includes('\r\n\r\n')) resolve(result);
      });
    });
    const converted = spawnSync('/usr/bin/plutil', ['-convert', 'binary1', '-o', '-', '--', '-'], {
      input: '<?xml version="1.0"?><plist version="1.0"><dict/></plist>',
    });
    assert.equal(converted.status, 0, converted.stderr.toString());
    socket.write(`SETUP rtsp://127.0.0.1/session RTSP/1.0\r\nCSeq: 2\r\nContent-Length: ${converted.stdout.length}\r\n\r\n`);
    socket.write(converted.stdout);
    assert.match(await response, approved ? /^RTSP\/1.0 200 OK/ : /^RTSP\/1.0 503 Service Unavailable/);
    assert.deepEqual(events, [{ preflight: true }]);
    assert.doesNotMatch(log, /AIRPLAY-SESSION started/);
  } finally {
    socket?.destroy();
    const ended = once(child, 'exit');
    child.kill('SIGTERM');
    await ended;
  }
});
