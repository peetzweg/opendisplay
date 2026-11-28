import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const before = '    path_challenge_count = ossl_quic_channel_get_path_challenge_count(ch);\n    path_response_count = ossl_quic_channel_get_path_response_count(ch);';
const after = '    if (!TEST_true(SSL_handle_events(ssl)))\n        goto err;\n\n' + before + '\n\n    /* Write completion is not packet receipt. Keep the harness deadline. */\n    if (path_challenge_count == 0 || path_response_count == 0)\n        F_SPIN_AGAIN();';

// OpenSSL 3.6.3's build-time QUIC test can inspect counters before the
// server processes the injected frames. Preserve every assertion and wait
// for packet processing. No library or production source is changed.
export function synchronizeFloodTest(source) {
  if (source.includes(after) || source.split(before).length !== 2) throw new Error('Unexpected OpenSSL test source; review the synchronization patch');
  return source.replace(before, after);
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length !== 3) throw new Error('Usage: node scripts/sync-openssl-test.js <OpenSSL source directory>');
    const file = path.join(process.argv[2], 'test/radix/quic_tests.c');
    writeFileSync(file, synchronizeFloodTest(readFileSync(file, 'utf8')));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
