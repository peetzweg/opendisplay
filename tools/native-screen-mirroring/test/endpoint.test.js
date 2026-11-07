import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { once } from 'node:events';
import { receiverEndpoint } from '../src/endpoint.js';

test('Bonjour hostname connection requests IPv4 and reaches the receiver socket', {
  skip: process.env.RUN_NATIVE_TESTS !== '1', timeout: 5000,
}, async () => {
  const peers = [];
  const server = net.createServer(peer => { peers.push(peer); peer.end('receiver'); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  let requestedFamily;
  const socket = net.createConnection({ ...receiverEndpoint('phone.local', server.address().port),
    lookup: (host, options, callback) => {
      assert.equal(host, 'phone.local'); requestedFamily = options.family;
      callback(null, '127.0.0.1', 4);
    } });
  let received = ''; socket.on('data', bytes => { received += bytes; });
  try {
    await once(socket, 'end');
    assert.equal(requestedFamily, 4);
    assert.equal(received, 'receiver');
  } finally {
    socket.destroy(); for (const peer of peers) peer.destroy();
    await new Promise(resolve => server.close(resolve));
  }
});

test('explicit Tailscale and IPv6 targets keep their original address selection', () => {
  for (const host of ['100.106.150.88', 'fd7a:115c:a1e0::1', '192.168.1.119', 'phone.ts.net'])
    assert.deepEqual(receiverEndpoint(host, 9000), { host, port: 9000 });
  assert.equal(receiverEndpoint('Phone.LOCAL.', 9000).family, 4);
});

test('optional VPN fallback keeps the LAN route primary and resets for each session', async () => {
  const { ReceiverRoute } = await import('../src/endpoint.js');
  const route = new ReceiverRoute('phone.local', '100.106.150.88');
  assert.equal(route.current, 'phone.local'); assert.equal(route.canFallback, true);
  assert.equal(route.advance(), '100.106.150.88'); assert.equal(route.canFallback, false);
  assert.equal(route.advance(), undefined); route.reset(); assert.equal(route.current, 'phone.local');
  const unchanged = new ReceiverRoute('phone.local'); assert.equal(unchanged.advance(), undefined);
  assert.equal(unchanged.current, 'phone.local');
  assert.throws(() => new ReceiverRoute('phone.local', '192.168.1.2'), /Tailscale address/);
});
