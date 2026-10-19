import { test } from 'node:test';
import assert from 'node:assert/strict';
import { synchronizeFloodTest } from '../scripts/sync-openssl-test.js';
const sequence = '    path_challenge_count = ossl_quic_channel_get_path_challenge_count(ch);\n    path_response_count = ossl_quic_channel_get_path_response_count(ch);';
test('OpenSSL test synchronization waits for counters without changing assertions', () => {
  const assertions = '\n    if (TEST_uint64_t_ne(path_challenge_count, 16))\n        goto err;\n    if (TEST_uint64_t_ne(path_response_count, 1))\n        goto err;';
  const source = sequence + assertions;
  const changed = synchronizeFloodTest(source);
  assert.ok(changed.endsWith(assertions));
  assert.match(changed, /SSL_handle_events\(ssl\)/);
  assert.match(changed, /if \(path_challenge_count == 0 \|\| path_response_count == 0\)\n        F_SPIN_AGAIN\(\);/);
});
test('changed, duplicate or already-patched upstream tests fail closed', () => {
  for (const source of ['', sequence.replace('path_challenge_count =', 'other ='), sequence + sequence, synchronizeFloodTest(sequence)])
    assert.throws(() => synchronizeFloodTest(source), /Unexpected OpenSSL test source/);
});
