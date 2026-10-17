import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { virtualPhone } from './support/virtual-phone.js';
import { fileURLToPath } from 'node:url';

const ffmpeg = process.env.FFMPEG_BINARY || '/opt/homebrew/bin/ffmpeg';
const options = { skip: process.env.RUN_VIDEO_TESTS !== '1', timeout: 20000 };
function clip(width, height) {
  const result = spawnSync(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
    '-i', `testsrc=size=${width}x${height}:rate=10`, '-frames:v', '10', '-pix_fmt', 'yuv420p',
    '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency', '-f', 'h264', 'pipe:1'],
  { timeout: 5000, maxBuffer: 4 * 1024 * 1024 });
  assert.equal(result.status, 0, result.stderr?.toString());
  assert.ok(result.stdout.length > 1000);
  return result.stdout;
}
async function decodedReceiver(t, video, env = {}) {
  const dir = await mkdtemp(path.join(tmpdir(), 'mirror-decoded-'));
  const videoFile = path.join(dir, 'video.h264'); await writeFile(videoFile, video);
  let diagnostics = '', frames = 0, phone;
  const decoder = spawn(ffmpeg, ['-hide_banner', '-loglevel', 'info', '-probesize', '32',
    '-analyzeduration', '0', '-f', 'h264', '-i', 'pipe:0', '-vf', 'showinfo', '-f', 'null', '-'],
  { stdio: ['pipe', 'ignore', 'pipe'] });
  decoder.stdin.on('error', () => {});
  decoder.stderr.on('data', bytes => {
    diagnostics += bytes;
    const next = (diagnostics.match(/Parsed_showinfo_.*\bn:\s*\d+ .*\bs:\d+x\d+/g) || []).length;
    if (next > frames) {
      frames = next;
      if (frames >= Number(env.TEST_MIN_DECODED_FRAMES || 1) && phone?.connections.at(-1) && !phone.connections.at(-1).destroyed) phone.send({ type: 'stats', fps: 1 });
    }
  });
  t.after(async () => {
    if (decoder.exitCode === null && decoder.signalCode === null) {
      const exited = once(decoder, 'exit'); decoder.stdin.end(); decoder.kill();
      const forced = setTimeout(() => decoder.kill('SIGKILL'), 1000);
      await exited; clearTimeout(forced);
    }
    if (!frames) t.diagnostic(diagnostics.slice(-3000));
    await rm(dir, { recursive: true, force: true });
  });
  phone = await virtualPhone(t, { onVideo: body => {
    // Match Shared/StreamReceiver.swift's four-byte-only Annex-B splitter.
    for (let i = 0; i + 2 < body.length; i++) {
      if (body[i] === 0 && body[i + 1] === 0 && body[i + 2] === 1)
        assert.equal(body[i - 1], 0, 'Wire video must use the iPhone receiver start-code format');
    }
    decoder.stdin.write(body);
  },
    env: { SESSION_VIDEO_FILE: videoFile, SESSION_VIDEO_INTERVAL_MS: '200', MIRROR_READY_TIMEOUT_MS: '2500', ...env } });
  phone.reportPlayback = false;
  return { phone, decoder, replace: bytes => writeFile(videoFile, bytes),
    get diagnostics() { return diagnostics; }, get frames() { return frames; } };
}

test('real decode: bridge forwards decodable video and resolution changes on one phone connection', options, async t => {
  const portrait = clip(320, 640), landscape = clip(640, 320);
  const receiver = await decodedReceiver(t, portrait), { phone } = receiver;
  await phone.select(true);
  await phone.until(() => receiver.frames >= 10 && phone.log.includes('IPHONE-PLAYBACK confirmed'));
  assert.match(receiver.diagnostics, /s:320x640/);
  for (let cycle = 0; cycle < 2; cycle++) {
    for (const [video, width, height] of [[landscape, 640, 320], [portrait, 320, 640]]) {
      await phone.rotate(width, height);
      const previousFrames = receiver.frames;
      const previousLength = receiver.diagnostics.length;
      await receiver.replace(video);
      await phone.until(() => receiver.frames > previousFrames && new RegExp(`s:${width}x${height}\\b`).test(receiver.diagnostics.slice(previousLength)));
      assert.equal(phone.connections.length, 1);
      assert.equal(phone.connections[0].destroyed, false);
    }
  }
  phone.log = '';
  const frames = receiver.frames;
  phone.connections[0].destroy();
  await phone.until(() => phone.connections.length === 2 && receiver.frames > frames && phone.log.includes('IPHONE-PLAYBACK confirmed'));
  assert.doesNotMatch(phone.log, /IPHONE-NOT-READY/);
});

