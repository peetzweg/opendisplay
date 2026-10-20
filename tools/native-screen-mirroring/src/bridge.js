import net from 'node:net';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { Decoder, frame } from './protocol.js';
import { VideoGate, StartupReplay } from './video.js';
import { ReadinessGuard } from './readiness.js';
import { prepareTailscale } from './tailscale.js';
import { AirPlayEvents } from './airplay-events.js';
import { NetworkMonitor } from './network-monitor.js';
import { receiverEndpoint, ReceiverRoute } from './endpoint.js';
import { SidecarHelp } from './sidecar-help.js';

const host = process.env.IPHONE_HOST;
if (!host) throw new Error('Set IPHONE_HOST to the iPhone LAN or Tailscale address');
const route = new ReceiverRoute(host, process.env.IPHONE_FALLBACK_HOST);
const binary = process.env.AIRPLAY_BINARY || fileURLToPath(new URL('../build/airplay-bridge', import.meta.url));
const errorBinary = process.env.MIRROR_ERROR_BINARY || fileURLToPath(new URL('../build/iphone-display-error', import.meta.url));
const readiness = new ReadinessGuard(() => failSession('No iPhone playback confirmation'), {
  timeoutMs: Number(process.env.MIRROR_READY_TIMEOUT_MS || 10000),
});
const receiverReadiness = new ReadinessGuard(() => {
  if (route.canFallback && socket && !ready) {
    socket.destroy(new Error('Local receiver did not answer; trying Tailscale'));
    return;
  }
  failSession('iPhone receiver did not answer');
}, {
  timeoutMs: Number(process.env.MIRROR_HELLO_TIMEOUT_MS || 3000),
});
let stopping = false, active = false, socket, retry, heartbeat, ready = false, generation = 0, preflightPending = false;
let sidecarDialog;
const sidecarHelp = new SidecarHelp({
  show: () => {
    if (!active || stopping || sidecarDialog) return;
    const dialog = spawn(errorBinary, ['sidecar'], { stdio: 'ignore' });
    sidecarDialog = dialog;
    const clear = () => { if (sidecarDialog === dialog) sidecarDialog = undefined; };
    dialog.on('error', error => { clear(); console.error('SIDECAR-HELP:', error.message); });
    dialog.on('exit', clear);
  },
  onError: reason => console.error('SIDECAR-HELP unavailable:', reason),
});
let receivedVideo = false, forwardedVideo = false;
let startupProbe;
const startupReplay = new StartupReplay({ idleMs: Number(process.env.MIRROR_STARTUP_IDLE_MS || 1000) });
const networkMonitor = new NetworkMonitor({
  isActive: () => active || stopping,
  onRefresh: () => {
    console.error('AIRPLAY-NETWORK changed or resumed; refreshing discovery');
    stop(); // launchd restarts the service with fresh addresses and multicast memberships.
  },
});
networkMonitor.start();
let preflightRefusals = 0;
const displayEvents = new AirPlayEvents({
  width: Number(process.env.MIRROR_WIDTH || 1288), height: Number(process.env.MIRROR_HEIGHT || 2796),
  onChange: size => {
    gate.reset(); startupReplay.clear(); pendingVideo = []; pendingBytes = 0;
    console.error('AIRPLAY-ORIENTATION', `${size.width}x${size.height}`);
  },
  onError: reason => console.error('AIRPLAY-EVENT-CHANNEL:', reason),
});
const eventPort = await displayEvents.start();
const receiver = spawn(binary, [process.env.MIRROR_NAME || 'iPhone Mirror'], {
  stdio: ['ignore', 'pipe', 'inherit', 'pipe', 'pipe'], env: { ...process.env, MIRROR_EVENTS: '1', MIRROR_EVENT_PORT: String(eventPort) },
});
const sessionDecoder = new Decoder(body => {
  const message = JSON.parse(body.toString());
  if (message.active === true) displayEvents.setActive(true);
  if (message.preflight === true) {
    preflightPending = true;
    if (ready) { approvePreflight(); return; }
  }
  if ((message.active === true || message.preflight === true) && !active) {
    active = true;
    route.reset();
    receivedVideo = false; forwardedVideo = false;
    const session = ++generation;
    prepareTailscale(host).then(state => {
      if (!active || stopping || session !== generation) return;
      if (state === 'missing' || state === 'unconfigured') return failSession('Tailscale setup required', 'tailscale');
      if (state === 'login') return failSession('Tailscale login opened', 'login');
      receiverReadiness.start();
      connect();
    }).catch(() => { if (session === generation) failSession('Tailscale setup required', 'tailscale'); });
  } else if (message.active === false && active) {
    displayEvents.setActive(false);
    sidecarHelp.setActive(false);
    active = false;
    generation++;
    readiness.stop();
    receiverReadiness.stop();
    disconnectPhone();
    console.error('IPHONE-SESSION ended with AirPlay');
  }
});
receiver.stdio[4].on('error', error => { if (!stopping) console.error('AIRPLAY-APPROVAL:', error.message); });
function approvePreflight() {
  if (!preflightPending) return;
  preflightPending = false;
  receiver.stdio[4].write(Buffer.from([1]));
  console.error('AIRPLAY-PREFLIGHT approved');
}
receiver.stdio[3].on('data', bytes => {
  try { sessionDecoder.push(bytes); }
  catch (error) { console.error('AIRPLAY-EVENT:', error.message); stop(); process.exitCode = 1; }
});
const gate = new VideoGate();
let pendingVideo = [], pendingBytes = 0;
const videoDecoder = new Decoder(body => {
  if (!active) return;
  if (!receivedVideo) { receivedVideo = true; console.error('AIRPLAY-VIDEO received'); }
  const accepted = gate.accept(body);
  if (!accepted) return;
  if (!forwardedVideo) { forwardedVideo = true; console.error('IPHONE-VIDEO forwarding keyframe'); }
  if (startupProbe !== undefined) startupReplay.observe(accepted);
  const packet = frame(accepted);
  if (!ready || !socket || socket.destroyed) {
    pendingBytes += packet.length;
    if (pendingBytes > 4 * 1024 * 1024) {
      pendingVideo = []; pendingBytes = 0; gate.reset();
    } else pendingVideo.push(packet);
  } else if (!socket.write(packet)) receiver.stdout.pause();
}, 16 * 1024 * 1024);
receiver.stdout.on('data', bytes => {
  try { videoDecoder.push(bytes); }
  catch (error) { console.error('AIRPLAY-VIDEO:', error.message); stop(); process.exitCode = 1; }
});
receiver.on('error', error => { console.error('AIRPLAY:', error.message); stop(); process.exitCode = 1; });
receiver.on('exit', (code, signal) => {
  console.error('AIRPLAY-EXIT', code, signal);
  if (!stopping) { stop(); process.exitCode = 1; }
});
function connect() {
  if (!active || stopping) return;
  clearInterval(startupProbe); startupProbe = undefined; startupReplay.clear();
  ready = false;
  let handshaken = false;
  const connection = net.createConnection(receiverEndpoint(route.current, Number(process.env.IPHONE_PORT || 9000)));
  socket = connection;
  connection.setNoDelay(true);
  connection.on('drain', () => receiver.stdout.resume());
  connection.setTimeout(8000, () => connection.destroy(new Error('iPhone silent')));
  const decoder = new Decoder(payload => {
    const message = JSON.parse(payload.toString());
    if (message.type === 'hello') {
      if ((message.pv ?? 1) > 3) throw new Error('Unsupported receiver protocol');
      displayEvents.observeHello(message);
      connection.write(frame({ type: 'welcome', pv: 3, min: 1 }));
      if (ready) return; // Acknowledge rotation without restarting the session or heartbeat.
      ready = true;
      handshaken = true;
      sidecarHelp.setActive(true);
      console.error('IPHONE-TRANSPORT', route.current === host ? 'primary' : 'Tailscale fallback');
      receiverReadiness.stop();
      readiness.start();
      // Receiver stats are video-driven. Request a few fresh frames so an idle
      // desktop can confirm startup, then stop probing once playback is reported.
      startupReplay.clear();
      startupProbe = setInterval(() => {
        displayEvents.requestKeyframe();
        if (socket !== connection || connection.destroyed || connection.writableLength > 4 * 1024 * 1024) return;
        const packets = startupReplay.take();
        if (packets.length) console.error('IPHONE-STARTUP replaying idle keyframe group');
        for (const packet of packets) connection.write(frame(packet));
      }, Number(process.env.MIRROR_STARTUP_KEYFRAME_MS || 1200));
      console.error('IPHONE-READY', message.name || host);
      console.error('IPHONE-PANEL', JSON.stringify(message.panel || { width: message.pixelsWide, height: message.pixelsHigh, scale: message.scale }));
      for (const packet of pendingVideo) {
        if (!connection.write(packet)) receiver.stdout.pause();
      }
      pendingVideo = []; pendingBytes = 0;
      heartbeat = setInterval(() => connection.write(frame({ type: 'ping', t: Date.now() })), 2000);
      approvePreflight();
    } else if (message.type === 'ping') {
      connection.write(frame({ type: 'pong', t: message.t, mt: Date.now() }));
    } else if (message.type === 'stats') {
      if (readiness.observe(message) && startupProbe !== undefined) {
        clearInterval(startupProbe); startupProbe = undefined; startupReplay.clear();
        console.error('IPHONE-PLAYBACK confirmed');
      }
      console.error('PHONE-STATS', JSON.stringify(message));
    }
    else if (message.type === 'kf') { gate.reset(); displayEvents.requestKeyframe(); console.error('PHONE-KF: requested AirPlay IDR'); }
    else if (message.type === 'closing' || message.type === 'sleeping') failSession('iPhone receiver closed or locked');
  });
  connection.on('data', data => {
    if (socket !== connection) return;
    try { decoder.push(data); } catch (error) { connection.destroy(error); }
  });
  connection.on('error', error => {
    console.error('IPHONE:', error.message);
    if (!route.canFallback && socket === connection && preflightPending && error.code === 'ECONNREFUSED' && ++preflightRefusals >= 2)
      failSession('iPhone receiver refused the connection');
  });
  connection.on('close', () => {
    if (socket !== connection) return;
    socket = undefined;
    ready = false;
    gate.reset(); startupReplay.clear(); pendingVideo = []; pendingBytes = 0;
    clearInterval(heartbeat);
    readiness.stop();
    clearInterval(startupProbe); startupProbe = undefined; startupReplay.clear();
    if (handshaken && active && !stopping) receiverReadiness.start();
    receiver.stdout.resume();
    if (!stopping && active) {
      const fallback = !handshaken && route.advance();
      if (fallback) {
        receiverReadiness.stop();
        const session = generation;
        console.error('IPHONE-ROUTE trying Tailscale fallback');
        prepareTailscale(fallback).then(state => {
          if (!active || stopping || session !== generation) return;
          if (state !== 'ready' && state !== 'starting') return failSession('Tailscale is not ready', 'tailscale');
          receiverReadiness.start(); connect();
        }).catch(() => { if (active && !stopping && session === generation) failSession('Tailscale is not ready', 'tailscale'); });
      } else retry = setTimeout(connect, 500);
    }
  });
}
function disconnectPhone() {
  clearTimeout(retry); clearInterval(heartbeat);
  clearInterval(startupProbe); startupProbe = undefined; startupReplay.clear();
  ready = false; gate.reset();
  preflightRefusals = 0;
  preflightPending = false;
  pendingVideo = []; pendingBytes = 0;
  const previous = socket; socket = undefined;
  previous?.destroy();
  receiver.stdout.resume();
}
function stop() {
  sidecarHelp.close();
  sidecarDialog?.kill();
  networkMonitor.close();
  stopping = true; active = false;
  generation++;
  readiness.stop();
  receiverReadiness.stop();
  displayEvents.close();
  const rejectPreflight = preflightPending;
  disconnectPhone();
  // Wake the native approval wait before shutdown joins its request thread.
  if (rejectPreflight && !receiver.stdio[4].destroyed)
    receiver.stdio[4].write(Buffer.from([0]), () => receiver.kill());
  else receiver.kill();
}
function failSession(reason, kind = 'opendisplay') {
  if (!active || stopping) return;
  console.error('IPHONE-NOT-READY:', reason);
  const systemHandlesError = preflightPending && kind === 'opendisplay';
  if (systemHandlesError) console.error('IPHONE-ERROR: macOS handles rejected connection; skipping duplicate dialog');
  // Do not place the error on the AirPlay display while it is being removed.
  receiver.once('exit', () => {
    if (kind === 'login' || systemHandlesError) return;
    const dialog = spawn(errorBinary, [kind], { detached: true, stdio: 'ignore' });
    dialog.on('error', error => console.error('ERROR-DIALOG:', error.message));
    dialog.unref();
  });
  stop();
}
process.on('SIGTERM', stop); process.on('SIGINT', stop);
