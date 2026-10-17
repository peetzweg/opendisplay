import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

export function installPackage({ host, root, env = process.env, run = spawnSync }) {
  const temporary = mkdtempSync(path.join(tmpdir(), 'iphone-mirror-install-'));
  const npm = path.join(path.dirname(process.execPath), 'npm');
  const options = { cwd: root, env: { ...env, IPHONE_HOST: host,
    PATH: `${path.dirname(process.execPath)}${path.delimiter}${env.PATH || ''}` }, stdio: 'inherit' };
  function command(args, extra = {}) {
    const result = run(npm, [...args, '--cache', path.join(temporary, 'cache')], { ...options, ...extra });
    if (result.error || result.status !== 0) throw new Error(`npm ${args[0]} failed${result.error ? `: ${result.error.message}` : ` (exit ${result.status})`}.`);
    return result;
  }
  try {
    const packed = command(['pack', '--json', '--ignore-scripts', '--pack-destination', temporary],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] });
    const manifest = JSON.parse(packed.stdout);
    const filename = manifest[0]?.filename;
    if (manifest.length !== 1 || typeof filename !== 'string' || path.basename(filename) !== filename || !filename.endsWith('.tgz'))
      throw new Error('npm pack returned an invalid archive name.');
    command(['install', '--global', path.join(temporary, filename), '--foreground-scripts', '--offline', '--no-audit', '--no-fund']);
  } finally { rmSync(temporary, { recursive: true, force: true }); }
}
