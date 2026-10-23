// Run only local protocol simulations. Never start the installed native service.
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

console.log('Virtual receiver tests: real Node bridge, simulated AirPlay source and phone.');
console.log('Not tested: H.264 decoding, native picker, Sidecar, audio routing, Wi-Fi or Tailscale.');
const child = spawn(process.execPath, ['--test', 'test/lifecycle.test.js', 'test/virtual.test.js'], {
  cwd: fileURLToPath(new URL('..', import.meta.url)),
  env: { ...process.env, RUN_NATIVE_TESTS: '1', RUN_VIRTUAL_TESTS: '1' }, stdio: 'inherit',
});
child.on('error', error => { console.error(error.message); process.exitCode = 1; });
child.on('exit', (code, signal) => { process.exitCode = signal ? 1 : code; });
