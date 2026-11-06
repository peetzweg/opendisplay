//! Find receivers via Bonjour (§2.1), and over Tailscale when Bonjour finds
//! nothing (see [`crate::tailscale`]).

use std::net::SocketAddr;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use mdns_sd::{ServiceDaemon, ServiceEvent};
use opendisplay_proto::SERVICE_TYPE;
use tracing::info;

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct Found {
    /// The receiver's Bonjour name, e.g. `iMac`.
    #[serde(rename = "name")]
    pub instance: String,
    pub addr: SocketAddr,
    pub id: Option<String>,
    pub pv: u32,
}

impl Found {
    /// `--to` matching: the instance name contains `to`, or the receiver
    /// `id` equals it (both case-insensitive).
    pub fn matches(&self, to: &str) -> bool {
        self.instance.to_lowercase().contains(&to.to_lowercase())
            || self
                .id
                .as_deref()
                .is_some_and(|id| id.eq_ignore_ascii_case(to))
    }
}

/// What to check when no receiver answers (PROTOCOL §2.1: Bonjour on the LAN).
pub const NO_RECEIVER_HINT: &str = "\
Is the OpenDisplay app open and in the foreground on the device, on the same
Wi-Fi as this computer (not a guest network)? On iPhone and iPad, Settings >
Privacy & Security > Local Network must allow OpenDisplay. Bonjour does not
cross VPNs: over Tailscale or another VPN, connect with
`od-sender run --to <vpn-ip>:9000` (`tailscale ip -4 <device>` prints it).
Try `od-sender list --timeout 10`, or connect directly with
`od-sender run --to <device-ip>:9000`.";

/// Discovery found nothing.
#[derive(Debug)]
pub struct NoReceiver {
    pub to: Option<String>,
    pub timeout: Duration,
    /// Receivers that answered but did not match `to`.
    pub others: Vec<Found>,
    /// How many Tailscale peers were probed, if any were.
    pub tailscale_peers: Option<usize>,
}

impl std::fmt::Display for NoReceiver {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.to {
            Some(t) if !self.others.is_empty() => {
                writeln!(f, "no receiver matching {t:?}; on the network:")?;
                for r in &self.others {
                    writeln!(f, "  {}  ({})", r.instance, r.addr)?;
                }
                return write!(f, "connect with: od-sender connect <name>");
            }
            Some(t) => write!(
                f,
                "no receiver matching {t:?} found within {:?}",
                self.timeout
            )?,
            None => write!(f, "no receiver found within {:?}", self.timeout)?,
        }
        if let Some(n) = self.tailscale_peers {
            write!(
                f,
                ", and none of {n} online Tailscale peer{} answered on port 9000",
                if n == 1 { "" } else { "s" }
            )?;
        }
        write!(f, ".\n{NO_RECEIVER_HINT}")
    }
}

impl std::error::Error for NoReceiver {}

/// Several receivers answered and none was chosen.
#[derive(Debug)]
pub struct SeveralReceivers(pub Vec<Found>);

impl std::fmt::Display for SeveralReceivers {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        writeln!(
            f,
            "several receivers found; pick one with `od-sender connect <name>`:"
        )?;
        for r in &self.0 {
            writeln!(
                f,
                "  {}  ({}, id {})",
                r.instance,
                r.addr,
                r.id.as_deref().unwrap_or("-")
            )?;
        }
        write!(
            f,
            "(or set `to = \"<name>\"` in ~/.config/opendisplay/sender.toml)"
        )
    }
}

impl std::error::Error for SeveralReceivers {}

/// With no `--to`, keep listening this long after the first answer, so a
/// second device on the network is noticed instead of silently ignored.
const SETTLE_WITHOUT_TO: Duration = Duration::from_millis(1500);

/// Browse until `deadline` (`None`: forever), calling `on_found` for each
/// resolved receiver; it may move the deadline, or return `true` to stop.
fn browse(
    mut deadline: Option<Instant>,
    mut on_found: impl FnMut(Found, &mut Option<Instant>) -> bool,
) -> Result<()> {
    let daemon = ServiceDaemon::new().context("starting mDNS browser")?;
    let ty = format!("{SERVICE_TYPE}.local.");
    let rx = daemon.browse(&ty).context("browsing")?;
    loop {
        let wait = match deadline {
            Some(d) => {
                let left = d.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    break;
                }
                left
            }
            None => Duration::from_secs(3600),
        };
        match rx.recv_timeout(wait) {
            Ok(ServiceEvent::ServiceResolved(info)) => {
                let instance = info
                    .get_fullname()
                    .trim_end_matches(&format!(".{ty}"))
                    .to_string();
                // Prefer IPv4: link-local IPv6 needs a scope id we do not have (§6.1 addrs note).
                let ip = info
                    .get_addresses()
                    .iter()
                    .map(|a| a.to_ip_addr())
                    .min_by_key(|a| if a.is_ipv4() { 0 } else { 1 });
                let Some(ip) = ip else { continue };
                let id = info.get_property_val_str("id").map(str::to_owned);
                let pv = info
                    .get_property_val_str("pv")
                    .and_then(|p| p.parse().ok())
                    .unwrap_or(1);
                let found = Found {
                    instance,
                    addr: SocketAddr::new(ip, info.get_port()),
                    id,
                    pv,
                };
                if found.pv >= 1 && on_found(found, &mut deadline) {
                    break;
                }
            }
            Ok(_) => continue,
            // Browsing without a deadline (`--wait`): a quiet hour is fine.
            Err(_) if deadline.is_none() && !rx.is_disconnected() => continue,
            Err(_) => break,
        }
    }
    let _ = daemon.stop_browse(&ty);
    let _ = daemon.shutdown();
    Ok(())
}

