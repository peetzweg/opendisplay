import { test } from 'node:test';
import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { virtualPhone } from './support/virtual-phone.js';
import { frame } from '../src/protocol.js';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const options = { skip: process.env.RUN_VIRTUAL_TESTS !== '1', timeout: 15000 };

test('bridge startup fails cleanly when its native binary is missing', options, () => {
  const result = spawnSync(process.execPath, [fileURLToPath(new URL('../src/bridge.js', import.meta.url))], {
    env: { ...process.env, IPHONE_HOST: '127.0.0.1', AIRPLAY_BINARY: '/private/tmp/opendisplay-deliberately-missing-native-binary' },
    timeout: 5000, encoding: 'utf8',
  });
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /AIRPLAY:.*ENOENT/);
});

test('virtual phone: idle, fragmented handshake, repeated rotation, and clean reselection', options, async t => {
  const phone = await virtualPhone(t);
  await delay(150); assert.equal(phone.connections.length, 0);
  await phone.select(true);
  await phone.until(() => phone.log.includes('IPHONE-PLAYBACK confirmed'));
  for (let cycle = 0; cycle < 3; cycle++) {
    for (const [width, height] of [[2796, 1290], [1290, 2796]]) {
      // Clear the event log so each rotation must produce its own resize.
      phone.log = '';
      await phone.rotate(width, height);
      const videos = phone.videos;
      await phone.until(() => phone.videos > videos);
      await phone.until(() => phone.log.includes('FIXTURE-DISPLAY '));
      const event = JSON.parse(phone.log.split('\n').find(line => line.startsWith('FIXTURE-DISPLAY ')).slice('FIXTURE-DISPLAY '.length));
      assert.equal(event.displays[0].width, Math.floor(width / 4) * 4);
      assert.equal(event.displays[0].height, Math.floor(height / 4) * 4);
      assert.equal(phone.connections.length, 1, 'Rotation must retain the TCP connection');
      assert.equal(phone.connections[0].destroyed, false);
      assert.doesNotMatch(phone.log, /IPHONE-NOT-READY|FIXTURE-STREAM-STARTED/);
    }
  }
  const closed = new Promise(resolve => phone.connections[0].once('close', resolve));
  await phone.select(false); await closed;
  await delay(650); assert.equal(phone.connections.length, 1, 'Deselection cancels retries');
  phone.log = '';
  await phone.select(true);
  await phone.until(() => phone.connections.length === 2 && phone.log.includes('IPHONE-PLAYBACK confirmed'));
});

test('virtual phone: temporary playback pause resumes on the existing connection', options, async t => {
  const phone = await virtualPhone(t);
  await phone.select(true); await phone.until(() => phone.log.includes('IPHONE-PLAYBACK confirmed'));
  phone.reportPlayback = false;
  phone.send({ type: 'stats', fps: 0 });
  await delay(1800); // Longer than the configured initial playback deadline.
  assert.equal(phone.connections.length, 1); assert.equal(phone.connections[0].destroyed, false);
  assert.doesNotMatch(phone.log, /IPHONE-NOT-READY/);
  const videos = phone.videos; phone.reportPlayback = true;
  await phone.until(() => phone.videos > videos);
  await phone.until(() => phone.messages.some(m => m.type === 'pong'));
});

test('virtual phone: broken TCP connection reconnects and forwards a fresh keyframe', options, async t => {
  const phone = await virtualPhone(t);
  await phone.select(true); await phone.until(() => phone.log.includes('IPHONE-PLAYBACK confirmed'));
  const videos = phone.videos;
  phone.log = '';
  phone.connections[0].destroy();
  await phone.until(() => phone.connections.length === 2 && phone.messages.filter(m => m.type === 'welcome').length === 2);
  await phone.until(() => phone.videos > videos);
  await phone.until(() => phone.log.includes('IPHONE-PLAYBACK confirmed'));
  assert.equal(phone.connections[1].destroyed, false);
  assert.doesNotMatch(phone.log, /IPHONE-NOT-READY/);
});

test('virtual phone: explicit receiver sleep tears down the bridge instead of retrying', options, async t => {
  const phone = await virtualPhone(t);
  await phone.select(true); await phone.until(() => phone.log.includes('IPHONE-PLAYBACK confirmed'));
  const closed = new Promise(resolve => phone.connections[0].once('close', resolve));
  phone.send({ type: 'sleeping' });
  await Promise.all([phone.waitForExit(), closed]);
  assert.match(phone.log, /IPHONE-NOT-READY: iPhone receiver closed or locked/);
  await delay(650); assert.equal(phone.connections.length, 1);
});

