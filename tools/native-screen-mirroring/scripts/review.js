import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { isIP } from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { installationIdentity } from '../src/installer.js';
import { installPackage } from './install-package.js';

const projectRoot = fileURLToPath(new URL('..', import.meta.url));

export function phoneAddress(value) {
  const host = String(value || '').trim();
  if (isIP(host) || (host.length <= 253 && host.split('.').every(label =>
    /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label)))) return host;
  throw new Error('Enter an IP address or hostname, without a URL or port.');
}

export function review({ mode = 'run', env = process.env, root = projectRoot,
  platform = process.platform, run = spawnSync, install = installPackage } = {}) {
  if (platform !== 'darwin') throw new Error('macOS is required.');
  if (!['run', 'check', 'verify', 'install'].includes(mode)) throw new Error('Use --check, --verify or --install, or no option to run.');
  if (Number(process.versions.node.split('.')[0]) < 20) throw new Error('Node 20+ is required.');
  function command(binary, args, options = {}) {
    const result = run(binary, args, { cwd: root, env, stdio: 'inherit', ...options });
    if (result.error || result.status !== 0)
      throw new Error(`${binary} failed${result.error ? `: ${result.error.message}` : ` (exit ${result.status})`}.`);
    return result;
  }
  console.log('Checking CMake, pkg-config, libplist and OpenSSL.');
  try {
    command('cmake', ['--version'], { stdio: 'ignore' });
    command('pkg-config', ['--exists', 'libplist-2.0'], { stdio: 'ignore' });
    command('pkg-config', ['--exists', 'openssl'], { stdio: 'ignore' });
  } catch (error) {
    throw new Error(`${error.message}\nInstall prerequisites with: brew install cmake pkgconf libplist openssl@3\nThis installs the compiler tools and libraries used by the AirPlay receiver.`);
  }
  if (mode === 'check') { console.log('Prerequisites are ready.'); return; }
  let host;
  if (mode === 'run' || mode === 'install') {
    const action = mode === 'install' ? 'Install' : 'Start Review';
    let discovered = [];
    if (!env.IPHONE_HOST) {
      console.log('Looking for OpenDisplay receivers on this network. Keep the phone app open.');
      const scan = run(process.execPath, ['scripts/discover.js'], { cwd: root, env, encoding: 'utf8', timeout: 55000, stdio: ['ignore', 'pipe', 'pipe'] });
      if (scan.status === 0) {
        try { discovered = JSON.parse(scan.stdout); } catch { /* Manual fallback below. */ }
      }
    }
    let answer = env.IPHONE_HOST;
    if (!answer && discovered.length === 1) {
      answer = discovered[0].host;
      console.log(`Found OpenDisplay: ${discovered[0].name}`);
    } else if (!answer && discovered.length > 1) {
      const labels = discovered.map((device, i) => `${i + 1}. ${device.name}`);
      const selected = command('/usr/bin/osascript', ['-e',
        `set chosen to choose from list {${labels.map(label => JSON.stringify(label)).join(', ')}} with title "iPhone Native Mirror" with prompt "Choose the phone running OpenDisplay:"\nif chosen is false then error number -128\nreturn item 1 of chosen`],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).stdout.trim();
      answer = discovered[labels.indexOf(selected)]?.host;
      if (!answer) throw new Error('No OpenDisplay receiver selected.');
    }
    answer ||= command('/usr/bin/osascript', ['-e',
      `text returned of (display dialog "No OpenDisplay receiver was found. Keep the app open on an unlocked phone on the same Wi-Fi. If discovery is blocked, enter its address from iPhone Settings > Wi-Fi > your network, or from the Tailscale app." with title "iPhone Native Mirror" default answer "" buttons {"Cancel", "${action}"} default button "${action}")`],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).stdout;
    host = phoneAddress(answer);
  }
  if (mode === 'install') {
    console.log('Packaging the source, installing the bridge, and registering its login service.');
    install({ host, root, env, run });
    return;
  }
  console.log('Building the native receiver and error dialog.');
  command('cmake', ['-S', '.', '-B', 'build', '-DMIRROR_INTERNAL_MDNS=ON', ...(mode === 'verify' ? ['-DMIRROR_BUILD_TESTS=ON'] : [])]);
  command('cmake', ['--build', 'build', '-j', '4']);
  if (mode === 'verify') {
    console.log('Running all automated tests, including local native/network checks.');
    command('ctest', ['--test-dir', 'build', '--output-on-failure']);
    const tests = readdirSync(path.join(root, 'test')).filter(name => name.endsWith('.test.js')).sort().map(name => path.join('test', name));
    command(process.execPath, ['--test', ...tests], { env: { ...env, RUN_NATIVE_TESTS: '1', RUN_VIRTUAL_TESTS: '1', RUN_VIDEO_TESTS: '1', RUN_SOAK_TESTS: '1' } });
    return;
  }
  const identityFile = path.join(root, 'build', 'review-identity.json');
  const saved = existsSync(identityFile) ? JSON.parse(readFileSync(identityFile, 'utf8')) : {};
  const identity = installationIdentity(saved);
  mkdirSync(path.dirname(identityFile), { recursive: true });
  writeFileSync(identityFile, JSON.stringify(identity) + '\n', { mode: 0o600 });
  console.log('Open macOS Screen Mirroring and select OpenDisplay Review.');
  console.log('Use Extended Display. Press Control-C here to stop; nothing starts at login.');
  command(process.execPath, ['src/bridge.js'], { env: { ...env, IPHONE_HOST: host,
    MIRROR_NAME: 'OpenDisplay Review', MIRROR_LOCAL_ONLY: '1',
    MIRROR_HOST_LABEL: identity.hostLabel, MIRROR_DEVICE_ID: identity.deviceId } });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    const mode = args.length === 0 ? 'run' : args.length === 1 ? args[0].replace(/^--/, '') : 'invalid';
    review({ mode });
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
