import { test } from 'node:test';
import assert from 'node:assert/strict';
import { VideoGate } from '../src/video.js';
const nal = type => Buffer.from([0, 0, 0, 1, type, 0x88]);
test('discards interframes until IDR with parameter sets; restores them after reconnect', () => {
  const gate = new VideoGate();
  assert.equal(gate.accept(nal(1)), null);
  assert.equal(gate.accept(nal(5)), null);
  const first = Buffer.concat([nal(7), nal(8), nal(5)]);
  assert.deepEqual(gate.accept(first), first);
  assert.deepEqual(gate.accept(nal(1)), nal(1));
  gate.reset();
  assert.equal(gate.accept(nal(1)), null);
  assert.deepEqual(gate.accept(nal(5)), first);
});

test('normalizes mixed Annex-B prefixes to the stock iPhone format and restores parameter sets', () => {
  const sps = Buffer.from([0, 0, 0, 1, 0x67, 0x88]);
  const pps = Buffer.from([0, 0, 1, 0x68, 0x99]);
  const idr = Buffer.from([0, 0, 1, 0x65, 0xaa]);
  const inter = Buffer.from([0, 0, 1, 0x41, 0xbb]);
  const gate = new VideoGate();
  assert.equal(gate.accept(inter), null);
  const video = Buffer.concat([sps, pps, idr]);
  const expected = Buffer.concat([sps, Buffer.from([0]), pps, Buffer.from([0]), idr]);
  assert.deepEqual(gate.accept(video), expected);
  gate.reset();
  assert.equal(gate.accept(inter), null);
  assert.deepEqual(gate.accept(idr), expected);
  assert.deepEqual(gate.accept(inter), Buffer.concat([Buffer.from([0]), inter]));
});

test('startup replay retains a complete reference chain, bounds memory and waits for idle', async () => {
  const { StartupReplay } = await import('../src/video.js');
  let now = 0;
  const replay = new StartupReplay({ now: () => now, idleMs: 100, maxBytes: 40 });
  replay.observe(nal(1)); now = 101; assert.deepEqual(replay.take(), []);
  replay.observe(nal(5)); replay.observe(nal(1));
  assert.deepEqual(replay.take(), []);
  now += 101; assert.deepEqual(replay.take(), [nal(5), nal(1)]);
  assert.deepEqual(replay.take(), []);
  replay.observe(Buffer.alloc(50)); now += 101; assert.deepEqual(replay.take(), []);
  replay.observe(nal(1)); now += 101; assert.deepEqual(replay.take(), []);
  replay.observe(nal(5)); replay.clear(); now += 101; assert.deepEqual(replay.take(), []);
});
