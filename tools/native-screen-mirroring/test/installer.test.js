import { test } from 'node:test';
import assert from 'node:assert/strict';
import { installationIdentity, launchAgent } from '../src/installer.js';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

test('discovery identities are unique per installation and retained across upgrades', () => {
  const first = installationIdentity();
  const second = installationIdentity();
  assert.notEqual(first.deviceId, second.deviceId);
  assert.notEqual(first.hostLabel, second.hostLabel);
  assert.deepEqual(installationIdentity(first), first);
  assert.match(first.deviceId, /^02(?::[0-9a-f]{2}){5}$/);
  assert.throws(() => installationIdentity({ deviceId: 'invalid' }), /Invalid saved/);
  assert.throws(() => installationIdentity({ ...first, hostLabel: 'bad.label' }), /Invalid saved/);
  const xml = launchAgent({ node: '/node', script: '/bridge.js', host: '192.168.1.2', log: '/tmp/mirror.log', ...first });
  assert.ok(xml.includes(`<string>${first.deviceId}</string>`));
  assert.ok(xml.includes(`<string>${first.hostLabel}</string>`));
});

test('login service plist preserves paths containing XML metacharacters', () => {
  const xml = launchAgent({ node: '/node & tools/node', script: '/project <one>/bridge.js', host: '100.1.2.3', log: '/tmp/mirror.log' });
  assert.match(xml, /node &amp; tools/);
  assert.match(xml, /project &lt;one&gt;/);
  assert.match(xml, /<key>RunAtLoad<\/key><true\/>/);
  assert.match(xml, /<key>MIRROR_LOCAL_ONLY<\/key><string>1<\/string>/);
  assert.match(xml, /<key>MIRROR_NAME<\/key><string>iPhone<\/string>/);
  if (process.platform === 'darwin') {
    const dir = mkdtempSync(path.join(tmpdir(), 'mirror-test-'));
    try {
      const file = path.join(dir, 'agent.plist'); writeFileSync(file, xml);
      const result = spawnSync('/usr/bin/plutil', ['-lint', file], { encoding: 'utf8' });
      assert.equal(result.status, 0, result.stdout + result.stderr);
    } finally { rmSync(dir, { recursive: true }); }
  }
});
