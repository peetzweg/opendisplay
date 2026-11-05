import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';

const execute = promisify(execFile);
export function isTailscaleAddress(host) {
  const parts = host.split('.');
  return (parts.length === 4 && parts.every(p => /^\d+$/.test(p) && Number(p) <= 255)
    && Number(parts[0]) === 100 && Number(parts[1]) >= 64 && Number(parts[1]) <= 127)
    || /\.ts\.net$/i.test(host) || /^fd7a:115c:a1e0:/i.test(host);
}
function launchApp(app) {
  const child = spawn('/usr/bin/open', ['-g', app], { detached: true, stdio: 'ignore' });
  child.on('error', () => {}); child.unref();
}
function launchCommand(binary, command) {
  const child = spawn(binary, [command], {
    env: { ...process.env, TAILSCALE_BE_CLI: '1' }, stdio: ['ignore', 'pipe', 'pipe'],
  });
  // CLI login emits the official auth URL. Open it, but never log or save it.
  let output = '', opened = false;
  const receive = bytes => {
    output = (output + bytes.toString()).slice(-8192);
    const match = output.match(/https:\/\/login\.tailscale\.com\/a\/[A-Za-z0-9_-]+/);
    if (!opened && match) {
      opened = true;
      const browser = spawn('/usr/bin/open', [match[0]], { detached: true, stdio: 'ignore' });
      browser.on('error', () => {}); browser.unref();
    }
  };
  child.stdout.on('data', receive);
  child.stderr.on('data', receive);
  child.on('error', () => {});
  child.unref();
}

export async function prepareTailscale(host, {
  exists = existsSync, openApp = launchApp, command = launchCommand,
  status = async binary => JSON.parse((await execute(binary, ['status', '--json'], {
    env: { ...process.env, TAILSCALE_BE_CLI: '1' }, timeout: 3000, maxBuffer: 4 * 1024 * 1024,
  })).stdout),
} = {}) {
  if (!isTailscaleAddress(host)) return 'ready';
  const app = ['/Applications/Tailscale.app', `${homedir()}/Applications/Tailscale.app`]
    .find(candidate => exists(`${candidate}/Contents/MacOS/Tailscale`));
  if (!app) return 'missing';
  const binary = `${app}/Contents/MacOS/Tailscale`;
  let state;
  try { state = (await status(binary)).BackendState; }
  catch {
    openApp(app);
    try { state = (await status(binary)).BackendState; } catch { return 'unconfigured'; }
  }
  if (state === 'Running') return 'ready';
  openApp(app);
  if (state === 'NeedsLogin') { command(binary, 'login'); return 'login'; }
  if (state === 'Stopped') { command(binary, 'up'); return 'starting'; }
  if (state === 'Starting' || state === 'NoState') return 'starting';
  return 'unconfigured';
}
