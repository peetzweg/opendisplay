import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn as spawnProcess, spawnSync } from 'node:child_process';
import net from 'node:net';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { Decoder } from '../src/protocol.js';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

function spawn(...args) {
  const child = spawnProcess(...args);
  child.auditLog = '';
  child.stderr?.on('data', bytes => { child.auditLog += bytes; });
  return child;
}

async function stopChild(child) {
  if (child.exitCode === null && child.signalCode === null) {
    const exited = once(child, 'exit'); child.kill();
    const forced = setTimeout(() => child.kill('SIGKILL'), 1500);
    try { await exited; } finally { clearTimeout(forced); }
  }
  assert.notEqual(child.signalCode, 'SIGKILL', 'Native shutdown must not need a forced kill');
  assert.doesNotMatch(child.auditLog, /ERROR: AddressSanitizer|runtime error:/, 'Native diagnostics must remain clean through shutdown');
}

test('isolated pairing identity rejects invalid UUIDs and retains the default when unset', {
  skip: process.env.RUN_NATIVE_TESTS !== '1', timeout: 10000,
}, () => {
  const binary = process.env.AIRPLAY_TEST_BINARY || fileURLToPath(new URL('../build/airplay-bridge', import.meta.url));
  for (const value of ['broken', 'gggggggg-0000-0000-0000-000000000000', '00000000_0000-0000-0000-000000000000']) {
    const result = spawnSync(binary, ['Invalid Identity Test'], { env: { ...process.env, MIRROR_PAIRING_ID: value }, timeout: 2000 });
    assert.equal(result.status, 1);
    assert.match(result.stderr.toString(), /Invalid MIRROR_PAIRING_ID/);
    assert.doesNotMatch(result.stderr.toString(), /AIRPLAY-READY/);
  }
  const dir = mkdtempSync(path.join(tmpdir(), 'mirror-pairing-default-'));
  try {
    const source = path.join(dir, 'default.c'), executable = path.join(dir, 'default');
    writeFileSync(source, '#include <stdio.h>\n#include "dnssdint.h"\nint main(void) { puts(AIRPLAY_PI); return 0; }\n');
    const compile = spawnSync('/usr/bin/clang', [source, '-I', fileURLToPath(new URL('../vendor/uxplay/lib', import.meta.url)), '-o', executable], { timeout: 5000 });
    assert.equal(compile.status, 0, compile.stderr.toString());
    const result = spawnSync(executable, [], { env: { ...process.env, MIRROR_PAIRING_ID: '' }, timeout: 2000 });
    assert.equal(result.status, 0);
    assert.equal(result.stdout.toString().trim(), '2e388006-13ba-4041-9a67-25dd4a43d536');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('closed phone fails fast and releases the real native approval wait', {
  skip: process.env.RUN_NATIVE_TESTS !== '1', timeout: 10000,
}, async () => {
  const reservation = net.createServer();
  reservation.listen(0, '127.0.0.1'); await once(reservation, 'listening');
  const phonePort = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  const child = spawn(process.execPath, [fileURLToPath(new URL('../src/bridge.js', import.meta.url))], {
    stdio: ['ignore', 'ignore', 'pipe'],
    env: { ...process.env, MIRROR_PAIRING_ID: randomUUID(), IPHONE_HOST: '127.0.0.1', IPHONE_PORT: String(phonePort),
      AIRPLAY_BINARY: process.env.AIRPLAY_TEST_BINARY || fileURLToPath(new URL('../build/airplay-bridge', import.meta.url)),
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
    await stopChild(child);
  }
});

test('native AirPlay receiver returns a complete RTSP capability plist', {
  skip: process.env.RUN_NATIVE_TESTS !== '1', timeout: 15000,
}, async () => {
  const binary = process.env.AIRPLAY_TEST_BINARY || fileURLToPath(new URL('../build/airplay-bridge', import.meta.url));
  const pairingID = randomUUID();
  const child = spawn(binary, ['iPhone Smoke Test'], { stdio: ['ignore', 'ignore', 'pipe'], env: { ...process.env, MIRROR_PAIRING_ID: pairingID, MIRROR_DEVICE_ID: '02:49:50:48:4f:60' } });
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
    const identity = spawnSync('/usr/bin/plutil', ['-extract', 'pi', 'raw', '-o', '-', '--', '-'], { input: result.body });
    assert.equal(identity.status, 0);
    assert.equal(identity.stdout.toString().trim(), pairingID);
    const capabilities = spawnSync('/usr/bin/plutil', ['-extract', 'features', 'raw', '-o', '-', '--', '-'], { input: result.body });
    assert.equal(capabilities.status, 0, capabilities.stderr.toString());
    const features = BigInt(capabilities.stdout.toString().trim());
    assert.notEqual(features & (1n << 9n), 0n, 'macOS requires audio capability to preserve the route during rotation; the native guard preserves actual audio output');
    assert.notEqual(features & (1n << 7n), 0n, 'Screen mirroring remains supported');
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
    const txt = await discovery;
    assert.ok(txt.includes(Buffer.from('model=AppleTV6,2')), 'Bonjour TXT uses the working receiver discovery model');
    assert.ok(txt.includes(Buffer.from(`pi=${pairingID}`)), 'TXT and /info use the same isolated pairing identity');
    assert.ok(txt.includes(Buffer.from(`psi=${pairingID}`)), 'Secondary TXT pairing identity is isolated too');
  } finally {
    socket?.destroy();
    await stopChild(child);
  }
});

for (const approved of [false, true]) test(`native SETUP ${approved ? 'accepts an approved phone' : 'rejects an unavailable phone before starting the display'}`, {
  skip: process.env.RUN_NATIVE_TESTS !== '1', timeout: 15000,
}, async () => {
  const binary = process.env.AIRPLAY_TEST_BINARY || fileURLToPath(new URL('../build/airplay-bridge', import.meta.url));
  const child = spawn(binary, ['iPhone Preflight Test'], {
    stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'],
    env: { ...process.env, MIRROR_PAIRING_ID: randomUUID(), MIRROR_EVENTS: '1', MIRROR_DEVICE_ID: approved ? '02:49:50:48:4f:62' : '02:49:50:48:4f:61' },
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
    await stopChild(child);
  }
});


test('native teardown diagnostics distinguish audio, video and full-session requests', {
  skip: process.env.RUN_NATIVE_TESTS !== '1', timeout: 10000,
}, async () => {
  const binary = process.env.AIRPLAY_TEST_BINARY || fileURLToPath(new URL('../build/airplay-bridge', import.meta.url));
  const child = spawn(binary, ['Teardown Test'], { stdio: ['ignore', 'ignore', 'pipe'],
    env: { ...process.env, MIRROR_PAIRING_ID: randomUUID(), MIRROR_DEVICE_ID: '02:49:50:48:4f:63' } });
  let log = '', socket;
  try {
    const port = await new Promise((resolve, reject) => {
      child.stderr.on('data', bytes => {
        log += bytes; const match = log.match(/AIRPLAY-READY .* port=(\d+)/);
        if (match) resolve(Number(match[1]));
      });
      child.once('error', reject); child.once('exit', code => reject(new Error(`Exited ${code}: ${log}`)));
    });
    for (const [type, expected] of [[96, 'audio=1 video=0'], [110, 'audio=0 video=1'], [null, 'audio=0 video=0']]) {
      socket = net.createConnection({ host: '127.0.0.1', port });
      await once(socket, 'connect');
      const encoded = spawnSync('/usr/bin/plutil', ['-convert', 'binary1', '-o', '-', '--', '-'], {
        input: JSON.stringify(type === null ? {} : { streams: [{ type }] }),
      });
      assert.equal(encoded.status, 0);
      const response = new Promise((resolve, reject) => {
        let text = ''; socket.on('error', reject); socket.on('data', bytes => {
          text += bytes.toString(); if (text.includes('\r\n\r\n')) resolve(text);
        });
      });
      socket.write(Buffer.concat([Buffer.from(`TEARDOWN rtsp://127.0.0.1/session RTSP/1.0\r\nCSeq: 3\r\nContent-Length: ${encoded.stdout.length}\r\n\r\n`), encoded.stdout]));
      assert.match(await response, /^RTSP\/1.0 200 OK/);
      const deadline = Date.now() + 1000;
      while (!log.includes(`AIRPLAY-TEARDOWN ${expected}`) && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
      assert.ok(log.includes(`AIRPLAY-TEARDOWN ${expected}`), log);
      socket.destroy();
    }
  } finally {
    socket?.destroy(); await stopChild(child);
  }
});

test('native receiver survives malformed and truncated requests and remains usable', {
  skip: process.env.RUN_NATIVE_TESTS !== '1', timeout: 15000,
}, async () => {
  const binary = process.env.AIRPLAY_TEST_BINARY || fileURLToPath(new URL('../build/airplay-bridge', import.meta.url));
  const child = spawn(binary, ['Malformed Request Test'], { stdio: ['ignore', 'ignore', 'pipe'],
    env: { ...process.env, MIRROR_PAIRING_ID: randomUUID(), MIRROR_DEVICE_ID: '02:49:50:48:4f:79' } });
  let log = '';
  try {
    const port = await new Promise((resolve, reject) => {
      child.stderr.on('data', bytes => { log += bytes; const match = log.match(/AIRPLAY-READY .* port=(\d+)/); if (match) resolve(Number(match[1])); });
      child.once('error', reject); child.once('exit', code => reject(new Error(`Exited ${code}: ${log}`)));
    });
    async function request(payload, health = false) {
      return new Promise((resolve, reject) => {
        const socket = net.createConnection({ host: '127.0.0.1', port });
        let response = '', done = false;
        const finish = error => {
          if (done) return; done = true; socket.destroy();
          if (error && health) reject(error); else resolve(response);
        };
        socket.setTimeout(health ? 2000 : 300, () => finish(new Error('Request timed out')));
        socket.on('error', finish);
        socket.on('close', () => finish(new Error('Connection closed')));
        socket.on('data', bytes => {
          response += bytes.toString();
          if (response.includes('\r\n\r\n')) finish();
        });
        socket.on('connect', () => { if (health) socket.write(payload); else socket.end(payload); });
      });
    }
    for (const payload of [
      'NOT RTSP\r\n\r\n',
      'GET /info RTSP/1.0\r\nCSeq: nope\r\n\r\n',
      'GET /info RTSP/1.0\r\nCSeq: 1\r\nContent-Length: -1\r\n\r\n',
      'SETUP rtsp://127.0.0.1/session RTSP/1.0\r\nCSeq: 2\r\nContent-Length: 64\r\n\r\nbplist00',
      'SETUP rtsp://127.0.0.1/session RTSP/1.0\r\nCSeq: 2\r\nContent-Length: 4\r\n\r\nNULL',
      'POST /fp-setup RTSP/1.0\r\nCSeq: 3\r\nContent-Length: 1\r\n\r\n\x00',
    ]) {
      await request(payload);
      assert.equal(child.exitCode, null, log); assert.equal(child.signalCode, null, log);
      assert.match(await request('GET /info RTSP/1.0\r\nCSeq: 99\r\n\r\n', true), /^RTSP\/1.0 200 OK/);
    }
    assert.doesNotMatch(log, /ERROR: AddressSanitizer|runtime error:/);
  } finally { await stopChild(child); }
});
