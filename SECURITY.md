# Security

OpenDisplay is designed for local use. It captures your Mac display and sends
frames directly to a receiver on USB or the local network.

## Security Model

- No project-operated relay server is used for screen content.
- WiFi mode uses local-network discovery and a direct TCP connection.
- USB mode uses local device transport where supported.
- macOS Screen Recording permission is required for capture.
- macOS Accessibility permission is required for injected touch and scroll input.

## Current Caveats

- WiFi pairing and transport encryption are not production-grade in this fork.
- Use trusted local networks.
- Avoid exposing receiver ports outside your LAN.
- VPN TUN mode, firewall tools, and network filters can affect discovery and
  latency.
- Android receiver behavior depends on device vendor networking and decoder
  implementations.

## Reporting Security Issues

If you find a security issue, avoid publishing exploit details in a public issue
first. Open a minimal private contact path if available on the repository owner
profile, or create a public issue with a high-level summary that does not
include reproduction details.

Useful security reports include:

- affected platform and OS version
- transport path: USB or WiFi
- whether the issue requires local-network access
- what permission state was active
- impact and expected mitigation

## Dependency And Build Trust

Build locally from source when evaluating this fork. Generated build output,
APK files, provisioning profiles, and signing credentials should not be
committed to the repository.
