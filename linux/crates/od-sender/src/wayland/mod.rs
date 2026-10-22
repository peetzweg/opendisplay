//! Wayland-protocol pieces shared by every backend that is a Wayland
//! compositor speaking the common protocols.

pub mod capture;
pub mod cursor;
pub mod display;
pub mod input;
pub mod registry;
pub mod screencopy;
pub mod shm_pool;

use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use wayland_client::Connection;

/// `blocking_dispatch` with an upper bound, so a capture of a static output
/// (which never produces a frame) still notices the stop flag.
pub fn dispatch_with_timeout<S>(
    conn: &Connection,
    queue: &mut wayland_client::EventQueue<S>,
    st: &mut S,
    timeout: Duration,
) -> Result<()> {
    use std::os::fd::AsRawFd;
    queue.dispatch_pending(st)?;
    conn.flush()?;
    let Some(guard) = conn.prepare_read() else {
        queue.dispatch_pending(st)?;
        return Ok(());
    };
    let fd = guard.connection_fd().as_raw_fd();
    let mut pfd = libc_pollfd(fd);
    // SAFETY: pollfd points at one valid struct for the duration of the call.
    let r = unsafe { libc_poll(&mut pfd, 1, timeout.as_millis() as i32) };
    if r > 0 {
        // A dead connection (e.g. after a protocol error) must end the
        // caller's loop instead of spinning on it.
        match guard.read() {
            Ok(_) => {}
            Err(wayland_client::backend::WaylandError::Io(e))
                if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(e) => return Err(e).context("reading from the compositor"),
        }
        queue.dispatch_pending(st)?;
    }
    Ok(())
}

/// Dispatch until `done` holds, failing at `deadline` instead of waiting on
/// a stalled compositor forever. `what` names the awaited event in the error.
pub fn dispatch_until<S>(
    conn: &Connection,
    queue: &mut wayland_client::EventQueue<S>,
    st: &mut S,
    deadline: Instant,
    what: &str,
    done: impl Fn(&S) -> bool,
) -> Result<()> {
    while !done(st) {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            bail!("the compositor did not send {what} in time");
        }
        dispatch_with_timeout(conn, queue, st, left.min(Duration::from_millis(100)))?;
    }
    Ok(())
}

#[repr(C)]
struct PollFd {
    fd: i32,
    events: i16,
    revents: i16,
}

fn libc_pollfd(fd: i32) -> PollFd {
    PollFd {
        fd,
        events: 0x001, /* POLLIN */
        revents: 0,
    }
}

unsafe extern "C" {
    #[link_name = "poll"]
    fn libc_poll(fds: *mut PollFd, nfds: u64, timeout: i32) -> i32;
}

#[cfg(test)]
mod tests {
    use std::os::unix::net::UnixStream;

    use super::*;

    #[test]
    fn dispatch_until_gives_up_on_a_silent_compositor() {
        // A peer that accepts the connection and never says anything.
        let (ours, _silent) = UnixStream::pair().unwrap();
        let conn = Connection::from_socket(ours).unwrap();
        let mut queue = conn.new_event_queue::<()>();
        let began = Instant::now();
        let err = dispatch_until(
            &conn,
            &mut queue,
            &mut (),
            Instant::now() + Duration::from_millis(200),
            "anything",
            |_| false,
        )
        .unwrap_err();
        assert!(err.to_string().contains("anything"), "{err:#}");
        let took = began.elapsed();
        assert!(
            took >= Duration::from_millis(200) && took < Duration::from_secs(2),
            "{took:?}"
        );
    }
}
