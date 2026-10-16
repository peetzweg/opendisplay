import { spawnSync } from 'node:child_process';
import { chmodSync, cpSync, existsSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = fileURLToPath(new URL('..', import.meta.url));
export function assertSystemDependencies(output) {
  const dependencies = output.split('\n').slice(1).map(line => line.trim().split(' (')[0]).filter(Boolean);
  if (!dependencies.length) throw new Error('Could not inspect Mach-O dependencies.');
  for (const dependency of dependencies)
    if (!dependency.startsWith('/usr/lib/') && !dependency.startsWith('/System/Library/'))
      throw new Error(`Installer would depend on an external library: ${dependency}`);
}

export function buildInstaller({ root = projectRoot, node = process.execPath, sign = process.env.DEVELOPER_ID_APPLICATION,
  run = spawnSync } = {}) {
  function command(binary, args, options = {}) {
    const r = run(binary, args, { cwd: root, encoding: 'utf8', ...options });
    if (r.error || r.status !== 0) throw new Error(`${binary} failed: ${r.stderr || r.error?.message || r.status}`);
    return r.stdout || '';
  }
  node = realpathSync(node);
  const version = JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8')).version;
  const arch = command('/usr/bin/lipo', ['-archs', node]).trim();
  if (!['arm64', 'x86_64'].includes(arch)) throw new Error('Build with a single-architecture Node runtime.');
  command('cmake', ['-S', '.', '-B', 'build', '-DMIRROR_INTERNAL_MDNS=ON', '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0', `-DCMAKE_OSX_ARCHITECTURES=${arch}`]);
  command('cmake', ['--build', 'build', '-j', '4']);
  const out = path.join(root, 'build/distribution'); mkdirSync(out, { recursive: true });
  const app = path.join(out, 'Install iPhone Native Mirror.app'); rmSync(app, { recursive: true, force: true });
  const contents = path.join(app, 'Contents'), runtime = path.join(contents, 'Resources/runtime');
  mkdirSync(path.join(contents, 'MacOS'), { recursive: true }); mkdirSync(runtime, { recursive: true });
  for (const dir of ['src', 'scripts', 'test', 'native', 'vendor']) cpSync(path.join(root, dir), path.join(runtime, dir), { recursive: true });
  for (const name of ['package.json', 'CMakeLists.txt', 'LICENSE', 'README.md', 'Review.command', 'Install.command'])
    cpSync(path.join(root, name), path.join(runtime, name));
  mkdirSync(path.join(runtime, 'build'));
  for (const name of ['airplay-bridge', 'iphone-display-error']) cpSync(path.join(root, 'build', name), path.join(runtime, 'build', name));
  cpSync(node, path.join(runtime, 'node')); chmodSync(path.join(runtime, 'node'), 0o755);
  const notices = path.join(contents, 'Resources/Third Party Notices'); mkdirSync(notices, { recursive: true });
  const nodeLicense = path.resolve(node, '../../LICENSE');
  if (!existsSync(nodeLicense)) throw new Error('Node distribution LICENSE is required beside its bin directory.');
  cpSync(nodeLicense, path.join(notices, 'Node-LICENSE.txt'));
  for (const [dependency, files] of [['libplist-2.0', ['COPYING', 'COPYING.LESSER']], ['openssl', ['LICENSE.txt']]]) {
    const prefix = command('pkg-config', ['--variable=prefix', dependency]).trim();
    for (const name of files) cpSync(path.join(prefix, name), path.join(notices, `${dependency}-${name}`));
  }
  const launcher = path.join(contents, 'MacOS/Installer');
  command('/usr/bin/xcrun', ['clang', '-arch', arch, '-mmacosx-version-min=14.0', '-fobjc-arc', '-framework', 'AppKit',
    path.join(root, 'native/setup.m'), '-o', launcher]);
  const plist = { CFBundleIdentifier: 'local.iphone-native-mirror.installer', CFBundleName: 'Install iPhone Native Mirror',
    CFBundleExecutable: 'Installer', CFBundlePackageType: 'APPL', CFBundleVersion: version, CFBundleShortVersionString: version,
    LSMinimumSystemVersion: '14.0', NSHighResolutionCapable: true,
    NSBonjourServices: ['_opensidecar._tcp'],
    NSLocalNetworkUsageDescription: 'Find your iPhone running OpenDisplay on the local network.' };
  const info = path.join(contents, 'Info.plist'); writeFileSync(info, JSON.stringify(plist));
  command('/usr/bin/plutil', ['-convert', 'xml1', info]);
  const binaries = [path.join(runtime, 'node'), path.join(runtime, 'build/airplay-bridge'), path.join(runtime, 'build/iphone-display-error'), launcher];
  const entitlements = path.join(out, 'node-entitlements.plist');
  writeFileSync(entitlements, '<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.cs.allow-jit</key><true/></dict></plist>');
  for (const binary of binaries) {
    assertSystemDependencies(command('/usr/bin/otool', ['-L', binary]));
    const binaryArch = command('/usr/bin/lipo', ['-archs', binary]).trim();
    if (binaryArch !== arch) throw new Error(`Architecture mismatch: ${binary}`);
    command('/usr/bin/codesign', ['--force', '--sign', sign || '-', ...(sign ? ['--options', 'runtime', '--timestamp'] : []),
      ...(sign && binary === binaries[0] ? ['--entitlements', entitlements] : []), binary]);
  }
  command('/usr/bin/codesign', ['--force', '--sign', sign || '-', ...(sign ? ['--options', 'runtime', '--timestamp'] : []), app]);
  command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
  const manifest = { version, architecture: arch, minimumMacOS: '14.0', signing: sign ? 'Developer ID; notarization still required' : 'ad-hoc review build; not notarized',
    runtime: command(node, ['--version']).trim(), source: 'https://github.com/therealjosemaria/opendisplay/tree/native-screen-mirroring/tools/native-screen-mirroring' };
  writeFileSync(path.join(contents, 'Resources/manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  // Re-sign after writing the manifest into the bundle's sealed resources.
  command('/usr/bin/codesign', ['--force', '--sign', sign || '-', ...(sign ? ['--options', 'runtime', '--timestamp'] : []), app]);
  command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
  const zip = path.join(out, `iPhone-Native-Mirror-${version}-${arch}.zip`);
  rmSync(zip, { force: true });
  command('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, zip]);
  return { app, zip, manifest };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try { console.log(JSON.stringify(buildInstaller(), null, 2)); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
