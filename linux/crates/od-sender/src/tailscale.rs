//! Discovery over Tailscale (#409). Bonjour (§2.1) does not cross a tailnet,
//! so when it finds nothing, dial the online peers on the receiver port (§1)
//! and keep the ones whose first message is a `hello` (§6.1).
//!
//! A probe connects, reads the `hello` and closes without sending a byte.
//! The official receivers park a newcomer while a session is live and only
//! adopt it once it sends something, so a probe never takes over a session.

use std::io::Read;
use std::net::{IpAddr, SocketAddr, TcpStream};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use opendisplay_proto::control::Hello;
use opendisplay_proto::{ControlMessage, DEFAULT_PORT, Deframer};
use serde::Deserialize;
use tracing::debug;

use crate::discover::Found;

/// How long `tailscale status` may take before it is given up on.
const STATUS_TIMEOUT: Duration = Duration::from_secs(2);
/// TCP connect timeout per peer; a tailnet peer that is online answers fast.
const CONNECT_TIMEOUT: Duration = Duration::from_millis(500);
/// How long a connected peer has to send its `hello`.
const HELLO_TIMEOUT: Duration = Duration::from_secs(1);
/// Probe at most this many peers (one thread each); a big tailnet is cut.
const MAX_PEERS: usize = 64;

/// A peer worth probing: online, with an address.
#[derive(Debug, Clone, PartialEq)]
pub struct Peer {
    /// Its Tailscale host name, as `tailscale status` shows it.
    pub name: String,
    pub ip: IpAddr,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Status {
    #[serde(default)]
    backend_state: String,
    // `null` when there are none, as are the lists below.
    #[serde(default)]
    peer: Option<std::collections::BTreeMap<String, PeerStatus>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct PeerStatus {
    #[serde(default)]
    host_name: String,
    #[serde(default, rename = "DNSName")]
    dns_name: String,
    #[serde(default)]
    tailscale_i_ps: Option<Vec<IpAddr>>,
    #[serde(default)]
    online: bool,
}

/// The peers to probe from `tailscale status --json`: online ones, by name,
/// each at its IPv4 address (else its first). Nothing when Tailscale is not
/// running.
pub fn peers(status_json: &str) -> serde_json::Result<Vec<Peer>> {
    let status: Status = serde_json::from_str(status_json)?;
    if status.backend_state != "Running" {
        return Ok(Vec::new());
    }
    let mut peers: Vec<Peer> = status
        .peer
        .unwrap_or_default()
        .into_values()
        .filter(|p| p.online)
        .filter_map(|p| {
            let ip = p
                .tailscale_i_ps
                .unwrap_or_default()
                .into_iter()
                .min_by_key(|a| if a.is_ipv4() { 0 } else { 1 })?;
            let name = if p.host_name.is_empty() {
                p.dns_name.split('.').next().unwrap_or_default().to_string()
            } else {
                p.host_name
            };
            Some(Peer { name, ip })
        })
        .collect();
    peers.sort_by(|a, b| a.name.cmp(&b.name).then(a.ip.cmp(&b.ip)));
    Ok(peers)
}

/// `tailscale status --json`, or `None` (debug-logged) when the CLI is
/// missing, fails or hangs.
fn status() -> Option<String> {
    let mut child = match Command::new("tailscale")
        .args(["status", "--json"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            debug!("tailscale: not used ({e})");
            return None;
        }
    };
    // Read on a thread so a large status cannot fill the pipe and stall.
    let mut stdout = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut s = String::new();
        stdout.read_to_string(&mut s).map(|_| s)
    });
    let deadline = Instant::now() + STATUS_TIMEOUT;
    let exit = loop {
        match child.try_wait() {
            Ok(Some(exit)) => break exit,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            Ok(None) | Err(_) => {
                debug!("tailscale: status did not answer within {STATUS_TIMEOUT:?}");
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    };
    let out = reader.join().ok()?.ok()?;
    if !exit.success() {
        debug!("tailscale: status exited with {exit}");
        return None;
    }
    Some(out)
}

/// The first frame from a receiver, if it is a `hello`.
fn read_hello(r: &mut impl Read) -> Option<Hello> {
    let mut deframer = Deframer::for_sender();
    let mut buf = [0u8; 4096];
    loop {
        if let Some(frame) = deframer.next_frame().ok()? {
            return match ControlMessage::parse(&frame).ok()? {
                ControlMessage::Hello(h) => Some(h),
                _ => None,
            };
        }
        let n = r.read(&mut buf).ok()?;
        if n == 0 {
            return None;
        }
        deframer.push(&buf[..n]);
    }
}

/// What a `hello` from `peer` makes of it; named after the peer, which is
/// how `tailscale status` lists it.
fn found(peer: &Peer, port: u16, hello: Hello) -> Option<Found> {
    let pv = hello.pv.unwrap_or(1);
    (pv >= 1).then(|| Found {
        instance: peer.name.clone(),
        addr: SocketAddr::new(peer.ip, port),
        id: hello.id,
        pv,
    })
}

fn probe(peer: &Peer) -> Option<Found> {
    let addr = SocketAddr::new(peer.ip, DEFAULT_PORT);
    let mut stream = match TcpStream::connect_timeout(&addr, CONNECT_TIMEOUT) {
        Ok(s) => s,
        Err(e) => {
            debug!("tailscale: {} ({addr}): {e}", peer.name);
            return None;
        }
    };
    stream.set_read_timeout(Some(HELLO_TIMEOUT)).ok()?;
    let hello = read_hello(&mut stream);
    debug!(
        "tailscale: {} ({addr}) {}",
        peer.name,
        if hello.is_some() {
            "sent a hello"
        } else {
            "answered without a hello"
        }
    );
    // Dropping the stream closes it before a byte is sent (see the module docs).
    found(peer, DEFAULT_PORT, hello?)
}

/// Receivers among the online Tailscale peers, and how many peers were
/// probed; `None` when Tailscale is not installed or not running.
pub fn discover() -> Option<(Vec<Found>, usize)> {
    let mut peers = match peers(&status()?) {
        Ok(p) => p,
        Err(e) => {
            debug!("tailscale: unreadable status: {e}");
            return None;
        }
    };
    if peers.is_empty() {
        debug!("tailscale: no online peers");
        return None;
    }
    if peers.len() > MAX_PEERS {
        debug!(
            "tailscale: probing the first {MAX_PEERS} of {} peers",
            peers.len()
        );
        peers.truncate(MAX_PEERS);
    }
    let found = std::thread::scope(|s| {
        let probes: Vec<_> = peers.iter().map(|p| s.spawn(|| probe(p))).collect();
        probes
            .into_iter()
            .filter_map(|h| h.join().ok().flatten())
            .collect::<Vec<_>>()
    });
    debug!(
        "tailscale: {} of {} online peers answered as receivers",
        found.len(),
        peers.len()
    );
    Some((found, peers.len()))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `tailscale status --json`, trimmed to what matters, made-up values.
    const STATUS: &str = r#"{
        "Version": "1.90.0",
        "BackendState": "Running",
        "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"],
        "Self": {"HostName": "laptop", "DNSName": "laptop.tail1234.ts.net.",
                 "TailscaleIPs": ["100.64.0.1"], "Online": true},
        "Peer": {
            "nodekey:aa": {"HostName": "galaxy-z-fold7", "DNSName": "galaxy-z-fold7.tail1234.ts.net.",
                           "TailscaleIPs": ["fd7a:115c:a1e0::2", "100.64.0.2"], "Online": true, "OS": "android"},
            "nodekey:bb": {"HostName": "old-nas", "DNSName": "old-nas.tail1234.ts.net.",
                           "TailscaleIPs": ["100.64.0.3"], "Online": false, "OS": "linux"},
            "nodekey:cc": {"HostName": "", "DNSName": "ipad.tail1234.ts.net.",
                           "TailscaleIPs": ["fd7a:115c:a1e0::4"], "Online": true, "OS": "iOS"},
            "nodekey:dd": {"HostName": "no-address", "TailscaleIPs": null, "Online": true}
        },
        "MagicDNSSuffix": "tail1234.ts.net"
    }"#;

