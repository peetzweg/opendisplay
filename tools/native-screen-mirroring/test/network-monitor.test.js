import { test } from 'node:test';
import assert from 'node:assert/strict';
import { NetworkMonitor, networkSignature } from '../src/network-monitor.js';

test('network signature ignores enumeration order and loopback but detects changed addresses', () => {
  const a = { family: 'IPv4', address: '192.168.1.2', internal: false };
  const b = { family: 'IPv6', address: 'fe80::1', scopeid: 4, internal: false };
  assert.equal(networkSignature({ en0: [a, b] }), networkSignature({ en0: [b, a], lo0: [{ internal: true }] }));
  assert.notEqual(networkSignature({ en0: [a] }), networkSignature({ en0: [{ ...a, address: '192.168.2.2' }] }));
});

test('network changes settle, refresh once, and defer throughout an active session', () => {
  let time = 0, signature = 'home', active = false, refreshes = 0;
  const monitor = new NetworkMonitor({ read: () => signature, now: () => time,
    isActive: () => active, onRefresh: () => refreshes++ });
  const tick = ms => { time += ms; monitor.tick(); };
  tick(2000); assert.equal(refreshes, 0);
  signature = 'offline'; tick(2000);
  signature = 'work'; tick(2000); // Restart settling after another change.
  tick(2000); assert.equal(refreshes, 0);
  active = true; tick(2000); tick(2000); assert.equal(refreshes, 0);
  active = false; tick(2000); assert.equal(refreshes, 1);
  tick(2000); assert.equal(refreshes, 1);
  tick(60000); assert.equal(refreshes, 1); // Wake even when addresses are unchanged.
  tick(2000); tick(2000); assert.equal(refreshes, 2);
  monitor.start(); monitor.close();
});
