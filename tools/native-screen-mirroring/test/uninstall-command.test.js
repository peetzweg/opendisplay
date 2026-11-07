import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
test('documented one-line uninstall succeeds and repeating it reports already uninstalled', () => {
  const home = mkdtempSync(path.join(tmpdir(), 'mirror-uninstall-'));
  try {
    const runtime = path.join(home, 'Library/Application Support/iphone-native-mirror/runtime');
    mkdirSync(runtime, { recursive: true });
    // Disposable bundled-runtime stand-in: remove itself after successful removal.
    const node = path.join(runtime, 'node');
    writeFileSync(node, '#!/bin/sh\nrm -rf "' + runtime + '"\nprintf "Uninstall successful\\n"\n'); chmodSync(node, 0o755);
    const readme = readFileSync(new URL('../README.md', import.meta.url), 'utf8');
    let command = readme.match(/```sh\n(if \[ -x[^\n]+)\n```/)[1];
    for (const expected of ['Uninstall successful', 'Already uninstalled']) {
      const result = spawnSync('/bin/zsh', ['-c', command.replaceAll('$HOME', home)], { encoding: 'utf8' });
      assert.equal(result.status, 0, result.stderr); assert.equal(result.stderr, ''); assert.match(result.stdout, new RegExp(expected));
    }
  } finally { rmSync(home, { recursive: true, force: true }); }
});
