import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';

const workflow = readFileSync(new URL('../../../.github/workflows/native-mirror-release.yml', import.meta.url), 'utf8');
const script = workflow.split('Publish the approved bytes without rebuilding or overwriting')[1]
  .split('script: |\n')[1].split('\n').map(line => line.replace(/^            /, '')).join('\n');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
async function exercise({ existing = false, modified = false, corruptUpload = false, invalid = false, uploadFails = false } = {}) {
  const events = [];
  const bytes = Buffer.from('synthetic installer fixture; never uploaded');
  const sha = createHash('sha256').update(bytes).digest('hex');
  const metadata = { artifact: invalid ? '../outside.zip' : 'iPhone-Native-Mirror-0.0.18-arm64.zip',
    tag: 'native-mirror-v0.0.18-arm64-aaaaaaaaaaaa', sourceCommit: 'a'.repeat(40) };
  const files = { 'approved/release.json': JSON.stringify(metadata), 'approved/candidate.json': JSON.stringify({
    version: '0.0.18', architecture: 'arm64', artifactSHA256: modified ? 'b'.repeat(64) : sha }),
    'approved/RELEASE.md': 'Unit test fixture' };
  const fakeFS = { readFileSync: name => files[name] || bytes };
  const github = { rest: {
    git: { getRef: async () => { events.push('tag'); if (existing) return {}; throw Object.assign(new Error('Not found'), { status: 404 }); } },
    repos: {
      createRelease: async input => { events.push('draft'); assert.equal(input.draft, true); return { data: { id: 42, html_url: 'https://example.invalid' } }; },
      uploadReleaseAsset: async input => { events.push('upload'); if (uploadFails) throw new Error('Upload failed'); return { data: { id: 43, name: input.name } }; },
      updateRelease: async input => { events.push('publish'); assert.equal(input.draft, false); },
    },
  }, request: async () => { events.push('download'); return { data: corruptUpload ? Buffer.from('corrupted') : bytes }; } };
  const require = createRequire(import.meta.url);
  try {
    await new AsyncFunction('require', 'github', 'context', 'core', script)(
      name => name === 'fs' ? fakeFS : require(name), github,
      { repo: { owner: 'unit', repo: 'fixture' } }, { summary: { addLink() { return this; }, async write() {} } });
    return { events };
  } catch (error) { return { events, error }; }
}
test('publisher exposes the release only after all uploads and remote checksum verification', async () => {
  const result = await exercise(); assert.equal(result.error, undefined);
  assert.deepEqual(result.events, ['tag', 'draft', ...Array(6).fill('upload'), 'download', 'publish']);
});
for (const [label, options] of Object.entries({
  'existing tag': { existing: true }, 'modified ZIP': { modified: true },
  'corrupted upload': { corruptUpload: true }, 'invalid metadata': { invalid: true }, 'upload failure': { uploadFails: true },
})) test(`publisher refuses ${label} without making a release visible`, async () => {
  const result = await exercise(options); assert.ok(result.error); assert.ok(!result.events.includes('publish'));
});
