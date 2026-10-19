import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, chmodSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { chooseReceiver, installBundle, removeBundle, setupPaths } from '../scripts/bundle-setup.js';
import { assertSystemDependencies, assertMacOSBaseline } from '../scripts/build-installer.js';

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

test('installer rejects newer static-library deployment targets instead of trusting its own binary label', () => {
  assertMacOSBaseline('cmd LC_BUILD_VERSION\n minos 14.0\n sdk 26.5');
  assertMacOSBaseline('cmd LC_VERSION_MIN_MACOSX\n cmdsize 16\n version 10.15\n sdk 13.3');
  assert.throws(() => assertMacOSBaseline('minos 14.0\nminos 26.0'), /requires macOS 26.0/);
  assert.throws(() => assertMacOSBaseline('minos 14.0.1'), /newer/);
  assert.throws(() => assertMacOSBaseline('no deployment metadata'), /Could not inspect/);
});

test('bundled setup discovers one phone without external developer tools or address entry', () => {
  assert.equal(chooseReceiver({ env: {}, scan: () => [{ name: 'Phone', host: 'phone.local' }],
    run: () => { throw new Error('No prompt needed'); } }), 'phone.local');
  assert.throws(() => chooseReceiver({ env: {}, scan: () => [] }), /Open OpenDisplay/);
  assert.equal(chooseReceiver({ env: { IPHONE_HOST: '100.64.1.2' }, scan: () => { throw new Error('Explicit target'); } }), '100.64.1.2');
});

test('bundled setup selects the named phone and rejects cancellation or an invalid selection', () => {
  const devices = [{ name: 'First phone', host: 'first.local' }, { name: 'Second "phone"', host: 'second.local' }];
  let prompt;
  const host = chooseReceiver({ env: {}, scan: () => devices, run: (binary, args) => {
    assert.equal(binary, '/usr/bin/osascript'); prompt = args[1];
    return { status: 0, stdout: '2. Second "phone"\n' };
  } });
  assert.equal(host, 'second.local');
  assert.ok(prompt.includes(JSON.stringify('2. Second "phone"')));
  assert.throws(() => chooseReceiver({ env: {}, scan: () => devices, run: () => ({ status: 1 }) }), /cancelled/);
  assert.throws(() => chooseReceiver({ env: {}, scan: () => devices, run: () => ({ status: 0, stdout: 'not a phone' }) }), /No phone selected/);
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
    assert.deepEqual(calls.map(c => c[0]), ['/bin/launchctl', '/bin/launchctl', '/bin/launchctl']);
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

test('refused service shutdown aborts an update before replacing the working runtime', () => {
  const f = fixture();
  try {
    installBundle({ ...f, host: 'working.local', run: () => ({ status: 0 }) });
    const before = readFileSync(f.p.config, 'utf8');
    writeFileSync(path.join(f.source, 'node'), 'new runtime');
    assert.throws(() => installBundle({ ...f, host: 'new.local', run: (binary, args) =>
      args[0] === 'bootout' ? { status: 1, stderr: 'Operation not permitted' } : { status: 0 } }), /Operation not permitted/);
    assert.equal(readFileSync(f.p.config, 'utf8'), before);
    assert.equal(readFileSync(path.join(f.p.runtime, 'node'), 'utf8'), 'bundled payload');
    assert.ok(!readdirSync(f.p.support).some(name => name.startsWith('runtime-staging-')));
  } finally { f.clean(); }
});

test('failed staging copy cleans partial files and preserves the existing installation', t => {
  if (process.getuid?.() === 0) return t.skip('Permission fault requires an unprivileged user');
  const f = fixture();
  try {
    installBundle({ ...f, host: 'working.local', run: () => ({ status: 0 }) });
    const before = readFileSync(f.p.config, 'utf8');
    const unreadable = path.join(f.source, 'unreadable'); writeFileSync(unreadable, 'copy failure fixture'); chmodSync(unreadable, 0);
    assert.throws(() => installBundle({ ...f, host: 'new.local', run: () => ({ status: 0 }) }), /EACCES|permission denied/i);
    assert.equal(readFileSync(f.p.config, 'utf8'), before);
    assert.equal(readFileSync(path.join(f.p.runtime, 'node'), 'utf8'), 'bundled payload');
    assert.ok(!readdirSync(f.p.support).some(name => name.startsWith('runtime-staging-')), 'Partial staging must not survive a failed copy');
  } finally { f.clean(); }
});

test('failed rollback restart is reported while previous files remain restored', () => {
  const f = fixture();
  try {
    installBundle({ ...f, host: 'working.local', run: () => ({ status: 0 }) });
    const before = readFileSync(f.p.config, 'utf8');
    writeFileSync(path.join(f.source, 'node'), 'new runtime');
    assert.throws(() => installBundle({ ...f, host: 'new.local', run: (binary, args) =>
      args[0] === 'bootstrap' ? { status: 1, stderr: 'registration denied' } : { status: 0 } }), /registration denied.*previous service could not restart/s);
    assert.equal(readFileSync(f.p.config, 'utf8'), before);
    assert.equal(readFileSync(path.join(f.p.runtime, 'node'), 'utf8'), 'bundled payload');
  } finally { f.clean(); }
});

test('fresh install handles an absent service and refuses an indeterminate service state', () => {
  for (const status of [113, 1]) {
    const f = fixture(), calls = [];
    const run = (binary, args) => { calls.push(args[0]); return { status: args[0] === 'print' ? status : 0, stderr: 'query denied' }; };
    try {
      if (status === 113) {
        installBundle({ ...f, host: 'phone.local', run });
        assert.deepEqual(calls, ['print', 'bootstrap']);
        assert.ok(existsSync(f.p.runtime));
      } else {
        assert.throws(() => installBundle({ ...f, host: 'phone.local', run }), /Could not inspect/);
        assert.deepEqual(calls, ['print']);
        assert.ok(!existsSync(f.p.runtime));
      }
    } finally { f.clean(); }
  }
});

 test('removal preserves the runtime when service shutdown fails', () => {
  const f = fixture();
  try {
    installBundle({ ...f, host: 'phone.local', run: () => ({ status: 0 }) });
    assert.throws(() => removeBundle({ home: f.home, run: (binary, args) => ({ status: args[0] === 'bootout' ? 1 : 0 }) }), /Removal cancelled/);
    assert.ok(existsSync(f.p.runtime)); assert.ok(existsSync(f.p.agent));
    removeBundle({ home: f.home, run: () => ({ status: 113 }) });
    assert.ok(!existsSync(f.p.runtime)); assert.ok(existsSync(f.p.config));
  } finally { f.clean(); }
});

test('optional Tailscale fallback survives runtime upgrades without replacing the LAN target', () => {
  const f = fixture();
  try {
    installBundle({ ...f, host: 'phone.local', run: () => ({ status: 0 }) });
    const saved = JSON.parse(readFileSync(f.p.config, 'utf8'));
    saved.fallbackHost = '100.106.150.88'; writeFileSync(f.p.config, JSON.stringify(saved));
    installBundle({ ...f, host: 'phone.local', run: () => ({ status: 0 }) });
    const after = JSON.parse(readFileSync(f.p.config, 'utf8'));
    assert.equal(after.host, 'phone.local'); assert.equal(after.deviceId, saved.deviceId);
    assert.equal(after.fallbackHost, saved.fallbackHost);
    const agent = readFileSync(f.p.agent, 'utf8');
    assert.match(agent, /IPHONE_HOST<\/key><string>phone.local/);
    assert.match(agent, /IPHONE_FALLBACK_HOST<\/key><string>100.106.150.88/);
  } finally { f.clean(); }
});
