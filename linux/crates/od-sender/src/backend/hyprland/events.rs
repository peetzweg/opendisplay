//! Hyprland's event socket (`$XDG_RUNTIME_DIR/hypr/<sig>/.socket2.sock`):
//! one `EVENT>>DATA` line per event. The sender needs `configreloaded`: a
//! reload (`hyprctl reload`, Omarchy's theme switch) re-runs the config,
//! drops the runtime `hl.monitor` rules the sender set, and re-applies the
//! config's own rules (often a catch-all `preferred`/`auto`) to our output.

use std::io::{BufRead, BufReader, ErrorKind};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tracing::debug;

/// Whether an event line says the config was reloaded.
pub fn is_reload(line: &str) -> bool {
    line.trim_end()
        .split_once(">>")
        .map_or(line.trim_end(), |(e, _)| e)
        == "configreloaded"
}

/// Watches for config reloads on its own thread; dropped with the output.
pub struct ReloadWatcher {
    stop: Arc<AtomicBool>,
    last: Arc<Mutex<Option<Instant>>>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl ReloadWatcher {
    pub fn spawn(socket2: PathBuf) -> std::io::Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let last = Arc::new(Mutex::new(None));
        let (t_stop, t_last) = (stop.clone(), last.clone());
        let handle = std::thread::Builder::new()
            .name("hypr-events".into())
            .spawn(move || watch(&socket2, &t_stop, &t_last))?;
        Ok(Self {
            stop,
            last,
            handle: Some(handle),
        })
    }

    /// `true` once a reload happened at least `settle` ago (a reload
    /// re-applies monitor rules over several frames; acting too early
    /// races it). Clears the mark.
    pub fn take_settled(&self, settle: Duration) -> bool {
        let mut last = self.last.lock().unwrap_or_else(|e| e.into_inner());
        match *last {
            Some(t) if t.elapsed() >= settle => {
                *last = None;
                true
            }
            _ => false,
        }
    }
}

impl Drop for ReloadWatcher {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

fn watch(socket2: &PathBuf, stop: &AtomicBool, last: &Mutex<Option<Instant>>) {
    while !stop.load(Ordering::Relaxed) {
        let stream = match UnixStream::connect(socket2) {
            Ok(s) => s,
            Err(e) => {
                debug!("hyprland events {}: {e}; retrying", socket2.display());
                std::thread::sleep(Duration::from_secs(1));
                continue;
            }
        };
        // A bounded read so `stop` is noticed.
        let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        while !stop.load(Ordering::Relaxed) {
            match reader.read_line(&mut line) {
                Ok(0) => break, // Hyprland went away: reconnect
                Ok(_) => {
                    if line.ends_with('\n') {
                        if is_reload(&line) {
                            debug!("hyprland event: configreloaded");
                            *last.lock().unwrap_or_else(|e| e.into_inner()) = Some(Instant::now());
                        }
                        line.clear();
                    }
                }
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
                Err(e) => {
                    debug!("hyprland events: {e}");
                    break;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reload_lines_are_recognised() {
        assert!(is_reload("configreloaded>>\n"));
        assert!(is_reload("configreloaded>>"));
        assert!(is_reload("configreloaded"));
        assert!(!is_reload("monitoradded>>od-3f31ed\n"));
        assert!(!is_reload("activewindow>>foot,configreloaded\n"));
    }

    #[test]
    fn a_reload_is_reported_once_after_it_settles() {
        let w = ReloadWatcher {
            stop: Arc::new(AtomicBool::new(true)),
            last: Arc::new(Mutex::new(Some(Instant::now()))),
            handle: None,
        };
        assert!(!w.take_settled(Duration::from_secs(60)), "not settled yet");
        assert!(w.take_settled(Duration::ZERO));
        assert!(!w.take_settled(Duration::ZERO), "reported once");
    }
}
