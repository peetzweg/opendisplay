import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, writeFileSync, readFileSync, copyFileSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { installPackage } from '../scripts/install-package.js';
import { review } from '../scripts/review.js';

test('one-command install packs locally, forwards the target, and installs the archive offline', () => {
  const calls = [];
  installPackage({ host: '192.168.1.2', root: '/review source', env: { PATH: '/usr/bin' },
    run: (binary, args, options) => {
      calls.push({ binary, args, options });
      return { status: 0, stdout: '[{"filename":"iphone-native-mirror-0.0.13.tgz"}]' };
    } });
  assert.equal(calls.length, 2);
  assert.equal(calls[0].args[0], 'pack');
  assert.ok(calls[0].args.includes('--ignore-scripts'));
  assert.equal(calls[1].args[0], 'install');
  for (const flag of ['--global', '--foreground-scripts', '--offline', '--no-audit', '--no-fund'])
    assert.ok(calls[1].args.includes(flag));
  assert.equal(calls[1].options.env.IPHONE_HOST, '192.168.1.2');
  assert.equal(calls[1].options.cwd, '/review source');
  assert.ok(calls[1].args[2].endsWith('/iphone-native-mirror-0.0.13.tgz'));
  assert.ok(!existsSync(path.dirname(calls[1].args[2])), 'Temporary package and cache are removed');
});

test('failed or malformed packaging never starts global installation', () => {
  for (const result of [{ status: 1 }, { status: 0, stdout: 'not json' },
    { status: 0, stdout: '[{"filename":"../escape.tgz"}]' }]) {
    const calls = [];
    assert.throws(() => installPackage({ host: 'phone.local', root: '/source',
      run: (binary, args) => { calls.push(args); return result; } }));
    assert.equal(calls.length, 1);
    const temporary = calls[0][calls[0].indexOf('--pack-destination') + 1];
    assert.ok(!existsSync(temporary));
  }
});

test('failed global installation is reported and temporary source archives are cleaned up', () => {
  let temporary;
  assert.throws(() => installPackage({ host: 'phone.local', root: '/source', run: (binary, args) => {
    if (args[0] === 'pack') {
      temporary = args[args.indexOf('--pack-destination') + 1];
      return { status: 0, stdout: '[{"filename":"package.tgz"}]' };
    }
    return { status: 1 };
  } }), /npm install failed/);
  assert.ok(!existsSync(temporary));
});

test('install mode validates the target before delegating and does not start a review receiver', () => {
  const calls = [], installs = [];
  review({ mode: 'install', platform: 'darwin', env: { IPHONE_HOST: '192.168.1.2' }, root: '/source',
    run: (binary, args) => { calls.push({ binary, args }); return { status: 0 }; },
    install: options => installs.push(options) });
  assert.equal(installs.length, 1);
  assert.equal(installs[0].host, '192.168.1.2');
  assert.ok(calls.every(call => !call.args.includes('src/bridge.js') && !call.args.includes('--build')));
  assert.throws(() => review({ mode: 'install', platform: 'darwin', env: { IPHONE_HOST: 'http://invalid' },
    run: () => ({ status: 0 }), install: () => assert.fail('Invalid target must not install') }), /IP address/);
});

test('bootstrap installs prerequisites before delegating, without running real Homebrew', { skip: process.platform !== 'darwin' }, () => {
  const root = mkdtempSync(path.join(tmpdir(), 'mirror-bootstrap-'));
  const log = path.join(root, 'brew.log'), ready = path.join(root, 'ready');
  try {
    copyFileSync(fileURLToPath(new URL('../Install.command', import.meta.url)), path.join(root, 'Install.command'));
    writeFileSync(path.join(root, 'Review.command'), '#!/bin/zsh\nif [[ "$1" == --install ]]; then print INSTALL_STARTED; else [[ -f "$INSTALL_TEST_READY" ]]; fi\n');
    writeFileSync(path.join(root, 'brew'), '#!/bin/sh\nprintf "%s\\n" "$@" > "$INSTALL_TEST_LOG"\ntouch "$INSTALL_TEST_READY"\n');
    chmodSync(path.join(root, 'brew'), 0o755);
    const result = spawnSync('/bin/zsh', [path.join(root, 'Install.command')], {
      env: { ...process.env, PATH: `${root}:/usr/bin:/bin`, INSTALL_TEST_LOG: log, INSTALL_TEST_READY: ready }, encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /INSTALL_STARTED/);
    assert.equal(readFileSync(log, 'utf8'), 'install\ncmake\npkgconf\nlibplist\nopenssl@3\nnode\n');
  } finally { rmSync(root, { recursive: true }); }
});

test('interactive install prompt names the install action and forwards the entered address', () => {
  let prompt, installed;
  review({ mode: 'install', platform: 'darwin', env: {}, run: (binary, args) => {
    if (binary === '/usr/bin/osascript') { prompt = args[1]; return { status: 0, stdout: '192.168.1.2\n' }; }
    return { status: 0 };
  }, install: options => { installed = options; } });
  assert.match(prompt, /with title "iPhone Native Mirror"/);
  assert.match(prompt, /default button "Install"/);
  assert.doesNotMatch(prompt, /Start Review/);
  assert.equal(installed.host, '192.168.1.2');
});
