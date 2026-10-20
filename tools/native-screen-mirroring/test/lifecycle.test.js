import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, chmodSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { frame, Decoder } from '../src/protocol.js';

test('AirPlay disconnect closes the phone session, stays idle, and reconnects on selection', {
  skip: process.env.RUN_NATIVE_TESTS !== '1', timeout: 15000,
}, async () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'mirror-lifecycle-'));
  const control = path.join(dir, 'active'); writeFileSync(control, 'false');
  const fixture = fileURLToPath(new URL('../scripts/fake-airplay-receiver.cjs', import.meta.url));
  chmodSync(fixture, 0o755);
  const rejection = path.join(dir, 'sidecar-event'), marker = path.join(dir, 'sidecar-help');
  writeFileSync(rejection, '');
  const bootstrap = path.join(dir, 'bootstrap.cjs');
  const bridge = fileURLToPath(new URL('../src/bridge.js', import.meta.url));
  // Intercept only log access inside this isolated child. Production keeps the
  // fixed system log command; no test command override is installed or shipped.
  const logFixture = `const fs=require('node:fs');let previous='';setInterval(()=>{const text=fs.readFileSync(${JSON.stringify(rejection)},'utf8');if(text!==previous){previous=text;process.stdout.write(text)}},20);`;
  writeFileSync(bootstrap, `const cp=require('node:child_process'),original=cp.spawn;
cp.spawn=(binary,args,options)=>{
  if(binary==='/usr/bin/log') return original(process.execPath,['-e',${JSON.stringify(logFixture)}],options);
  if(args?.[0]==='sidecar') return original(process.execPath,['-e',${JSON.stringify(`require('node:fs').appendFileSync(${JSON.stringify(marker)},'sidecar\\n')`)}],options);
  return original(binary,args,options);
};require('node:module').syncBuiltinESMExports();import(${JSON.stringify(bridge)});`);
  const connections = [], welcomes = [], videos = [];
  const server = net.createServer(socket => {
    connections.push(socket);
    setTimeout(() => { if (!socket.destroyed) socket.write(frame({ type: 'hello', pv: 3 })); }, 150);
    const decoder = new Decoder(body => {
      if (body[0] === 0) { videos.push(body); socket.write(frame({ type: 'stats', fps: 1 })); }
      else if (JSON.parse(body).type === 'welcome') welcomes.push(socket);
    });
    socket.on('data', data => decoder.push(data));
    socket.on('error', () => {});
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const child = spawn(process.execPath, [bootstrap], {
    env: { ...process.env, IPHONE_HOST: '127.0.0.1', IPHONE_PORT: String(server.address().port), AIRPLAY_BINARY: fixture, SESSION_CONTROL_FILE: control, SESSION_PREFLIGHT: '1' },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let log = ''; child.stderr.on('data', data => { log += data; });
  async function until(predicate) {
    const deadline = Date.now() + 3000;
    while (!predicate()) {
      assert.equal(child.exitCode, null, log);
      if (Date.now() >= deadline) throw new Error(`Timed out: ${log}`);
      await delay(20);
    }
  }
  try {
    await until(() => log.includes('FIXTURE-READY'));
    await delay(100); assert.equal(connections.length, 0, 'Idle service must not connect to the phone');
    writeFileSync(control, 'true'); await until(() => welcomes.length === 1);
    await until(() => videos.length === 1);
    assert.ok(log.indexOf('IPHONE-READY') < log.indexOf('FIXTURE-STREAM-STARTED'), 'AirPlay starts only after the phone handshake');
    assert.equal(videos[0][4] & 31, 7, 'Startup video retains SPS before the first IDR');
    writeFileSync(rejection, JSON.stringify({ processImagePath: '/System/Library/CoreServices/SidecarDisplayAgent', eventMessage: 'SidecarErrorDisplayAirPlayBusy (-453)' }) + '\n');
    await until(() => existsSync(marker));
    assert.equal(readFileSync(marker, 'utf8'), 'sidecar\n');
    assert.equal(connections[0].destroyed, false, 'Sidecar guidance must leave the phone connected');
    assert.doesNotMatch(log, /IPHONE-NOT-READY|AIRPLAY-EXIT/);
    connections[0].write(frame({ type: 'hello', pv: 3, pixelsWide: 2796, pixelsHigh: 1290 }));
    await until(() => welcomes.length === 2);
    assert.equal(connections.length, 1, 'Rotation hello is acknowledged on the existing connection');
    assert.equal((log.match(/FIXTURE-STREAM-STARTED/g) || []).length, 1, 'Rotation must not restart AirPlay');
    const closed = once(connections[0], 'close');
    writeFileSync(control, 'false'); await closed;
    await delay(3200); assert.equal(connections.length, 1, 'Disconnect must cancel phone retries');
    writeFileSync(control, 'true'); await until(() => welcomes.length === 3);
    await until(() => videos.length === 2);
    assert.equal(connections.length, 2);
  } finally {
    const exited = child.exitCode === null ? once(child, 'exit') : Promise.resolve();
    child.kill(); await exited;
    for (const socket of connections) socket.destroy();
    await new Promise(resolve => server.close(resolve));
    rmSync(dir, { recursive: true });
  }
});

for (const scenario of [
  { name: 'background-like receiver handshakes but no playback triggers teardown', hello: true },
  { name: 'silent receiver fails the shorter answer deadline without waiting for playback', hello: false },
]) test(scenario.name, {
  skip: process.env.RUN_NATIVE_TESTS !== '1', timeout: 10000,
}, async () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'mirror-not-ready-'));
  const control = path.join(dir, 'active'), marker = path.join(dir, 'error');
  writeFileSync(control, 'true');
  const fixture = fileURLToPath(new URL('../scripts/fake-airplay-receiver.cjs', import.meta.url));
  const errorFixture = fileURLToPath(new URL('../scripts/fake-readiness-error.cjs', import.meta.url));
  chmodSync(fixture, 0o755); chmodSync(errorFixture, 0o755);
  let connection, closed = false;
  const server = net.createServer(socket => {
    connection = socket;
    socket.on('error', () => {}); socket.on('data', () => {});
    socket.on('close', () => { closed = true; });
    if (scenario.hello) {
      socket.write(frame({ type: 'hello', pv: 3 }));
      socket.write(frame({ type: 'stats', fps: 0 }));
    }
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const child = spawn(process.execPath, [fileURLToPath(new URL('../src/bridge.js', import.meta.url))], {
    env: { ...process.env, IPHONE_HOST: '127.0.0.1', IPHONE_PORT: String(server.address().port), AIRPLAY_BINARY: fixture,
      SESSION_CONTROL_FILE: control, SESSION_PREFLIGHT: '1', MIRROR_READY_TIMEOUT_MS: '600', MIRROR_HELLO_TIMEOUT_MS: '200', MIRROR_ERROR_BINARY: errorFixture, ERROR_MARKER: marker },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let log = ''; child.stderr.on('data', data => { log += data; });
  try {
    await once(child, 'exit');
    const deadline = Date.now() + 2000;
    while (((scenario.hello && !existsSync(marker)) || !closed) && Date.now() < deadline) await delay(20);
    if (!scenario.hello) await delay(200);
    if (scenario.hello) assert.match(log, /IPHONE-READY/);
    else { assert.doesNotMatch(log, /IPHONE-READY|FIXTURE-STREAM-STARTED/); assert.match(log, /receiver did not answer/); }
    assert.match(log, /IPHONE-NOT-READY/);
    assert.ok(closed, 'Unready phone socket closes');
    assert.equal(existsSync(marker), scenario.hello, 'Only playback failure launches the custom dialog; preflight rejection uses the macOS error');
    if (!scenario.hello) assert.match(log, /skipping duplicate dialog/);
  } finally {
    child.kill(); connection?.destroy();
    await new Promise(resolve => server.close(resolve));
    rmSync(dir, { recursive: true });
  }
});


test('idle startup requests fresh frames, then stops probing without an ongoing FPS deadline', {
  skip: process.env.RUN_NATIVE_TESTS !== '1', timeout: 10000,
}, async () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'mirror-static-'));
  const control = path.join(dir, 'active'); writeFileSync(control, 'true');
  let connection, videos = 0;
  const server = net.createServer(socket => {
    connection = socket; socket.on('error', () => {});
    const decoder = new Decoder(body => {
      if (body[0] === 0 && ++videos === 3) socket.write(frame({ type: 'stats', fps: 1 }));
    });
    socket.on('data', bytes => decoder.push(bytes));
    socket.write(frame({ type: 'hello', pv: 3 }));
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const child = spawn(process.execPath, [fileURLToPath(new URL('../src/bridge.js', import.meta.url))], {
    env: { ...process.env, IPHONE_HOST: '127.0.0.1', IPHONE_PORT: String(server.address().port),
      AIRPLAY_BINARY: fileURLToPath(new URL('../scripts/fake-airplay-receiver.cjs', import.meta.url)),
      SESSION_CONTROL_FILE: control, SESSION_PREFLIGHT: '1', SESSION_KEYFRAME_VIDEO: '1',
      MIRROR_READY_TIMEOUT_MS: '1200', MIRROR_STARTUP_KEYFRAME_MS: '100' },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let log = ''; child.stderr.on('data', bytes => { log += bytes; });
  try {
    const deadline = Date.now() + 3000;
    while (!log.includes('IPHONE-PLAYBACK confirmed')) {
      assert.equal(child.exitCode, null, log);
      assert.ok(Date.now() < deadline, log); await delay(20);
    }
    assert.equal(videos, 3, 'Playback needs multiple requested frames');
    await delay(1500);
    assert.equal(videos, 3, 'Confirmed playback cancels startup probes');
    assert.equal(child.exitCode, null, log);
    assert.doesNotMatch(log, /IPHONE-NOT-READY/);
    const closed = once(connection, 'close');
    writeFileSync(control, 'false'); await closed;
    assert.equal(videos, 3);
  } finally {
    const exited = child.exitCode === null ? once(child, 'exit') : Promise.resolve();
    child.kill(); await exited; connection?.destroy();
    await new Promise(resolve => server.close(resolve)); rmSync(dir, { recursive: true });
  }
});