test('real decode: forwarded corrupt H.264 cannot confirm playback', options, async t => {
  const receiver = await decodedReceiver(t, Buffer.from([0,0,0,1,7,0x88,0,0,0,1,8,0x88,0,0,0,1,5,0x88]));
  const { phone } = receiver;
  await phone.select(true); await phone.waitForExit();
  assert.ok(phone.videos > 0, 'Corrupt video reached the phone');
  assert.equal(receiver.frames, 0, receiver.diagnostics);
  assert.doesNotMatch(phone.log, /IPHONE-PLAYBACK confirmed/);
  assert.match(phone.log, /No iPhone playback confirmation/);
});

test('real decode: non-keyframe input waits for a recoverable SPS/PPS/IDR stream', options, async t => {
  const valid = clip(320, 640);
  const receiver = await decodedReceiver(t, Buffer.from([0,0,0,1,1,0x88]));
  const { phone } = receiver;
  await phone.select(true); await phone.until(() => phone.log.includes('IPHONE-READY'));
  await new Promise(resolve => setTimeout(resolve, 300));
  assert.equal(phone.videos, 0, 'Bridge must gate undecodable startup interframes');
  await receiver.replace(valid);
  await phone.until(() => receiver.frames > 0 && phone.log.includes('IPHONE-PLAYBACK confirmed'));
  assert.equal(phone.connections.length, 1);
});

for (const scenario of [
  { name: 'exact twenty-frame decoder self-check', env: { LIVE_SELF_TEST: '1' }, code: 0, output: /LIVE-SELF-TEST PASS/ },
  { name: 'failed decoder', env: { LIVE_SELF_TEST: '1', FFMPEG_BINARY: '/usr/bin/false' }, code: 1, output: /LIVE-SELF-TEST FAIL/ },
  { name: 'self-check deadline', env: { LIVE_SELF_TEST: '1', LIVE_TEST_DURATION_MS: '1' }, code: 1, output: /LIVE-FINAL/ },
  { name: 'no native selection', env: { LIVE_SELF_TEST: '0', LIVE_TEST_DURATION_MS: '300' }, code: 2, output: /"status":"not_connected"/ },
]) test(`live tester correctly classifies ${scenario.name} and exits without hanging`, options, () => {
  const result = spawnSync(process.execPath, [fileURLToPath(new URL('../scripts/live-virtual-phone.js', import.meta.url))], {
    env: { ...process.env, LIVE_TEST_DURATION_MS: '4000', ...scenario.env }, timeout: 6000, encoding: 'utf8',
  });
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.status, scenario.code, result.stderr);
  assert.match(result.stdout, scenario.output);
});

test('real decode: idle startup recovers when the sender ignores keyframe requests, then replay stops', options, async t => {
  const receiver = await decodedReceiver(t, clip(320, 640), {
    TEST_MIN_DECODED_FRAMES: '20', SESSION_KEYFRAME_VIDEO: '0', SESSION_VIDEO_INTERVAL_MS: '', MIRROR_STARTUP_IDLE_MS: '100', MIRROR_STARTUP_KEYFRAME_MS: '150'
  });
  const { phone } = receiver;
  await phone.select(true);
  await phone.until(() => phone.log.includes('IPHONE-STARTUP replaying'));
  await phone.until(() => receiver.frames > 0 && phone.log.includes('IPHONE-PLAYBACK confirmed'));
  const count = phone.videos;
  await new Promise(resolve => setTimeout(resolve, 500));
  assert.equal(phone.videos, count, 'Replay stops once decode feedback confirms playback');
  assert.equal(phone.connections.length, 1);
  assert.doesNotMatch(phone.log, /IPHONE-NOT-READY/);
});