/// The outcome of discovery, decided from what answered.
#[derive(Debug, PartialEq)]
pub enum Choice {
    One(Found),
    Several(Vec<Found>),
    None,
}

/// With `to`, the first match; without, the only receiver, or all of them.
pub fn choose(found: Vec<Found>, to: Option<&str>) -> Choice {
    let mut matching: Vec<Found> = match to {
        Some(t) => found.into_iter().filter(|f| f.matches(t)).take(1).collect(),
        None => found,
    };
    matching.dedup_by(|a, b| a.instance == b.instance);
    match matching.len() {
        0 => Choice::None,
        1 => Choice::One(matching.remove(0)),
        _ => Choice::Several(matching),
    }
}

/// Find the receiver to dial: the first matching `to`, or, without `to`,
/// the only one on the network (several is an error). `timeout: None`
/// browses until one appears (`run --wait`). When Bonjour finds nothing
/// within `timeout` and `tailscale` is set, the Tailscale peers are tried.
pub fn find(to: Option<&str>, timeout: Option<Duration>, tailscale: bool) -> Result<Found> {
    let mut seen: Vec<Found> = Vec::new();
    let mut others: Vec<Found> = Vec::new();
    browse(timeout.map(|t| Instant::now() + t), |f, deadline| {
        if seen.iter().chain(&others).any(|s| s.instance == f.instance) {
            return false;
        }
        if let Some(t) = to {
            if !f.matches(t) {
                info!("skipping {}", f.instance);
                others.push(f);
                return false;
            }
            seen.push(f);
            return true;
        }
        if seen.is_empty() {
            // Give other receivers a moment to answer.
            *deadline = Some(Instant::now() + SETTLE_WITHOUT_TO);
        }
        seen.push(f);
        false
    })?;
    let mut tailscale_peers = None;
    if seen.is_empty() && timeout.is_some() && tailscale {
        if let Some((found, probed)) = crate::tailscale::discover() {
            tailscale_peers = Some(probed);
            let (matching, rest) = split_tailscale(found, &others, to);
            seen = matching;
            others.extend(rest);
        }
    }
    match choose(seen, to) {
        Choice::One(f) => Ok(f),
        Choice::Several(all) => match pick_interactively(&all) {
            Some(f) => Ok(f),
            None => Err(SeveralReceivers(all).into()),
        },
        Choice::None => Err(NoReceiver {
            to: to.map(Into::into),
            timeout: timeout.unwrap_or_default(),
            others,
            tailscale_peers,
        }
        .into()),
    }
}

/// Tailscale finds split into those matching `to` (all of them without
/// `to`) and the rest, leaving out receivers Bonjour already reported
/// (same id: the same device on another address).
fn split_tailscale(
    found: Vec<Found>,
    known: &[Found],
    to: Option<&str>,
) -> (Vec<Found>, Vec<Found>) {
    found
        .into_iter()
        .filter(|f| {
            f.id.is_none()
                || !known.iter().any(|k| {
                    k.id.as_deref()
                        .is_some_and(|id| f.id.as_deref() == Some(id))
                })
        })
        .partition(|f| to.is_none_or(|t| f.matches(t)))
}

/// With a person at the terminal (stdin and stderr are terminals), ask which
/// receiver to use. Scripts, agents and the systemd unit get `None` and the
/// [`SeveralReceivers`] error instead, so nothing ever waits for input.
fn pick_interactively(all: &[Found]) -> Option<Found> {
    use std::io::{BufRead, IsTerminal, Write};
    if !std::io::stdin().is_terminal() || !std::io::stderr().is_terminal() {
        return None;
    }
    let mut err = std::io::stderr();
    let _ = writeln!(err, "Several receivers found:");
    for (i, r) in all.iter().enumerate() {
        let _ = writeln!(err, "  {}) {}  ({})", i + 1, r.instance, r.addr);
    }
    let _ = write!(err, "Connect to which one? [1-{}] ", all.len());
    let _ = err.flush();
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line).ok()?;
    pick(all, line.trim())
}

/// The receiver an answer at the [`pick_interactively`] prompt names: its
/// number, or (part of) its name.
fn pick(all: &[Found], answer: &str) -> Option<Found> {
    if answer.is_empty() {
        return None;
    }
    if let Ok(n) = answer.parse::<usize>() {
        return all.get(n.checked_sub(1)?).cloned();
    }
    match choose(all.to_vec(), Some(answer)) {
        Choice::One(f) => Some(f),
        _ => None,
    }
}

