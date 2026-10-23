import { cpSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { installationIdentity, launchAgent } from '../src/installer.js';
import { discover } from './discover.js';

const root = fileURLToPath(new URL('..', import.meta.url));
const label = 'local.iphone-native-mirror';
export function setupPaths(home) {
  const support = path.join(home, 'Library/Application Support/iphone-native-mirror');
  return { support, runtime: path.join(support, 'runtime'), config: path.join(support, 'config.json'),
    agent: path.join(home, 'Library/LaunchAgents', `${label}.plist`),
    log: path.join(home, 'Library/Logs/iphone-native-mirror.log') };
}

export function chooseReceiver({ run = spawnSync, scan = discover, env = process.env } = {}) {
  if (env.IPHONE_HOST) return env.IPHONE_HOST;
  const devices = scan();
  if (!devices.length) throw new Error('No phone found. Open OpenDisplay on your unlocked iPhone, allow Local Network access, connect both devices to the same Wi-Fi, then click Install again.');
  if (devices.length === 1) return devices[0].host;
  const labels = devices.map((d, i) => `${i + 1}. ${d.name}`);
  const selected = run('/usr/bin/osascript', ['-e',
    `set chosen to choose from list {${labels.map(s => JSON.stringify(s)).join(', ')}} with title "iPhone Native Mirror" with prompt "Choose your OpenDisplay phone:"\nif chosen is false then error number -128\nreturn item 1 of chosen`], { encoding: 'utf8' });
  if (selected.status !== 0) throw new Error('Installation cancelled.');
  const host = devices[labels.indexOf(selected.stdout.trim())]?.host;
  if (!host) throw new Error('No phone selected.');
  return host;
}

export function installBundle({ source = root, home = homedir(), uid = process.getuid(), host,
  run = spawnSync } = {}) {
  if (!host || !/^[a-z0-9.:%_-]+$/i.test(host)) throw new Error('Invalid phone address.');
  for (const file of ['node', 'build/airplay-bridge', 'build/iphone-display-error', 'src/bridge.js'])
    if (!existsSync(path.join(source, file))) throw new Error(`Incomplete installer: ${file} is missing.`);
  const p = setupPaths(home), domain = `gui/${uid}`;
  const saved = existsSync(p.config) ? JSON.parse(readFileSync(p.config, 'utf8')) : {};
  const identity = installationIdentity(saved);
  const previousConfig = existsSync(p.config) ? readFileSync(p.config) : undefined;
  const previousAgent = existsSync(p.agent) ? readFileSync(p.agent) : undefined;
  mkdirSync(p.support, { recursive: true, mode: 0o700 });
  const staging = path.join(p.support, `runtime-staging-${process.pid}`);
  const backup = path.join(p.support, `runtime-backup-${process.pid}`);
  if (existsSync(staging) || existsSync(backup)) throw new Error('An unfinished installation exists. Close the installer and retry.');
  let wasRegistered = false;
  try {
    cpSync(source, staging, { recursive: true });
    mkdirSync(path.dirname(p.agent), { recursive: true });
    mkdirSync(path.dirname(p.log), { recursive: true });
    const state = run('/bin/launchctl', ['print', `${domain}/${label}`], { encoding: 'utf8' });
    if (state.error) throw state.error;
    // launchctl returns 113 for a missing service. Other failures are not safe
    // evidence that an existing service has stopped.
    if (state.status !== 0 && state.status !== 113)
      throw new Error(`Could not inspect the service: ${state.stderr || 'launchctl failed'}`);
    wasRegistered = state.status === 0;
    if (wasRegistered) {
      const result = run('/bin/launchctl', ['bootout', domain, p.agent], { encoding: 'utf8' });
      if (result.error || result.status !== 0)
        throw new Error(`Could not stop the service: ${result.stderr || result.error?.message || 'launchctl failed'}`);
    }
  } catch (error) {
    rmSync(staging, { recursive: true, force: true });
    throw error;
  }
  let moved = false, installed = false;
  try {
    if (existsSync(p.runtime)) { renameSync(p.runtime, backup); moved = true; }
    renameSync(staging, p.runtime); installed = true;
    writeFileSync(p.config, JSON.stringify({ ...saved, host, ...identity }, null, 2) + '\n', { mode: 0o600 });
    writeFileSync(p.agent, launchAgent({ node: path.join(p.runtime, 'node'), script: path.join(p.runtime, 'src/bridge.js'),
      host, fallbackHost: saved.fallbackHost, log: p.log, ...identity }), { mode: 0o600 });
    const registered = run('/bin/launchctl', ['bootstrap', domain, p.agent], { encoding: 'utf8' });
    if (registered.error || registered.status !== 0) throw new Error(`Could not start the service: ${registered.stderr || registered.error?.message || 'launchctl failed'}`);
  } catch (error) {
    run('/bin/launchctl', ['bootout', domain, p.agent], { encoding: 'utf8' });
    if (installed) rmSync(p.runtime, { recursive: true, force: true });
    if (moved) renameSync(backup, p.runtime);
    for (const [file, contents] of [[p.config, previousConfig], [p.agent, previousAgent]]) {
      if (contents) writeFileSync(file, contents, { mode: 0o600 }); else rmSync(file, { force: true });
    }
    if (previousAgent && wasRegistered) {
      const restored = run('/bin/launchctl', ['bootstrap', domain, p.agent], { encoding: 'utf8' });
      if (restored.error || restored.status !== 0)
        error.message += ` Previous files were restored, but the previous service could not restart: ${restored.stderr || restored.error?.message || 'launchctl failed'}`;
    }
    throw error;
  } finally { rmSync(staging, { recursive: true, force: true }); }
  rmSync(backup, { recursive: true, force: true });
  return p;
}

export function removeBundle({ home = homedir(), uid = process.getuid(), run = spawnSync } = {}) {
  const p = setupPaths(home);
  const state = run('/bin/launchctl', ['print', `gui/${uid}/${label}`], { encoding: 'utf8' });
  if (state.error || ![0, 113].includes(state.status)) throw new Error('Could not inspect the service. Removal cancelled.');
  if (state.status === 0) {
    const stopped = run('/bin/launchctl', ['bootout', `gui/${uid}`, p.agent], { encoding: 'utf8' });
    if (stopped.error || stopped.status !== 0) throw new Error('Could not stop the service. Removal cancelled; please retry.');
  }
  rmSync(p.agent, { force: true });
  rmSync(p.runtime, { recursive: true, force: true });
  // Retain the small saved phone configuration so a reinstall keeps its identity.
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.includes('--remove')) { removeBundle(); console.log('Uninstall successful. Saved phone settings are kept.'); }
    else {
      console.log('Finding your iPhone…');
      const host = chooseReceiver();
      installBundle({ host });
      console.log('Installation complete. Open Control Center → Screen Mirroring → iPhone. Keep OpenDisplay open on your iPhone. Using an iPad too? Connect the iPad first.');
    }
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
