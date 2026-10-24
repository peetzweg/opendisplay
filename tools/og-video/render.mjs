// Renders tools/og-video/scene.html into public/og.mp4, the site's og:video.
//
//   node tools/og-video/render.mjs [--fps 60] [--out public/og.mp4]
//
// Steps the scene's clock frame by frame in headless Chrome at 2x, then lets
// ffmpeg downscale (free supersampling) and encode H.264 Main for the widest
// og:video support. og.png stays the og:image; most link previews only show that. Needs Google Chrome and ffmpeg on PATH.
import { chromium } from 'playwright-core';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : fallback;
};
const fps = Number(arg('fps', 60));
const out = resolve(root, arg('out', 'public/og.mp4'));
const W = 1200, H = 630, SCALE = 2;

const frames = mkdtempSync(join(tmpdir(), 'og-video-'));
const browser = await chromium.launch({ channel: 'chrome' });
try {
  const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: SCALE });
  await page.goto(pathToFileURL(join(here, 'scene.html')).href + '?render');
  await page.evaluate(() => document.fonts.ready);
  const duration = await page.evaluate(() => window.DURATION);
  const stage = page.locator('#stage');
  const total = Math.round(duration * fps);
  for (let i = 0; i < total; i++) {
    await page.evaluate(t => window.renderAt(t), i / fps);
    await stage.screenshot({ path: join(frames, `f${String(i).padStart(5, '0')}.png`) });
    if (i % fps === 0) process.stdout.write(`\rframe ${i}/${total}`);
  }
  process.stdout.write(`\rframe ${total}/${total}\n`);
} finally {
  await browser.close();
}

execFileSync('ffmpeg', [
  '-y', '-loglevel', 'error', '-framerate', String(fps), '-i', join(frames, 'f%05d.png'),
  '-vf', `scale=${W}:${H}:flags=lanczos`, '-c:v', 'libx264', '-profile:v', 'main', '-level', '4.0', '-preset', 'slow', '-crf', '18',
  '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out,
], { stdio: 'inherit' });
rmSync(frames, { recursive: true, force: true });
console.log(`wrote ${out}`);