/// Every receiver that resolves within `timeout`, one entry per instance;
/// when none does and `tailscale` is set, the receivers among the Tailscale
/// peers.
pub fn list(timeout: Duration, tailscale: bool) -> Result<Vec<Found>> {
    let mut all: Vec<Found> = Vec::new();
    browse(Some(Instant::now() + timeout), |f, _| {
        if !all.iter().any(|a| a.instance == f.instance) {
            all.push(f);
        }
        false
    })?;
    if all.is_empty() && tailscale {
        if let Some((found, _)) = crate::tailscale::discover() {
            all = found;
        }
    }
    all.sort_by(|a, b| a.instance.cmp(&b.instance));
    Ok(all)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(name: &str, id: &str) -> Found {
        Found {
            instance: name.into(),
            addr: "192.168.1.20:9000".parse().unwrap(),
            id: Some(id.into()),
            pv: 3,
        }
    }

    #[test]
    fn without_to_one_receiver_is_used_and_several_are_refused() {
        assert_eq!(
            choose(vec![r("iPhone", "A")], None),
            Choice::One(r("iPhone", "A"))
        );
        assert!(matches!(
            choose(vec![r("iPhone", "A"), r("iMac", "B")], None),
            Choice::Several(v) if v.len() == 2
        ));
        assert_eq!(choose(vec![], None), Choice::None);
    }

    #[test]
    fn to_picks_by_name_or_id() {
        let all = vec![r("iPhone", "A1"), r("iMac", "B2")];
        assert_eq!(
            choose(all.clone(), Some("iMac")),
            Choice::One(r("iMac", "B2"))
        );
        assert_eq!(
            choose(all.clone(), Some("a1")),
            Choice::One(r("iPhone", "A1"))
        );
        assert_eq!(choose(all, Some("Pixel")), Choice::None);
    }

    #[test]
    fn names_match_case_insensitively_and_picks_take_numbers_or_names() {
        let all = vec![r("iMac", "B2"), r("Pixel 10a", "C3")];
        assert_eq!(
            choose(all.clone(), Some("imac")),
            Choice::One(r("iMac", "B2"))
        );
        assert_eq!(pick(&all, "2"), Some(r("Pixel 10a", "C3")));
        assert_eq!(pick(&all, "pixel"), Some(r("Pixel 10a", "C3")));
        assert_eq!(pick(&all, "3"), None);
        assert_eq!(pick(&all, "0"), None);
        assert_eq!(pick(&all, ""), None);
    }

    #[test]
    fn tailscale_finds_go_through_to_and_skip_known_devices() {
        let at = |name: &str, id: &str, addr: &str| Found {
            addr: addr.parse().unwrap(),
            ..r(name, id)
        };
        let found = vec![
            at("galaxy-z-fold7", "FOLD", "100.64.0.2:9000"),
            at("ipad", "IPAD", "100.64.0.4:9000"),
            at("imac-ts", "B2", "100.64.0.5:9000"),
        ];
        // Bonjour saw the iMac (id B2) but it did not match `to`.
        let known = vec![r("iMac", "B2")];
        let (matching, rest) = split_tailscale(found.clone(), &known, Some("fold"));
        assert_eq!(matching, vec![found[0].clone()]);
        assert_eq!(rest, vec![found[1].clone()]);
        let (matching, rest) = split_tailscale(found.clone(), &[], None);
        assert_eq!(matching.len(), 3);
        assert!(rest.is_empty());
        assert_eq!(
            choose(matching, None),
            Choice::Several(found.clone()),
            "several on the tailnet are refused like several on the LAN"
        );
    }

    #[test]
    fn an_unknown_name_lists_what_answered() {
        let e = NoReceiver {
            to: Some("imc".into()),
            timeout: Duration::from_secs(10),
            others: vec![r("iMac", "B2")],
            tailscale_peers: None,
        }
        .to_string();
        assert!(e.contains("on the network") && e.contains("iMac"), "{e}");
    }

    #[test]
    fn errors_carry_the_hints() {
        let e = NoReceiver {
            to: None,
            timeout: Duration::from_secs(10),
            others: Vec::new(),
            tailscale_peers: None,
        }
        .to_string();
        assert!(
            e.contains("Local Network")
                && e.contains("--to <device-ip>:9000")
                && e.contains("Tailscale")
                && e.contains("--to <vpn-ip>:9000"),
            "{e}"
        );
        assert!(!e.contains("peers"), "{e}");
        let e = NoReceiver {
            to: None,
            timeout: Duration::from_secs(10),
            others: Vec::new(),
            tailscale_peers: Some(3),
        }
        .to_string();
        assert!(
            e.starts_with(
                "no receiver found within 10s, and none of 3 online Tailscale peers answered"
            ),
            "{e}"
        );
        let e = SeveralReceivers(vec![r("iPhone", "A"), r("iMac", "B")]).to_string();
        assert!(
            e.contains("od-sender connect <name>") && e.contains("iMac"),
            "{e}"
        );
    }
}