for (const scenario of [
  { name: 'unsupported protocol', hello: { type: 'hello', pv: 4 }, error: /Unsupported receiver protocol/ },
  { name: 'malformed JSON', rawHello: frame(Buffer.from('{broken')), error: /IPHONE:/ },
  { name: 'zero length frame', rawHello: Buffer.alloc(4), error: /Invalid frame length/ },
  { name: 'oversized frame', rawHello: Buffer.from([0x7f, 0xff, 0xff, 0xff]), error: /Invalid frame length/ },
  { name: 'playback stats before hello', hello: { type: 'stats', fps: 30 }, error: /receiver did not answer/ },
]) test(`virtual phone rejects ${scenario.name} without approving AirPlay`, options, async t => {
  const phone = await virtualPhone(t, scenario);
  await phone.select(true); await phone.waitForExit();
  assert.match(phone.log, scenario.error);
  assert.match(phone.log, /IPHONE-NOT-READY/);
  assert.doesNotMatch(phone.log, /IPHONE-READY|AIRPLAY-PREFLIGHT approved|FIXTURE-STREAM-STARTED/);
  assert.equal(phone.videos, 0);
  assert.equal(phone.messages.filter(m => m.type === 'welcome').length, 0);
});

test('virtual phone: delayed hello succeeds before its deadline', options, async t => {
  const phone = await virtualPhone(t, { helloDelayMs: 700 });
  await phone.select(true); await phone.until(() => phone.log.includes('IPHONE-PLAYBACK confirmed'));
  assert.equal(phone.connections.length, 1);
  assert.doesNotMatch(phone.log, /IPHONE-NOT-READY/);
});

test('virtual phone: rotation burst converges to the final size without restarting', options, async t => {
  const phone = await virtualPhone(t);
  await phone.select(true); await phone.until(() => phone.log.includes('IPHONE-PLAYBACK confirmed'));
  phone.log = '';
  const burst = Array.from({ length: 31 }, (_, index) => ({ type: 'hello', pv: 3,
    pixelsWide: index % 2 ? 1290 : 2796, pixelsHigh: index % 2 ? 2796 : 1290 }));
  phone.send(...burst);
  await phone.until(() => phone.messages.filter(m => m.type === 'welcome').length === 32);
  await phone.until(() => phone.log.includes('AIRPLAY-ORIENTATION 2796x1288'));
  const videos = phone.videos; await phone.until(() => phone.videos > videos);
  assert.equal(phone.connections.length, 1);
  assert.equal((phone.log.match(/AIRPLAY-ORIENTATION/g) || []).length, 1, 'Burst produces only its final resize');
  assert.doesNotMatch(phone.log, /FIXTURE-STREAM-STARTED|IPHONE-NOT-READY/);
});

test('virtual phone: twelve selection/drop cycles do not leak retries into later sessions', options, async t => {
  const phone = await virtualPhone(t);
  await phone.select(true); await phone.until(() => phone.log.includes('IPHONE-PLAYBACK confirmed'));
  for (let cycle = 0; cycle < 12; cycle++) {
    const previous = phone.connections.length, videos = phone.videos;
    if (cycle % 3 === 0) phone.connections.at(-1).destroy();
    else {
      const closed = new Promise(resolve => phone.connections.at(-1).once('close', resolve));
      await phone.select(false); await closed;
      await phone.select(true);
    }
    await phone.until(() => phone.connections.length === previous + 1 && phone.videos > videos);
    assert.equal(phone.connections.at(-1).destroyed, false);
  }
  await delay(650);
  assert.equal(phone.connections.length, 13, 'No stale retry creates an extra socket');
  assert.doesNotMatch(phone.log, /IPHONE-NOT-READY/);
});

test('virtual phone: large packets recover from backpressure and a delayed reconnect backlog', options, async t => {
  const dir = await mkdtemp(path.join(tmpdir(), 'mirror-backpressure-'));
  const videoFile = path.join(dir, 'video');
  const video = Buffer.concat([Buffer.from([0,0,0,1,7,0x88,0,0,0,1,8,0x88,0,0,0,1,5]), Buffer.alloc(512 * 1024, 0xff)]);
  await writeFile(videoFile, video);
  const phone = await virtualPhone(t, { helloDelayMs: 600,
    env: { SESSION_VIDEO_FILE: videoFile, SESSION_VIDEO_INTERVAL_MS: '20', MIRROR_HELLO_TIMEOUT_MS: '2500' } });
  t.after(() => rm(dir, { recursive: true, force: true }));
  await phone.select(true); await phone.until(() => phone.log.includes('IPHONE-PLAYBACK confirmed'));
  const socket = phone.connections[0]; socket.pause();
  const videos = phone.videos;
  await delay(700); assert.equal(phone.videos, videos);
  socket.resume(); await phone.until(() => phone.videos > videos);
  assert.equal(phone.connections.length, 1); assert.equal(socket.destroyed, false);
  assert.match(phone.log, /FIXTURE-VIDEO-BACKPRESSURE/);
  const beforeReconnect = phone.videos;
  socket.destroy();
  await phone.until(() => phone.connections.length === 2 && phone.videos > beforeReconnect);
  assert.equal(phone.connections.at(-1).destroyed, false);
  assert.doesNotMatch(phone.log, /IPHONE-NOT-READY/);
});
