import { test } from 'node:test';
import assert from 'node:assert/strict';
import { discover, serviceNames, resolvedService, snapshot } from '../scripts/discover.js';
import { review } from '../scripts/review.js';

const browse = name => `12:00:00.000 Add 2 14 local. _opensidecar._tcp. ${name}\n`;
test('Bonjour parsing preserves names, ignores removal and rejects incompatible receivers', () => {
  assert.deepEqual(serviceNames(browse('My iPhone') + browse('My iPhone') + browse('Other').replace('Add', 'Rmv')), ['My iPhone']);
  assert.deepEqual(resolvedService('My iPhone', 'My iPhone can be reached at phone.local.:9000 (interface 14)\n pv=3 id=abc'),
    { name: 'My iPhone', host: 'phone.local', id: 'abc' });
  for (const record of ['phone.local.:9001', 'phone.local.:9000 pv=4', 'evil;command:9000'])
    assert.equal(resolvedService('Phone', `can be reached at ${record} \n`), null);
});

test('discovery excludes Mac-local services and deduplicates the phone install identity', () => {
  const run = (binary, args) => {
    assert.equal(binary, '/usr/bin/dns-sd');
    let stdout;
    if (args[0] === '-B') stdout = browse('Mac alias') + browse('Phone') + browse('Phone again');
    else if (args[0] === '-L') stdout = `can be reached at ${args[1] === 'Mac alias' ? 'mac' : 'phone'}.local.:9000 (interface 14)\n pv=3 id=same`;
    else stdout = args[2] === 'mac.local' ? '192.168.1.10' : '192.168.1.20';
    return { stdout, error: { code: 'ETIMEDOUT' } };
  };
  assert.deepEqual(discover({ run, interfaces: { en0: [{ address: '192.168.1.10' }] } }),
    [{ name: 'Phone', host: 'phone.local', id: 'same' }]);
  assert.throws(() => snapshot([], () => ({ error: { code: 'ENOENT' } })), error => error.code === 'ENOENT');
});

test('installer detects a single phone without an address prompt and permits explicit Tailscale override', () => {
  for (const explicit of [undefined, '100.64.1.2']) {
    let installed, scans = 0;
    review({ mode: 'install', platform: 'darwin', env: explicit ? { IPHONE_HOST: explicit } : {},
      run: (binary, args) => {
        assert.notEqual(binary, '/usr/bin/osascript', 'Single phone needs no address dialog');
        if (args[0] === 'scripts/discover.js') { scans++; return { status: 0, stdout: JSON.stringify([{ name: 'Phone', host: 'phone.local' }]) }; }
        return { status: 0 };
      }, install: options => { installed = options; } });
    assert.equal(installed.host, explicit || 'phone.local');
    assert.equal(scans, explicit ? 0 : 1);
  }
});

test('multiple phones require a named selection and never silently select the first', () => {
  let installed;
  review({ mode: 'install', platform: 'darwin', env: {},
    run: (binary, args) => {
      if (args[0] === 'scripts/discover.js') return { status: 0, stdout: JSON.stringify([{ name: 'Alice', host: 'alice.local' }, { name: 'Bob', host: 'bob.local' }]) };
      if (binary === '/usr/bin/osascript') { assert.match(args[1], /choose from list/); return { status: 0, stdout: '2. Bob\n' }; }
      return { status: 0 };
    }, install: options => { installed = options; } });
  assert.equal(installed.host, 'bob.local');
});
