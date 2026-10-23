import { spawnSync } from 'node:child_process';
import { networkInterfaces } from 'node:os';
import { fileURLToPath } from 'node:url';

// dns-sd watches indefinitely; collect a bounded snapshot of Bonjour only.
export function snapshot(args, run = spawnSync, timeout = 1800) {
  const result = run('/usr/bin/dns-sd', args, {
    encoding: 'utf8', timeout, killSignal: 'SIGTERM', maxBuffer: 256 * 1024,
  });
  if (result.error && result.error.code !== 'ETIMEDOUT') throw result.error;
  return result.stdout || '';
}

export function serviceNames(output) {
  const services = new Set();
  for (const line of output.split('\n')) {
    const match = line.match(/\bAdd\s+\S+\s+\d+\s+local\.\s+_opensidecar\._tcp\.\s+(.+?)\s*$/);
    if (match) services.add(match[1]);
  }
  return [...services].slice(0, 12);
}

export function resolvedService(name, output) {
  const match = output.match(/can be reached at (\S+):([0-9]+)\s/);
  if (!match || Number(match[2]) !== 9000) return null;
  const host = match[1].replace(/\.$/, '');
  if (!/^[a-z0-9.-]+\.local$/i.test(host)) return null;
  const pv = output.match(/\bpv=(\d+)/)?.[1];
  if (pv && Number(pv) > 3) return null;
  return { name, host, id: output.match(/\bid=([^\s]+)/)?.[1] || host };
}

export function discover({ run = spawnSync, interfaces = networkInterfaces() } = {}) {
  const local = new Set(Object.values(interfaces).flat().filter(Boolean).map(i => i.address));
  const found = new Map();
  const names = serviceNames(snapshot(['-B', '_opensidecar._tcp', 'local.'], run));
  for (const name of names) {
    const device = resolvedService(name, snapshot(['-L', name, '_opensidecar._tcp', 'local.'], run));
    if (!device) continue;
    const addresses = snapshot(['-G', 'v4', device.host], run);
    const ips = [...addresses.matchAll(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g)].map(m => m[0]);
    if (!ips.length || ips.some(ip => local.has(ip))) continue;
    if (!found.has(device.id)) found.set(device.id, device);
  }
  return [...found.values()];
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try { console.log(JSON.stringify(discover())); }
  catch (error) { console.error(`Phone discovery failed: ${error.message}`); process.exitCode = 1; }
}
