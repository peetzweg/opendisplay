import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ReadinessGuard } from '../src/readiness.js';

function fixture() {
  const pending = new Map(); let next = 0, failures = 0;
  const guard = new ReadinessGuard(() => failures++, {
    schedule: callback => { pending.set(++next, callback); return next; },
    cancel: id => pending.delete(id),
  });
  return { guard, pending, fail: () => { for (const callback of [...pending.values()]) callback(); }, failures: () => failures };
}
test('hello and keepalives do not count as playback; background receiver times out', () => {
  const f = fixture(); f.guard.start();
  for (const message of [{ type: 'hello' }, { type: 'ping' }, { type: 'stats', fps: 0 }])
    assert.equal(f.guard.observe(message), false);
  f.fail(); assert.equal(f.failures(), 1);
});
test('positive receiver fps cancels the startup error, including a static one-fps desktop', () => {
  const f = fixture(); f.guard.start();
  assert.equal(f.guard.observe({ type: 'stats', fps: 1 }), true);
  assert.equal(f.pending.size, 0); f.fail(); assert.equal(f.failures(), 0);
});
test('disconnect cancels the watchdog and a new connection gets a fresh deadline', () => {
  const f = fixture(); f.guard.start(); f.guard.stop();
  f.fail(); assert.equal(f.failures(), 0);
  f.guard.start(); assert.equal(f.pending.size, 1);
  f.fail(); assert.equal(f.failures(), 1);
});
