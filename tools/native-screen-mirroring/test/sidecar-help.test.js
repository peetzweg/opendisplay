import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { SidecarHelp, isSidecarBusy, sidecarPredicate } from '../src/sidecar-help.js';

const busy = { processImagePath: '/System/Library/CoreServices/SidecarDisplayAgent', eventMessage: 'Connection failed: SidecarErrorDisplayAirPlayBusy (-453)' };

test('Sidecar guidance matches only the named AirPlay busy rejection from Sidecar or Control Center', () => {
  assert.equal(isSidecarBusy(busy), true);
  assert.equal(isSidecarBusy({ ...busy, processImagePath: '/System/Library/CoreServices/ControlCenter', eventMessage: 'Sidecar is not available while AirPlay Screen is active.' }), true);
  for (const event of [null, 1, 'noise', {}, { processImagePath: 42 }, { ...busy, eventMessage: 'Other error -453' }, { ...busy, eventMessage: 'Connected' }, { ...busy, processImagePath: '/tmp/other-app' }])
    assert.equal(isSidecarBusy(event), false);
});

test('real child log stream shows one hint per burst and leaves the connection owner untouched', { timeout: 10000 }, async () => {
  let child, launches = 0, shown = 0, now = 0;
  const help = new SidecarHelp({ show: () => { shown++; }, now: () => now,
    run: (binary, args, options) => {
      launches++;
      assert.equal(binary, '/usr/bin/log');
      assert.deepEqual(args, ['stream', '--style', 'ndjson', '--level', 'info', '--predicate', sidecarPredicate]);
      assert.deepEqual(options.stdio, ['ignore', 'pipe', 'ignore']);
      child = spawn(process.execPath, ['-e', 'process.stdin.pipe(process.stdout)'], { stdio: ['pipe', 'pipe', 'ignore'] });
      return child;
    } });
  const send = event => child.stdin.write(JSON.stringify(event) + '\n');
  async function until(count) {
    const deadline = Date.now() + 3000;
    while (shown !== count) { assert.ok(Date.now() < deadline); await delay(10); }
  }
  try {
    help.setActive(false); assert.equal(launches, 0);
    help.setActive(true); help.setActive(true); assert.equal(launches, 1);
    child.stdin.write('Filtering the log data\n{broken\nnull\n42\n{"processImagePath":123}\n');
    send({ ...busy, processImagePath: '/tmp/unrelated' });
    send(busy); await until(1);
    send(busy); await delay(50); assert.equal(shown, 1);
    assert.equal(child.exitCode, null, 'Showing help must not stop the observer or own the phone session');
    now = 30000; send(busy); await until(2);
    const exited = once(child, 'exit'); help.setActive(false); await exited;
    assert.equal(help.child, undefined);
    assert.equal(shown, 2);
    help.setActive(true); assert.equal(launches, 2);
    send(busy); await delay(50); assert.equal(shown, 2, 'Cooldown survives reconnect');
    const finalExit = once(child, 'exit'); help.close(); await finalExit;
  } finally { help.close(); }
});

test('unavailable log access and launch failures are nonfatal and do not display guidance', { timeout: 5000 }, async () => {
  let errors = [], shown = 0;
  const help = new SidecarHelp({ show: () => shown++, onError: error => errors.push(error),
    run: () => spawn('/nonexistent-sidecar-log-command', [], { stdio: ['ignore', 'pipe', 'ignore'] }) });
  help.setActive(true);
  await delay(100);
  assert.equal(errors.length, 1); assert.equal(shown, 0);
  help.close();
  const denied = new SidecarHelp({ show: () => shown++, run: () => spawn(process.execPath, ['-e', 'process.exit(77)'], { stdio: ['ignore', 'pipe', 'ignore'] }) });
  denied.setActive(true); await once(denied.child, 'exit');
  assert.equal(denied.child, undefined); assert.equal(shown, 0);
  denied.close();
});
