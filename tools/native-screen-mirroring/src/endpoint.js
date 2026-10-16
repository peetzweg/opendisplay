// Bonjour setup verifies an IPv4 receiver. Keep hostname-based connections on
// that transport instead of selecting an unscoped link-local IPv6 address.
export function receiverEndpoint(host, port) {
  return /\.local\.?$/i.test(host)
    ? { host, port, family: 4, autoSelectFamily: false }
    : { host, port };
}
