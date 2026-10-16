import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { chooseReceiver, installBundle, removeBundle, setupPaths } from '../scripts/bundle-setup.js';
import { assertSystemDependencies } from '../scripts/build-installer.js';

function fixture() {
  const dir = mkdtempSync(path.join(tmpdir(), 'mirror-bundle-'));
  const source = path.join(dir, 'payload'), home = path.join(dir, 'home');
  for (const name of ['node', 'build/airplay-bridge', 'build/iphone-display-error', 'src/bridge.js']) {
    const file = path.join(source, name); mkdirSync(path.dirname(file), { recursive: true }); writeFileSync(file, 'bundled payload');
  }
  return { dir, source, home, p: setupPaths(home), clean: () => rmSync(dir, { recursive: true, force: true }) };
}

test('self-contained payload rejects Homebrew, missing or relative dynamic dependencies', () => {
  assertSystemDependencies('bridge:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1)\n\t/System/Library/Frameworks/AppKit.framework/AppKit (version 1)');
  for (const dep of ['/opt/homebrew/lib/libcrypto.dylib', '/usr/local/lib/libplist.dylib', '@rpath/libcrypto.dylib'])
    assert.throws(() => assertSystemDependencies(`bridge:\n\t${dep} (version 1)`), /external library/);
  assert.throws(() => assertSystemDependencies('bridge:'), /inspect/);
});

test('bundled setup discovers one phone without external developer tools or address entry', () => {
  assert.equal(chooseReceiver({ env: {}, scan: () => [{ name: 'Phone', host: 'phone.local' }],
    run: () => { throw new Error('No prompt needed'); } }), 'phone.local');
  assert.throws(() => chooseReceiver({ env: {}, scan: () => [] }), /Open OpenDisplay/);
  assert.equal(chooseReceiver({ env: { IPHONE_HOST: '100.64.1.2' }, scan: () => { throw new Error('Explicit target'); } }), '100.64.1.2');
});

test('bundled setup registers only bundled paths and survives deletion of its source', () => {
  const f = fixture(), calls = [];
  try {
    installBundle({ ...f, host: 'phone.local', uid: 501, run: (binary, args) => { calls.push([binary, args]); return { status: 0 }; } });
    rmSync(f.source, { recursive: true });
    assert.ok(existsSync(path.join(f.p.runtime, 'node')));
    const xml = readFileSync(f.p.agent, 'utf8');
    assert.ok(xml.includes(path.join(f.p.runtime, 'node')));
    assert.ok(xml.includes(path.join(f.p.runtime, 'src/bridge.js')));
    assert.ok(!xml.includes(f.source));
    assert.equal(JSON.parse(readFileSync(f.p.config)).host, 'phone.local');
    assert.deepEqual(calls.map(c => c[0]), ['/bin/launchctl', '/bin/launchctl']);
  } finally { f.clean(); }
});

test('upgrade retains identity and replaces the bundled runtime', () => {
  const f = fixture(); const run = () => ({ status: 0 });
  try {
    installBundle({ ...f, host: 'first.local', run });
    const before = JSON.parse(readFileSync(f.p.config));
    writeFileSync(path.join(f.source, 'node'), 'updated runtime');
    installBundle({ ...f, host: 'second.local', run });
    const after = JSON.parse(readFileSync(f.p.config));
    assert.equal(after.deviceId, before.deviceId); assert.equal(after.hostLabel, before.hostLabel);
    assert.equal(after.host, 'second.local');
    assert.equal(readFileSync(path.join(f.p.runtime, 'node'), 'utf8'), 'updated runtime');
  } finally { f.clean(); }
});

test('failed service registration restores the working runtime, config and LaunchAgent', () => {
  const f = fixture();
  try {
    installBundle({ ...f, host: 'working.local', run: () => ({ status: 0 }) });
    const config = readFileSync(f.p.config, 'utf8'), agent = readFileSync(f.p.agent, 'utf8');
    writeFileSync(path.join(f.source, 'node'), 'broken update');
    let bootstraps = 0;
    assert.throws(() => installBundle({ ...f, host: 'new.local', run: (binary, args) => {
      if (args[0] === 'bootstrap' && ++bootstraps === 1) return { status: 1, stderr: 'simulated failure' };
      return { status: 0 };
    } }), /simulated failure/);
    assert.equal(bootstraps, 2, 'Previous service is registered again');
    assert.equal(readFileSync(f.p.config, 'utf8'), config);
    assert.equal(readFileSync(f.p.agent, 'utf8'), agent);
    assert.equal(readFileSync(path.join(f.p.runtime, 'node'), 'utf8'), 'bundled payload');
  } finally { f.clean(); }
});

test('remove deletes the bundled service and runtime but retains saved phone settings', () => {
  const f = fixture(); const run = () => ({ status: 0 });
  try {
    installBundle({ ...f, host: 'phone.local', run });
    removeBundle({ home: f.home, run });
    assert.ok(!existsSync(f.p.agent)); assert.ok(!existsSync(f.p.runtime)); assert.ok(existsSync(f.p.config));
    assert.throws(() => installBundle({ ...f, source: '/missing', host: 'phone.local', run }), /Incomplete installer/);
  } finally { f.clean(); }
});
