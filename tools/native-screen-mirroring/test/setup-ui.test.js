import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

test('native installer completes with Done and next steps, and keeps failures retryable', { skip: process.platform !== 'darwin' }, () => {
  const temporary = mkdtempSync(path.join(tmpdir(), 'mirror-setup-ui-'));
  try {
    const executable = path.join(temporary, 'test-setup');
    const source = fileURLToPath(new URL('../native/test-setup.m', import.meta.url));
    const compile = spawnSync('/usr/bin/xcrun', ['clang', '-Werror', '-fobjc-arc', '-framework', 'AppKit', source, '-o', executable], { encoding: 'utf8', timeout: 30000 });
    assert.equal(compile.status, 0, compile.stderr);
    const result = spawnSync(executable, [], { encoding: 'utf8', timeout: 10000 });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stderr, /Installer UI checks passed/);
  } finally { rmSync(temporary, { recursive: true, force: true }); }
});

test('native error dialog lays out existing errors and the iPad-first guidance', { skip: process.platform !== 'darwin' }, () => {
  const temporary = mkdtempSync(path.join(tmpdir(), 'mirror-help-ui-'));
  try {
    const executable = path.join(temporary, 'show-error');
    const source = fileURLToPath(new URL('../native/show-error.m', import.meta.url));
    const compile = spawnSync('/usr/bin/xcrun', ['clang', '-Werror', '-fobjc-arc', '-framework', 'AppKit', source, '-o', executable], { encoding: 'utf8', timeout: 30000 });
    assert.equal(compile.status, 0, compile.stderr);
    for (const kind of ['opendisplay', 'tailscale', 'sidecar']) {
      const result = spawnSync(executable, [kind, '--check'], { encoding: 'utf8', timeout: 10000 });
      assert.equal(result.status, 0, `${kind}: ${result.stderr}`);
    }
  } finally { rmSync(temporary, { recursive: true, force: true }); }
});
