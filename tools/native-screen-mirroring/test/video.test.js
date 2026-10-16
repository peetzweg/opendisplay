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