    #[test]
    fn online_peers_with_an_address_are_probed_ipv4_first() {
        assert_eq!(
            peers(STATUS).unwrap(),
            vec![
                Peer {
                    name: "galaxy-z-fold7".into(),
                    ip: "100.64.0.2".parse().unwrap()
                },
                Peer {
                    name: "ipad".into(),
                    ip: "fd7a:115c:a1e0::4".parse().unwrap()
                },
            ]
        );
    }

    #[test]
    fn a_stopped_or_logged_out_tailscale_has_no_peers() {
        let stopped = STATUS.replace(r#""Running""#, r#""Stopped""#);
        assert!(peers(&stopped).unwrap().is_empty());
        assert!(
            peers(r#"{"BackendState":"NeedsLogin","Peer":null}"#)
                .unwrap()
                .is_empty()
        );
        assert!(peers("not json").is_err());
    }

    fn framed(json: &str) -> Vec<u8> {
        opendisplay_proto::encode_frame(json.as_bytes())
    }

    #[test]
    fn a_hello_makes_a_receiver_and_anything_else_does_not() {
        let peer = Peer {
            name: "galaxy-z-fold7".into(),
            ip: "100.64.0.2".parse().unwrap(),
        };
        let bytes = framed(
            r#"{"type":"hello","pixelsWide":2176,"pixelsHigh":1812,"scale":2,"id":"FOLD-1","pv":3}"#,
        );
        // Split across reads, as TCP may deliver it.
        let mut split = std::io::Read::chain(&bytes[..3], &bytes[3..]);
        let hello = read_hello(&mut split).unwrap();
        assert_eq!(
            found(&peer, 9000, hello),
            Some(Found {
                instance: "galaxy-z-fold7".into(),
                addr: "100.64.0.2:9000".parse().unwrap(),
                id: Some("FOLD-1".into()),
                pv: 3,
            })
        );
        // Some other service on 9000.
        assert!(read_hello(&mut &b"HTTP/1.1 400 Bad Request\r\n\r\n"[..]).is_none());
        assert!(read_hello(&mut &framed(r#"{"type":"kf"}"#)[..]).is_none());
        assert!(read_hello(&mut &b""[..]).is_none());
    }
}
