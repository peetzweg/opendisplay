//! A one-slot channel where the newest value wins: `send` replaces a value
//! the receiver has not taken yet. Capture feeds the encoder through it, so
//! a busy encoder always starts on the latest picture instead of one that
//! waited a whole encode for it (`sync_channel(1)` + `try_send` keeps the
//! oldest and drops the newest).

use std::sync::mpsc::RecvTimeoutError;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

struct State<T> {
    value: Option<T>,
    sender_alive: bool,
}

struct Shared<T> {
    state: Mutex<State<T>>,
    ready: Condvar,
}

pub struct Sender<T>(Arc<Shared<T>>);

pub struct Receiver<T>(Arc<Shared<T>>);

pub fn channel<T>() -> (Sender<T>, Receiver<T>) {
    let shared = Arc::new(Shared {
        state: Mutex::new(State {
            value: None,
            sender_alive: true,
        }),
        ready: Condvar::new(),
    });
    (Sender(shared.clone()), Receiver(shared))
}

impl<T> Sender<T> {
    /// Store `value`, replacing one not yet received. Returns true when it
    /// replaced one.
    pub fn send(&self, value: T) -> bool {
        let mut s = self.0.state.lock().unwrap_or_else(|e| e.into_inner());
        let replaced = s.value.replace(value).is_some();
        drop(s);
        self.0.ready.notify_one();
        replaced
    }
}

impl<T> Drop for Sender<T> {
    fn drop(&mut self) {
        let mut s = self.0.state.lock().unwrap_or_else(|e| e.into_inner());
        s.sender_alive = false;
        drop(s);
        self.0.ready.notify_one();
    }
}

impl<T> Receiver<T> {
    /// Like [`std::sync::mpsc::Receiver::recv_timeout`]: a value stored
    /// before the sender went away is still delivered.
    pub fn recv_timeout(&self, timeout: Duration) -> Result<T, RecvTimeoutError> {
        let deadline = Instant::now() + timeout;
        let mut s = self.0.state.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            if let Some(v) = s.value.take() {
                return Ok(v);
            }
            if !s.sender_alive {
                return Err(RecvTimeoutError::Disconnected);
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(RecvTimeoutError::Timeout);
            }
            s = self
                .0
                .ready
                .wait_timeout(s, left)
                .unwrap_or_else(|e| e.into_inner())
                .0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newest_value_wins() {
        let (tx, rx) = channel();
        assert!(!tx.send(1));
        assert!(tx.send(2));
        assert!(tx.send(3));
        assert_eq!(rx.recv_timeout(Duration::ZERO), Ok(3));
        assert_eq!(
            rx.recv_timeout(Duration::from_millis(5)),
            Err(RecvTimeoutError::Timeout)
        );
    }

    #[test]
    fn disconnect_after_draining() {
        let (tx, rx) = channel();
        tx.send(7);
        drop(tx);
        assert_eq!(rx.recv_timeout(Duration::ZERO), Ok(7));
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(5)),
            Err(RecvTimeoutError::Disconnected)
        );
    }

    #[test]
    fn wakes_a_waiting_receiver() {
        let (tx, rx) = channel();
        let t = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            tx.send("frame");
        });
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)), Ok("frame"));
        t.join().unwrap();
    }
}
