import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Decoder, frame } from '../src/protocol.js';

test('reassembles fragmented headers and coalesced messages', () => {
  const received = [];
  const decoder = new Decoder(body => received.push(JSON.parse(body)));
  const messages = [{ type: 'hello', pv: 3 }, { type: 'ping', t: 42 }];
  const bytes = Buffer.concat(messages.map(frame));
  for (let i = 0; i < bytes.length; i += 3) decoder.push(bytes.subarray(i, i + 3));
  assert.deepEqual(received, messages);
});
test('preserves binary H264 including NUL bytes', () => {
  const bytes = Buffer.from([0, 0, 0, 1, 0x65, 0xff]);
  new Decoder(body => assert.deepEqual(body, bytes)).push(frame(bytes));
});
test('rejects empty and oversized frames before buffering payload', () => {
  for (const length of [0, 1024 * 1024]) {
    const header = Buffer.alloc(4); header.writeUInt32BE(length);
    assert.throws(() => new Decoder(() => {}).push(header), /Invalid frame/);
  }
});
