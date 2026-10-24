//! Power events the receiver tells the sender about (§6.1 `sleeping`).
//! The receiver loop only sees [`PowerEvent`]s on a channel; the logind
//! watcher below feeds it in the binary, tests feed it directly, so no test
//! touches the system bus.

/// The machine is about to sleep: say `sleeping` and close, the sender
/// redials after wake.
#[derive(Debug)]
pub enum PowerEvent {
    Sleeping {
        /// Dropped (or sent) once `sleeping` went out, which lets the
        /// watcher release its delay lock and the machine suspend.
        done: Option<std::sync::mpsc::Sender<()>>,
    },
}

/// Watch logind's `PrepareForSleep` on the system bus. Holds a `delay`
/// sleep inhibitor so `sleeping` reaches the sender before the suspend, and
/// re-takes it after every wake. Runs on its own thread; logs and stops if
/// there is no system bus or logind.
#[cfg(feature = "logind")]
pub fn watch_logind(tx: tokio::sync::mpsc::UnboundedSender<PowerEvent>) {
    use std::time::Duration;
    use tracing::{debug, info, warn};

    let run = move || -> zbus::Result<()> {
        let conn = zbus::blocking::Connection::system()?;
        let manager = zbus::blocking::Proxy::new(
            &conn,
            "org.freedesktop.login1",
            "/org/freedesktop/login1",
            "org.freedesktop.login1.Manager",
        )?;
        let inhibit = || -> zbus::Result<zbus::zvariant::OwnedFd> {
            manager.call(
                "Inhibit",
                &(
                    "sleep",
                    "OpenDisplay Receiver",
                    "Tell the sender the display is going to sleep",
                    "delay",
                ),
            )
        };
        let mut lock = Some(inhibit()?);
        info!("watching logind for sleep");
        for msg in manager.receive_signal("PrepareForSleep")? {
            let going: bool = msg.body().deserialize()?;
            if going {
                let (done_tx, done_rx) = std::sync::mpsc::channel();
                if tx
                    .send(PowerEvent::Sleeping {
                        done: Some(done_tx),
                    })
                    .is_err()
                {
                    break;
                }
                // Wait for `sleeping` to go out, but never hold the suspend
                // up for long (logind's InhibitDelayMaxSec is 5 s).
                let _ = done_rx.recv_timeout(Duration::from_millis(1500));
                debug!("releasing the sleep delay lock");
                lock = None;
            } else if lock.is_none() {
                lock = Some(inhibit()?);
            }
        }
        drop(lock);
        Ok(())
    };
    let spawned = std::thread::Builder::new()
        .name("logind".into())
        .spawn(move || {
            if let Err(e) = run() {
                warn!("no sleep notifications for the sender (logind: {e})");
            }
        });
    if let Err(e) = spawned {
        warn!("logind watcher: {e}");
    }
}
