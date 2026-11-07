import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { verifyArtifact } from '../scripts/ci-artifact.js';

for (const status of [0, 1]) test(`packaged test exit ${status} retains TAP and stderr before returning or failing`, () => {
  const directory = mkdtempSync(path.join(tmpdir(), 'mirror-artifact-log-'));
  try {
    const artifact = 'iPhone-Native-Mirror-0.0.18-arm64.zip';
    const bytes = Buffer.from('synthetic archive fixture');
    writeFileSync(path.join(directory, artifact), bytes);
    writeFileSync(path.join(directory, 'candidate.json'), JSON.stringify({ schemaVersion: 1, artifact,
      version: '0.0.18', architecture: 'arm64', sourceCommit: 'a'.repeat(40), sourceClean: true,
      artifactSHA256: createHash('sha256').update(bytes).digest('hex') }));
    const stdout = status ? 'not ok 1 - controlled decoder failure\n# fail 1\n' : 'ok 1 - controlled pass\n# fail 0\n';
    const stderr = 'controlled diagnostic';
    const spawn = (binary, args, options) => {
      if (binary === '/usr/bin/ditto') {
        const tests = path.join(args[3], 'Install iPhone Native Mirror.app/Contents/Resources/runtime/test');
        mkdirSync(tests, { recursive: true }); writeFileSync(path.join(tests, 'fixture.test.js'), '');
      }
      if (binary.endsWith('/runtime/node')) {
        assert.ok(args.includes('--test-reporter=tap'));
        for (const flag of ['RUN_NATIVE_TESTS', 'RUN_VIRTUAL_TESTS', 'RUN_VIDEO_TESTS', 'RUN_SOAK_TESTS'])
          assert.equal(options.env[flag], '1');
        return { status, stdout, stderr };
      }
      return { status: 0, stdout: '', stderr: '' };
    };
    if (status) assert.throws(() => verifyArtifact(directory, { spawn }), /controlled decoder failure/);
    else assert.equal(verifyArtifact(directory, { spawn }).sourceClean, true);
    assert.equal(readFileSync(path.join(directory, 'tests.tap'), 'utf8'), stdout);
    assert.equal(readFileSync(path.join(directory, 'tests.stderr.log'), 'utf8'), stderr);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
