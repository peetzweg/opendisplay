# Vendored UxPlay source

Upstream: https://github.com/FDH2/UxPlay

Base commit: `ec203121355220dd90278a369eeabb0b8ba4f14a`.

This repository includes the receiver libraries needed by iPhone Native Mirror.
Original copyright and license notices are retained. The project is independent
of UxPlay and OpenDisplay.

Local modifications by Jose Mosciaro, 14 October 2026:

- `lib/global.h`: allow configurable model and protocol version constants.
- `lib/dns_sd/dns_sd.c`: advertise a persistent system pairing identity.
- `lib/mdnsd/dnssd_mdnsd.c`: distinct configurable mDNS hostname and pairing identity.
- `lib/raop.h`: add the phone-readiness preflight callback.
- `lib/raop.c`: restrict installed receiver connections to the same Mac; track
  preflight lifecycle; log request paths without headers or query strings.
- `lib/raop_handlers.h`: gate SETUP on phone readiness and reject unavailable receivers.

Additional changes on 14 October 2026 for v0.0.11: `lib/raop.c` accepts a configured
event port, and `lib/raop_handlers.h` includes it in the initial SETUP response so
the same-Mac bridge can send live display information and keyframe requests.

The bridge's native entry point, Node transport, installer, error UI and tests
live outside the vendored source directory.
