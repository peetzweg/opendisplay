//! Find receivers via Bonjour (§2.1).

use std::net::SocketAddr;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use mdns_sd::{ServiceDaemon, ServiceEvent};
use opendisplay_proto::SERVICE_TYPE;
use tracing::info;

#[derive(Debug, Clone)]
pub struct Found {
    pub instance: String,
    pub addr: SocketAddr,
    pub id: Option<String>,
    pub pv: u32,
}

/// Browse until a receiver (optionally one whose instance name contains
/// `name`) resolves, or `timeout` passes.
pub fn find(name: Option<&str>, timeout: Duration) -> Result<Found> {
    let daemon = ServiceDaemon::new().context("starting mDNS browser")?;
    let ty = format!("{SERVICE_TYPE}.local.");
    let rx = daemon.browse(&ty).context("browsing")?;
    let deadline = Instant::now() + timeout;
    let result = loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break Err(anyhow::anyhow!("no receiver found within {timeout:?}"));
        }
        match rx.recv_timeout(left) {
            Ok(ServiceEvent::ServiceResolved(info)) => {
                let instance = info
                    .get_fullname()
                    .trim_end_matches(&format!(".{ty}"))
                    .to_string();
                if name.is_some_and(|n| !instance.contains(n)) {
                    info!("skipping {instance}");
                    continue;
                }
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
                break Ok(Found {
                    instance,
                    addr: SocketAddr::new(ip, info.get_port()),
                    id,
                    pv,
                });
            }
            Ok(_) => continue,
            Err(_) => break Err(anyhow::anyhow!("no receiver found within {timeout:?}")),
        }
    };
    let _ = daemon.stop_browse(&ty);
    let _ = daemon.shutdown();
    let found = result?;
    if found.pv < 1 {
        bail!("nonsense pv");
    }
    Ok(found)
}
