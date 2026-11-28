import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { validateRun, candidateName, approve } from '../scripts/ci-artifact.js';
import { checkRelease, requiredScenarios } from '../scripts/check-release.js';
const repository = 'therealjosemaria/opendisplay';
const commit = 'a'.repeat(40);
const run = () => ({ repository: { full_name: repository }, head_repository: { full_name: repository },
  path: '.github/workflows/native-screen-mirroring.yml', head_branch: 'main', event: 'push', conclusion: 'success', head_sha: commit });
test('only successful matching main-branch candidate runs are trusted', () => {
  validateRun(run(), repository, commit);
  for (const mutate of [r => { r.repository.full_name = 'attacker/fork'; }, r => { r.head_repository.full_name = 'attacker/fork'; },
    r => { r.path = '.github/workflows/other.yml'; }, r => { r.head_branch = 'feature'; }, r => { r.event = 'pull_request'; },
    r => { r.conclusion = 'failure'; }, r => { r.head_sha = 'b'.repeat(40); }]) {
    const r = run(); mutate(r); assert.throws(() => validateRun(r, repository, commit), /Untrusted/);
  }
});
test('release names cannot contain paths, shell expressions or dirty source', () => {
  const valid = { version: '0.0.18', architecture: 'arm64', sourceCommit: commit, sourceClean: true, artifact: 'iPhone-Native-Mirror-0.0.18-arm64.zip' };
  assert.equal(candidateName(valid), `native-mirror-v0.0.18-arm64-${commit.slice(0, 12)}`);
  for (const change of [{ artifact: '../outside.zip' }, { version: '$(malicious)' }, { architecture: 'other' }, { sourceClean: false }])
    assert.throws(() => candidateName({ ...valid, ...change }), /Invalid candidate/);
});
test('publication gate regenerates automated evidence and blocks absent physical evidence', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'mirror-ci-gate-'));
  const write = (name, content) => writeFileSync(path.join(dir, name), typeof content === 'string' ? content : JSON.stringify(content));
  try {
    const bytes = 'synthetic ZIP; never publish';
    const candidate = { schemaVersion: 1, version: '0.0.18', architecture: 'arm64', sourceCommit: commit, sourceClean: true,
      artifact: 'iPhone-Native-Mirror-0.0.18-arm64.zip', artifactSHA256: createHash('sha256').update(bytes).digest('hex') };
    write('candidate.json', candidate); write(candidate.artifact, bytes); write('run.json', run());
    write('native-tests.log', '100% tests passed, 0 tests failed out of 2\n');
    write('tests.tap', '# tests 3\n# pass 3\n# fail 0\n# skipped 0\n# cancelled 0\n');
    const evidence = { schemaVersion: 1, sourceCommit: commit, artifactSHA256: candidate.artifactSHA256,
      limitations: ['Synthetic unit test only'], physical: [] };
    write('physical.json', evidence);
    assert.throws(() => approve(dir, path.join(dir, 'physical.json'), path.join(dir, 'run.json'), repository), /Missing matching physical pass/);
    evidence.physical = requiredScenarios.map(id => ({ id, status: 'passed', sourceCommit: commit, artifactSHA256: candidate.artifactSHA256,
      setup: 'fresh-installer', testedAt: '2026-10-19T00:00:00Z', environment: 'Synthetic test', evidence: 'Unit fixture only' }));
    write('physical.json', evidence);
    assert.equal(approve(dir, path.join(dir, 'physical.json'), path.join(dir, 'run.json'), repository).tag, candidateName(candidate));
    assert.equal(JSON.parse(readFileSync(path.join(dir, 'evidence.json'))).automated.runtime, 'extracted-installer');
    write('tests.tap', '# tests 3\n# pass 2\n# fail 0\n# skipped 1\n# cancelled 0\n');
    assert.throws(() => approve(dir, path.join(dir, 'physical.json'), path.join(dir, 'run.json'), repository), /zero failures/);
    write('native-tests.log', 'No tests were found');
    assert.throws(() => approve(dir, path.join(dir, 'physical.json'), path.join(dir, 'run.json'), repository), /CTest/);
    write('candidate.json', { ...candidate, artifact: '../outside.zip' });
    assert.throws(() => checkRelease(path.join(dir, 'candidate.json'), path.join(dir, 'evidence.json')), /plain filenames/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
