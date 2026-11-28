import { test } from 'node:test';
import assert from 'node:assert/strict';
import { liveTestResult, displayEvidence } from '../scripts/live-test-result.js';

test('live evidence never treats missing native connections, undecoded bytes, or untested rotation as success', () => {
  const complete = { sessions: 1, decoded: 20, unexpectedDisconnects: 0, validatedRotations: 2 };
  assert.equal(liveTestResult(complete).exitCode, 0);
  for (const change of [{ sessions: 0 }, { decoded: 0 }, { sessions: 2 }, { unexpectedDisconnects: 1 }, { validatedRotations: 1 }])
    assert.notEqual(liveTestResult({ ...complete, ...change }).exitCode, 0);
});

test('display evidence catches a brief Sidecar removal even if polling snapshots show it reappeared', () => {
  const ipad = { id: 181, vendor: 0x6161706c, product: 0x69506164 };
  const baseline = { active: [ipad], error: 0, begin: false, removed: false, display: 0 };
  assert.equal(displayEvidence([]).status, 'no_display_evidence');
  assert.equal(displayEvidence([{ ...baseline, active: [] }]).status, 'no_sidecar_baseline');
  assert.equal(displayEvidence([baseline, { ...baseline, error: 1 }]).status, 'display_query_failed');
  assert.equal(displayEvidence([baseline, baseline]).status, 'sidecar_remained_registered');
  assert.equal(displayEvidence([baseline, { ...baseline, begin: true, active: [] }, baseline]).status, 'sidecar_remained_registered');
  assert.equal(displayEvidence([baseline, { ...baseline, removed: true, display: 181 }, baseline]).status, 'sidecar_interrupted');
  assert.equal(displayEvidence([baseline, { ...baseline, active: [] }, baseline]).status, 'sidecar_interrupted');
});
