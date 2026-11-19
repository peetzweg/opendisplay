import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const requiredScenarios = [
  'fresh_home_lan', 'fresh_restricted_wifi_tailscale', 'return_home_tailscale_off',
  'home_lan_with_tailscale_on', 'vpn_unavailable_clear_failure', 'upgrade_preserves_settings',
  'repeated_connections', 'rotation_audio', 'background_resume', 'uninstall_twice',
];
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const validHash = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);

// This verifies the consistency/completeness of recorded evidence. Physical
// observations remain human attestations; this cannot certify they occurred.
export function checkEvidence(candidate, evidence, { artifactBytes, automatedLog } = {}) {
  const errors = [];
  if (candidate.schemaVersion !== 1 || evidence.schemaVersion !== 1) errors.push('Unsupported evidence schema');
  if (!validHash(candidate.artifactSHA256) || hash(artifactBytes || '') !== candidate.artifactSHA256)
    errors.push('Installer ZIP does not match the frozen checksum');
  if (!/^[a-f0-9]{40}$/.test(candidate.sourceCommit || '') || candidate.sourceClean !== true)
    errors.push('Candidate must be built from a clean, identified source commit');
  if (evidence.artifactSHA256 !== candidate.artifactSHA256 || evidence.sourceCommit !== candidate.sourceCommit)
    errors.push('Evidence belongs to a different installer or source commit');
  const automated = evidence.automated || {};
  if (automated.status !== 'passed' || automated.runtime !== 'extracted-installer' ||
      !validHash(automated.logSHA256) || hash(automatedLog || '') !== automated.logSHA256)
    errors.push('Missing matching automated results from the extracted installer');
  const totals = name => [...String(automatedLog || '').matchAll(new RegExp(`^# ${name} (\\d+)$`, 'gm'))].map(m => Number(m[1]));
  for (const name of ['tests', 'pass', 'fail', 'skipped', 'cancelled'])
    if (totals(name).length !== 1) errors.push(`Expected one complete TAP summary for ${name}`);
  if (!(totals('tests')[0] > 0) || totals('pass')[0] !== totals('tests')[0] ||
      totals('fail')[0] !== 0 || totals('skipped')[0] !== 0 || totals('cancelled')[0] !== 0)
    errors.push('Automated suite must pass with zero failures, skips or cancellations');
  if (evidence.native?.status !== 'passed' || !evidence.native?.evidence)
    errors.push('Native CTest results are required');
  for (const id of requiredScenarios) {
    const matches = (Array.isArray(evidence.physical) ? evidence.physical : []).filter(row => row.id === id);
    const row = matches[0];
    if (matches.length !== 1 || row.status !== 'passed' || row.artifactSHA256 !== candidate.artifactSHA256 ||
        row.sourceCommit !== candidate.sourceCommit || !row.environment?.trim() || !row.evidence?.trim() ||
        !Number.isFinite(Date.parse(row.testedAt))) errors.push(`Missing matching physical pass: ${id}`);
    if (id.startsWith('fresh_') && row?.setup !== 'fresh-installer')
      errors.push(`${id} must start from a fresh installer, without a developer-supplied IP or plist edit`);
  }
  if (!Array.isArray(evidence.limitations) || !evidence.limitations.length)
    errors.push('Document signing, platform and Sidecar limitations');
  if (errors.length) throw new Error(`Release blocked:\n- ${errors.join('\n- ')}`);
  return { status: 'ready', artifactSHA256: candidate.artifactSHA256, sourceCommit: candidate.sourceCommit };
}

export function checkRelease(candidatePath, evidencePath) {
  const candidate = JSON.parse(readFileSync(candidatePath, 'utf8'));
  const evidence = JSON.parse(readFileSync(evidencePath, 'utf8'));
  if (typeof candidate.artifact !== 'string' || !/^[a-zA-Z0-9_.-]+\.zip$/.test(candidate.artifact) ||
      typeof evidence.automated?.log !== 'string' || !/^[a-zA-Z0-9_-]+\.tap$/.test(evidence.automated.log))
    throw new Error('Release blocked: ZIP and TAP paths must be plain filenames');
  return checkEvidence(candidate, evidence, {
    artifactBytes: readFileSync(path.resolve(path.dirname(candidatePath), candidate.artifact)),
    automatedLog: readFileSync(path.resolve(path.dirname(evidencePath), evidence.automated.log), 'utf8'),
  });
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length !== 4) throw new Error('Usage: node scripts/check-release.js candidate.json evidence.json');
    console.log(JSON.stringify(checkRelease(process.argv[2], process.argv[3]), null, 2));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
