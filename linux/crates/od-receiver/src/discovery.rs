//! Bonjour advertisement (§2.1) with a pure-Rust mDNS responder, so neither
//! Omarchy nor a kiosk needs `avahi-daemon` running.

use std::collections::HashMap;

use anyhow::{Context, Result};
use mdns_sd::{ServiceDaemon, ServiceInfo};
use opendisplay_proto::{SERVICE_TYPE, version};
use tracing::info;

pub struct Advertisement {
    daemon: ServiceDaemon,
    fullname: String,
}

impl Advertisement {
    /// `instance` is the user-visible, display-only name; `id` MUST equal `hello.id`.
    pub fn start(instance: &str, host: &str, port: u16, id: &str) -> Result<Advertisement> {
        let daemon = ServiceDaemon::new().context("starting mDNS responder")?;
        let ty = format!("{SERVICE_TYPE}.local.");
        let mut txt = HashMap::new();
        txt.insert("id".to_string(), id.to_string());
        txt.insert("pv".to_string(), version::PV.to_string());
        let hostname = if host.ends_with(".local.") {
            host.to_string()
        } else {
            format!("{host}.local.")
        };
        let info = ServiceInfo::new(&ty, instance, &hostname, "", port, txt)
            .context("building service info")?
            .enable_addr_auto();
        let fullname = info.get_fullname().to_string();
        daemon.register(info).context("registering service")?;
        info!(
            "advertising {fullname} on port {port} (id {id}, pv {})",
            version::PV
        );
        Ok(Advertisement { daemon, fullname })
    }

    pub fn stop(self) {
        if let Ok(rx) = self.daemon.unregister(&self.fullname) {
            let _ = rx.recv_timeout(std::time::Duration::from_secs(1));
        }
        let _ = self.daemon.shutdown();
    }
}
