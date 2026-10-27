//! Threads whose owner waits for them on drop, but not forever: a stalled
//! compositor or D-Bus peer must not turn Ctrl+C into a hang.

use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use tracing::warn;

/// How long an owner waits for a worker to finish its cleanup on drop.
pub const DROP_JOIN: Duration = Duration::from_millis(500);

/// A spawned thread that signals when it is done.
pub struct BoundedThread {
    name: String,
    done: mpsc::Receiver<()>,
    handle: Option<JoinHandle<()>>,
}

impl BoundedThread {
    pub fn spawn(name: &str, f: impl FnOnce() + Send + 'static) -> std::io::Result<Self> {
        let (done_tx, done) = mpsc::channel::<()>();
        let handle = std::thread::Builder::new()
            .name(name.into())
            .spawn(move || {
                // Dropped on return and on unwind alike: `done` disconnects.
                let _done = done_tx;
                f();
            })?;
        Ok(Self {
            name: name.into(),
            done,
            handle: Some(handle),
        })
    }

    /// Wait until `deadline` for the thread to finish; join it if it did.
    /// `false` leaves it running detached (and says so).
    pub fn join_until(&mut self, deadline: Instant) -> bool {
        let Some(handle) = self.handle.take() else {
            return true;
        };
        let left = deadline.saturating_duration_since(Instant::now());
        match self.done.recv_timeout(left) {
            Err(mpsc::RecvTimeoutError::Timeout) => {
                warn!(
                    "{} thread did not finish within {left:?}; leaving it",
                    self.name
                );
                false
            }
            _ => {
                let _ = handle.join();
                true
            }
        }
    }

    pub fn join_within(&mut self, within: Duration) -> bool {
        self.join_until(Instant::now() + within)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_finished_thread_is_joined() {
        let mut t = BoundedThread::spawn("t-ok", || {}).unwrap();
        assert!(t.join_within(Duration::from_secs(5)));
        assert!(t.join_within(Duration::ZERO), "idempotent");
    }

    #[test]
    fn a_stuck_thread_is_left_after_the_bound() {
        let (tx, rx) = mpsc::channel::<()>();
        let mut t = BoundedThread::spawn("t-stuck", move || {
            let _ = rx.recv();
        })
        .unwrap();
        let began = Instant::now();
        assert!(!t.join_within(Duration::from_millis(50)));
        assert!(began.elapsed() < Duration::from_secs(2));
        drop(tx);
    }

    #[test]
    fn a_panicking_thread_counts_as_done() {
        let mut t = BoundedThread::spawn("t-panic", || panic!("boom")).unwrap();
        assert!(t.join_within(Duration::from_secs(5)));
    }
}
