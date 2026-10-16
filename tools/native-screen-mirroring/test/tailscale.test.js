import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isTailscaleAddress, prepareTailscale } from '../src/tailscale.js';

test('recognizes only Tailscale address ranges and names', () => {
  for (const address of ['100.64.0.1', '100.127.255.255', 'phone.example.ts.net', 'fd7a:115c:a1e0::1']) assert.ok(isTailscaleAddress(address));
  for (const address of ['100.63.255.255', '100.128.0.1', '192.168.1.2', '100.100.999.1', 'example.com']) assert.equal(isTailscaleAddress(address), false);
});
function mock(state) {
  const actions = [];
  return { actions, deps: { exists: () => true, status: async () => ({ BackendState: state }),
    openApp: () => actions.push('open'), command: (_, command) => actions.push(command) } };
}
test('signed-in running Tailscale never triggers a login prompt', async () => {
  const m = mock('Running');
  assert.equal(await prepareTailscale('100.64.0.1', m.deps), 'ready');
  assert.deepEqual(m.actions, []);
});
test('signed-out Tailscale opens the app and triggers login', async () => {
  const m = mock('NeedsLogin');
  assert.equal(await prepareTailscale('100.64.0.1', m.deps), 'login');
  assert.deepEqual(m.actions, ['open', 'login']);
});
test('stopped configured Tailscale reconnects without forcing another login', async () => {
  const m = mock('Stopped');
  assert.equal(await prepareTailscale('100.64.0.1', m.deps), 'starting');
  assert.deepEqual(m.actions, ['open', 'up']);
});
test('missing Tailscale requests configuration; LAN connections do not require it', async () => {
  const deps = { exists: () => false, status: () => { throw new Error('Must not run'); } };
  assert.equal(await prepareTailscale('100.64.0.1', deps), 'missing');
  assert.equal(await prepareTailscale('192.168.1.2', deps), 'ready');
});
