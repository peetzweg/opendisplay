// Protocol simulator only: no H.264 decoder, AirPlay negotiation, or Sidecar.
import net from 'node:net';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import assert from 'node:assert/strict';
import { Decoder, frame } from '../../src/protocol.js';

export async function virtualPhone(t, options = {}) {
  const dir = await mkdtemp(path.join(tmpdir(), 'mirror-virtual-'));
  const control = path.join(dir, 'active');
  await writeFile(control, 'false');
  const phone = { connections: [], messages: [], videos: 0, reportPlayback: true, log: '', errors: [] };
  const server = net.createServer(socket => {
    phone.connections.push(socket);
    const decoder = new Decoder(body => {
      if (body[0] === 0) {
        phone.videos++;
        options.onVideo?.(body, socket);
        if (phone.reportPlayback) socket.write(frame({ type: 'stats', fps: 30 }));
      } else {
        const message = JSON.parse(body);
        phone.messages.push(message);
        if (message.type === 'ping') socket.write(frame({ type: 'ping', t: message.t }));
      }
    }, 16 * 1024 * 1024);
    socket.on('error', () => {});
    socket.on('data', bytes => { try { decoder.push(bytes); } catch (error) { phone.errors.push(error); socket.destroy(); } });
    // Send the initial hello in separate TCP writes to exercise partial framing.
    const hello = options.rawHello || frame(options.hello || { type: 'hello', pv: 3, name: 'Virtual phone', pixelsWide: 1290, pixelsHigh: 2796 });
    socket.write(hello.subarray(0, 2));
    setTimeout(() => { if (!socket.destroyed) socket.write(hello.subarray(2)); }, options.helloDelayMs || 15);
  });
  let child;
  t.after(async () => {
    if (child && child.exitCode === null && child.signalCode === null) {
      const exited = once(child, 'exit');
      child.kill();
      const force = setTimeout(() => child.kill('SIGKILL'), 1500);
      await exited; clearTimeout(force);
    }
    for (const socket of phone.connections) socket.destroy();
    await new Promise(resolve => server.close(resolve));
    await rm(dir, { recursive: true, force: true });
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  child = spawn(process.execPath, [fileURLToPath(new URL('../../src/bridge.js', import.meta.url))], {
    env: { ...process.env, IPHONE_HOST: '127.0.0.1', IPHONE_PORT: String(server.address().port),
      AIRPLAY_BINARY: fileURLToPath(new URL('../../scripts/fake-airplay-receiver.cjs', import.meta.url)),
      MIRROR_ERROR_BINARY: fileURLToPath(new URL('../../scripts/fake-readiness-error.cjs', import.meta.url)),
      ERROR_MARKER: path.join(dir, 'error'), SESSION_CONTROL_FILE: control, SESSION_PREFLIGHT: '1',
      SESSION_KEYFRAME_VIDEO: '1', SESSION_VIDEO_INTERVAL_MS: '100', MIRROR_READY_TIMEOUT_MS: '1500',
      MIRROR_HELLO_TIMEOUT_MS: '1200', MIRROR_STARTUP_KEYFRAME_MS: '100', ...options.env },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  child.stderr.on('data', bytes => { phone.log += bytes; });
  child.on('error', error => phone.errors.push(error));
  phone.until = async predicate => {
    const deadline = Date.now() + 4000;
    while (!predicate()) {
      assert.equal(child.exitCode, null, phone.log);
      assert.equal(child.signalCode, null, phone.log);
      assert.deepEqual(phone.errors, []);
      assert.ok(Date.now() < deadline, `Virtual test timed out:\n${phone.log}`);
      await delay(20);
    }
    assert.deepEqual(phone.errors, []);
  };
  phone.select = async active => writeFile(control, String(active));
  phone.send = (...messages) => phone.connections.at(-1).write(Buffer.concat(messages.map(frame)));
  phone.rotate = async (width, height) => {
    const welcomes = phone.messages.filter(m => m.type === 'welcome').length;
    const logOffset = phone.log.length;
    phone.send({ type: 'hello', pv: 3, panel: { pixelsWide: width, pixelsHigh: height } }, { type: 'ping', t: 123 });
    await phone.until(() => phone.messages.filter(m => m.type === 'welcome').length > welcomes);
    await phone.until(() => phone.log.slice(logOffset).includes(`AIRPLAY-ORIENTATION ${Math.floor(width / 4) * 4}x${Math.floor(height / 4) * 4}`));
  };
  phone.waitForExit = () => child.exitCode !== null || child.signalCode !== null ? Promise.resolve() : once(child, 'exit');
  await phone.until(() => phone.log.includes('FIXTURE-READY'));
  return phone;
}
