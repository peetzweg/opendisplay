import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, chmodSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { phoneAddress, review } from '../scripts/review.js';

test('double-click launcher preserves the selected Node and forwards options', { skip: process.platform !== 'darwin' }, () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'mirror-launcher-'));
  try {
    const binary = path.join(dir, 'node');
    writeFileSync(binary, '#!/bin/sh\nif [ "$1" = "-p" ]; then echo true; else printf "%s\\n" "$@"; fi\n'); chmodSync(binary, 0o755);
    const launcher = fileURLToPath(new URL('../Review.command', import.meta.url));
    const result = spawnSync('/bin/zsh', [launcher, '--check'], {
      env: { ...process.env, PATH: `${dir}:/usr/bin:/bin` }, encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'scripts/review.js\n--check\n');
  } finally { rmSync(dir, { recursive: true }); }
});

test('review accepts IP addresses and hostnames, rejecting URLs, ports and shell text', () => {
  for (const host of ['192.168.1.2', '100.64.1.2', 'fd7a:115c:a1e0::1', 'phone.local', 'phone'])
    assert.equal(phoneAddress(` ${host}\n`), host);
  for (const host of ['', 'https://phone.local', 'phone.local:9000', '-phone', 'x; touch /tmp/x', 'bad..local'])
    assert.throws(() => phoneAddress(host), /IP address or hostname/);
});

test('prerequisite checks never build, install a service, or start a receiver', () => {
  const calls = [];
  review({ mode: 'check', platform: 'darwin', run: (binary, args) => {
    calls.push([binary, args]); return { status: 0 };
  } });
  assert.deepEqual(calls.map(([binary]) => binary), ['cmake', 'pkg-config', 'pkg-config']);
  assert.throws(() => review({ platform: 'linux' }), /macOS/);
  assert.throws(() => review({ mode: 'invalid', platform: 'darwin' }), /--check/);
});

test('review stops when prerequisites are missing or the address prompt is cancelled', () => {
  const failed = [];
  assert.throws(() => review({ platform: 'darwin', run: (binary) => {
    failed.push(binary); return { status: 1 };
  } }), /brew install/);
  assert.deepEqual(failed, ['cmake']);
  const cancelled = [];
  assert.throws(() => review({ platform: 'darwin', env: {}, run: (binary) => {
    cancelled.push(binary); return { status: binary === '/usr/bin/osascript' ? 1 : 0 };
  } }), /osascript failed/);
  assert.deepEqual(cancelled, ['cmake', 'pkg-config', 'pkg-config', process.execPath, '/usr/bin/osascript']);
});

test('temporary review reuses its identity without registering a login service', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'mirror-review-'));
  const calls = [];
  const run = (binary, args, options) => { calls.push({ binary, args, options }); return { status: 0 }; };
  try {
    review({ platform: 'darwin', env: { IPHONE_HOST: '192.168.1.2' }, root, run });
    const first = readFileSync(path.join(root, 'build/review-identity.json'), 'utf8');
    review({ platform: 'darwin', env: { IPHONE_HOST: '192.168.1.2' }, root, run });
    assert.equal(readFileSync(path.join(root, 'build/review-identity.json'), 'utf8'), first);
    const sessions = calls.filter(call => call.args[0] === 'src/bridge.js');
    assert.equal(sessions.length, 2);
    assert.equal(sessions[0].options.env.MIRROR_NAME, 'OpenDisplay Review');
    assert.equal(sessions[0].options.env.MIRROR_LOCAL_ONLY, '1');
    assert.equal(sessions[0].options.env.MIRROR_DEVICE_ID, sessions[1].options.env.MIRROR_DEVICE_ID);
    assert.ok(calls.every(call => !/launchctl|npm/.test(call.binary)));
  } finally { rmSync(root, { recursive: true }); }
});

test('verification builds before running the full suite and never starts a phone session', () => {
  const calls = [];
  review({ mode: 'verify', platform: 'darwin', run: (binary, args, options) => {
    calls.push({ binary, args, options }); return { status: 0 };
  } });
  assert.equal(calls.at(-1).args[0], '--test');
  assert.ok(calls.at(-1).args.slice(1).every(name => name.startsWith('test/') && !name.includes('build/')));
  assert.ok(calls.at(-1).args.includes('test/bundle.test.js'));
  assert.equal(calls.at(-1).options.env.RUN_NATIVE_TESTS, '1');
  assert.equal(calls.at(-1).options.env.RUN_VIRTUAL_TESTS, '1');
  assert.equal(calls.at(-1).options.env.RUN_VIDEO_TESTS, '1');
  assert.equal(calls.at(-1).options.env.RUN_SOAK_TESTS, '1');
  assert.equal(calls[5].binary, 'ctest');
  assert.deepEqual(calls[5].args, ['--test-dir', 'build', '--output-on-failure']);
  assert.ok(calls.at(-1).args.includes('test/virtual.test.js'));
  assert.deepEqual(calls[3].args, ['-S', '.', '-B', 'build', '-DMIRROR_INTERNAL_MDNS=ON', '-DMIRROR_BUILD_TESTS=ON']);
  assert.deepEqual(calls[4].args, ['--build', 'build', '-j', '4']);
  assert.ok(calls.every(call => !call.args.includes('src/bridge.js')));
});
