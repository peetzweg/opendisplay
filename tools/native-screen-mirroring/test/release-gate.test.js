import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { checkEvidence, requiredScenarios } from '../scripts/check-release.js';
const hash = value => createHash('sha256').update(value).digest('hex');
function fixture() {
  const artifactBytes = Buffer.from('isolated test artifact; not release evidence');
  const automatedLog = '# tests 3\n# pass 3\n# fail 0\n# skipped 0\n# cancelled 0\n';
  const candidate = { schemaVersion: 1, artifactSHA256: hash(artifactBytes), sourceCommit: 'a'.repeat(40), sourceClean: true };
  const evidence = { schemaVersion: 1, artifactSHA256: candidate.artifactSHA256, sourceCommit: candidate.sourceCommit,
    automated: { status: 'passed', runtime: 'extracted-installer', logSHA256: hash(automatedLog) },
    native: { status: 'passed', evidence: 'isolated test fixture' }, limitations: ['Not notarized'],
    physical: requiredScenarios.map(id => ({ id, status: 'passed', artifactSHA256: candidate.artifactSHA256,
      sourceCommit: candidate.sourceCommit, setup: 'fresh-installer', environment: 'Test fixture only',
      testedAt: '2026-10-19T00:00:00Z', evidence: 'Synthetic evidence for validator unit test; never publish' })) };
  return { candidate, evidence, options: { artifactBytes, automatedLog } };
}
test('complete matching evidence passes the release consistency check', () => {
  const f = fixture(); assert.equal(checkEvidence(f.candidate, f.evidence, f.options).status, 'ready');
});
test('changed artifacts, stale commits and dirty builds block publication', () => {
  for (const mutate of [f => { f.options.artifactBytes = Buffer.from('changed'); },
    f => { f.evidence.sourceCommit = 'b'.repeat(40); }, f => { f.candidate.sourceClean = false; },
    f => { f.evidence.physical[0].artifactSHA256 = 'b'.repeat(64); }]) {
    const f = fixture(); mutate(f); assert.throws(() => checkEvidence(f.candidate, f.evidence, f.options), /Release blocked/);
  }
});
test('every required physical case is mandatory, including VPN and return to LAN', () => {
  for (const id of requiredScenarios) {
    const f = fixture(); f.evidence.physical = f.evidence.physical.filter(row => row.id !== id);
    assert.throws(() => checkEvidence(f.candidate, f.evidence, f.options), new RegExp(id));
  }
  const f = fixture(); f.evidence.physical.find(row => row.id === 'fresh_restricted_wifi_tailscale').setup = 'manual-IP-override';
  assert.throws(() => checkEvidence(f.candidate, f.evidence, f.options), /fresh installer/);
});
test('pending, duplicate and undocumented physical rows cannot count as passes', () => {
  for (const mutate of [f => { f.evidence.physical[0].status = 'pending'; },
    f => { f.evidence.physical.push(f.evidence.physical[0]); }, f => { f.evidence.physical[0].evidence = ''; },
    f => { f.evidence.physical[0].testedAt = 'not a date'; }]) {
    const f = fixture(); mutate(f); assert.throws(() => checkEvidence(f.candidate, f.evidence, f.options), /Missing matching physical pass/);
  }
});
test('skipped, failed, cancelled, partial and modified test logs cannot pass', () => {
  for (const log of ['# tests 3\n# pass 2\n# fail 0\n# skipped 1\n# cancelled 0\n',
    '# tests 3\n# pass 2\n# fail 1\n# skipped 0\n# cancelled 0\n',
    '# tests 3\n# pass 2\n# fail 0\n# skipped 0\n# cancelled 1\n', '# tests 3\n']) {
    const f = fixture(); f.options.automatedLog = log; f.evidence.automated.logSHA256 = hash(log);
    assert.throws(() => checkEvidence(f.candidate, f.evidence, f.options), /TAP summary|zero failures/);
  }
  const f = fixture(); f.options.automatedLog += 'changed';
  assert.throws(() => checkEvidence(f.candidate, f.evidence, f.options), /matching automated/);
});
