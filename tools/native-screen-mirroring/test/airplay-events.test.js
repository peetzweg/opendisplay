import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { spawnSync } from 'node:child_process';
import { AirPlayEvents, panelSize, encodeEvent } from '../src/airplay-events.js';

test('event channel reports rejected replies, bounds input and accepts a replacement connection', {
  skip: process.env.RUN_NATIVE_TESTS !== '1', timeout: 10000,
}, async t => {
  const errors = [], peers = [];
  const events = new AirPlayEvents({ onError: error => errors.push(error) });
  const port = await events.start();
  t.after(() => { for (const peer of peers) peer.destroy(); events.close(); });
  async function until(predicate) {
    const deadline = Date.now() + 2000;
    while (!predicate()) {
      assert.ok(Date.now() < deadline, 'Event channel did not settle');
      await delay(10);
    }
  }
  async function connect() {
    const peer = net.createConnection({ host: '127.0.0.1', port });
    peers.push(peer); peer.on('error', () => {});
    await once(peer, 'connect');
    await until(() => events.socket?.remotePort === peer.localPort && !events.socket.destroyed);
    return peer;
  }
  const first = await connect();
  first.write('RTSP/1.0 500 Error\r\nContent-Length: 4\r\n\r\na');
  await delay(30);
  assert.deepEqual(errors, [], 'Wait for the entire response body');
  first.write('bcdRTSP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n');
  await until(() => errors.length === 1);
  assert.deepEqual(errors, ['Mac rejected the display update']);
  first.write('x'.repeat(16385));
  await until(() => first.destroyed);
  const second = await connect();
  second.write('RTSP/1.0 200 OK\r\nContent-Length: 1048577\r\n\r\n');
  await until(() => second.destroyed);
  const third = await connect();
  let bytes = Buffer.alloc(0);
  third.on('data', chunk => { bytes = Buffer.concat([bytes, chunk]); });
  events.setActive(true); events.requestKeyframe();
  await until(() => bytes.includes(Buffer.from('forceKeyFrame')));
  assert.equal(third.destroyed, false);
  assert.equal(errors.length, 1);
});

test('rotation dimensions prefer panel facts, align the raster and reject invalid updates', () => {
  assert.deepEqual(panelSize({ pixelsWide: 1290, pixelsHigh: 2796 }), { width: 1288, height: 2796 });
  assert.deepEqual(panelSize({ panel: { pixelsWide: 2796, pixelsHigh: 1290 } }), { width: 2796, height: 1288 });
  assert.deepEqual(panelSize({ pixelsWide: 640, pixelsHigh: 480, panel: { width: 1290, height: 2796 } }), { width: 1288, height: 2796 });
  for (const pixelsWide of [0, -1, 319, 8193, NaN, Infinity, '1290', 1290.5])
    assert.equal(panelSize({ pixelsWide, pixelsHigh: 2796 }), null);
  assert.equal(panelSize({}), null);
});

function decode(packet) {
  const end = packet.indexOf('\r\n\r\n');
  const converted = spawnSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '--', '-'], { input: packet.subarray(end + 4) });
  assert.equal(converted.status, 0, converted.stderr.toString());
  return JSON.parse(converted.stdout.toString());
}
test('AirPlay event is an RTSP command containing a binary plist and exact length', { skip: process.platform !== 'darwin' }, () => {
  const packet = encodeEvent({ type: 'forceKeyFrame' }, 7);
  const end = packet.indexOf('\r\n\r\n');
  const header = packet.subarray(0, end).toString();
  assert.match(header, /^POST \/command RTSP\/1.0\r\nCSeq: 7/);
  assert.equal(Number(header.match(/Content-Length: (\d+)/)[1]), packet.length - end - 4);
  assert.equal(packet.subarray(end + 4, end + 12).toString(), 'bplist00');
  assert.deepEqual(decode(packet), { type: 'forceKeyFrame' });
});

test('live rotation debounces, preserves the session, returns to portrait and cancels on disconnect', {
  skip: process.env.RUN_NATIVE_TESTS !== '1', timeout: 10000,
}, async () => {
  const changes = [], errors = [], packets = [], peers = [];
  const events = new AirPlayEvents({ debounceMs: 30, onChange: size => changes.push(size), onError: error => errors.push(error) });
  const port = await events.start();
  const portrait = { pixelsWide: 1290, pixelsHigh: 2796 };
  const landscape = { pixelsWide: 2796, pixelsHigh: 1290 };
  async function until(predicate) {
    const deadline = Date.now() + 2000;
    while (!predicate()) { assert.ok(Date.now() < deadline, 'Timed out waiting for rotation event'); await delay(10); }
  }
  async function connect() {
    const peer = net.createConnection({ host: '127.0.0.1', port }); peers.push(peer);
    let pending = Buffer.alloc(0);
    peer.on('data', bytes => {
      pending = Buffer.concat([pending, bytes]);
      while (pending.length) {
        const end = pending.indexOf('\r\n\r\n');
        if (end < 0) return;
        const header = pending.subarray(0, end).toString();
        const length = Number(header.match(/Content-Length: (\d+)/)[1]);
        if (pending.length < end + 4 + length) return;
        packets.push(pending.subarray(0, end + 4 + length));
        pending = pending.subarray(end + 4 + length);
        const sequence = header.match(/CSeq: (\d+)/)[1];
        peer.write('RTSP/1.0 200 OK\r\n');
        peer.write(`CSeq: ${sequence}\r\nContent-Length: 0\r\n\r\n`);
      }
    });
    peer.on('error', () => {});
    await once(peer, 'connect'); return peer;
  }
  try {
    events.observeHello(portrait); events.setActive(true);
    const peer = await connect();
    await delay(80); assert.equal(packets.length, 0, 'Initial portrait matches the advertisement');
    events.observeHello(landscape); events.observeHello(portrait); events.observeHello(landscape);
    await until(() => packets.length === 1);
    assert.equal(decode(packets[0]).displays[0].widthPixels, 2796);
    assert.equal(decode(packets[0]).displays[0].heightPixels, 1288);
    events.observeHello(landscape); await delay(80); assert.equal(packets.length, 1);
    events.observeHello(portrait); await until(() => packets.length === 2);
    assert.equal(decode(packets[1]).displays[0].widthPixels, 1288);
    assert.ok(!peer.destroyed, 'Rotation keeps the event connection open');
    events.requestKeyframe(); await until(() => packets.length === 3);
    assert.equal(decode(packets[2]).type, 'forceKeyFrame');
    const closed = once(peer, 'close');
    events.observeHello(landscape); events.setActive(false); await closed;
    await delay(80); assert.equal(packets.length, 3, 'Disconnect cancels queued rotation');
    events.observeHello(landscape); events.setActive(true); await connect();
    await until(() => packets.length === 4);
    assert.deepEqual(changes, [{ width: 2796, height: 1288 }, { width: 1288, height: 2796 }, { width: 2796, height: 1288 }]);
    assert.deepEqual(errors, []);
  } finally {
    for (const peer of peers) peer.destroy();
    events.close();
  }
});
