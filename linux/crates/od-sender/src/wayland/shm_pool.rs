//! Capture buffers lent to the encoder without copying: each `wl_shm`
//! buffer is mapped once, a ready frame goes out as a [`Lease`] on its
//! buffer, and dropping the lease hands the buffer back for the next frame.
//! The compositor never writes into a buffer that is lent out, because the
//! capture loop only attaches buffers it took from the free list.

use std::fs::File;
use std::os::fd::AsRawFd;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use anyhow::{Result, bail};

use crate::backend::PixelLease;

/// A read-only shared mapping of a file, unmapped when the last user goes.
pub struct Mapping {
    ptr: *const u8,
    len: usize,
}

// SAFETY: the mapping is read-only for us and stays valid until drop; the
// bytes are only read while the buffer is lent out, when nothing writes them.
unsafe impl Send for Mapping {}
unsafe impl Sync for Mapping {}

const PROT_READ: i32 = 1;
const MAP_SHARED: i32 = 1;

unsafe extern "C" {
    fn mmap(addr: *mut u8, len: usize, prot: i32, flags: i32, fd: i32, off: i64) -> *mut u8;
    fn munmap(addr: *mut u8, len: usize) -> i32;
}

impl Mapping {
    pub fn new(file: &File, len: usize) -> Result<Self> {
        // SAFETY: maps `len` bytes of a file we own; checked for MAP_FAILED.
        let ptr = unsafe {
            mmap(
                std::ptr::null_mut(),
                len,
                PROT_READ,
                MAP_SHARED,
                file.as_raw_fd(),
                0,
            )
        };
        if ptr as isize == -1 || ptr.is_null() {
            bail!("mmap of a {len}-byte capture buffer failed");
        }
        Ok(Self { ptr, len })
    }

    fn bytes(&self) -> &[u8] {
        // SAFETY: `ptr` maps `len` readable bytes for our lifetime.
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }
}

impl Drop for Mapping {
    fn drop(&mut self) {
        // SAFETY: unmaps exactly what `new` mapped, once.
        unsafe { munmap(self.ptr as *mut u8, self.len) };
    }
}

#[derive(Default)]
struct State {
    free: Vec<usize>,
    /// Bumped when the buffers are reallocated; leases of an older
    /// generation are not returned to the free list.
    generation: u64,
}

#[derive(Default)]
struct Shared {
    state: Mutex<State>,
    returned: Condvar,
}

/// Free-list bookkeeping for the capture's buffers (indices into the
/// capture loop's own buffer list).
#[derive(Clone, Default)]
pub struct Recycler(Arc<Shared>);

impl Recycler {
    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.0.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// A buffer that is neither lent out nor attached.
    pub fn take(&self) -> Option<usize> {
        self.state().free.pop()
    }

    /// Wait up to `timeout` for a lease to come back; true if one did.
    pub fn wait(&self, timeout: Duration) -> bool {
        let s = self.state();
        if !s.free.is_empty() {
            return true;
        }
        let (s, _) = self
            .0
            .returned
            .wait_timeout_while(s, timeout, |s| s.free.is_empty())
            .unwrap_or_else(|e| e.into_inner());
        !s.free.is_empty()
    }

    /// Return a buffer that was attached but never lent out (failed frame).
    pub fn release(&self, index: usize) {
        self.state().free.push(index);
        self.0.returned.notify_one();
    }

    /// Forget every buffer (they are being reallocated).
    pub fn reset(&self) {
        let mut s = self.state();
        s.free.clear();
        s.generation += 1;
    }

    /// Lend buffer `index` (holding `len` bytes of `map`) out.
    pub fn lease(&self, index: usize, map: Arc<Mapping>, len: usize) -> Lease {
        assert!(len <= map.len);
        Lease {
            recycler: self.clone(),
            index,
            generation: self.state().generation,
            map,
            len,
        }
    }
}

pub struct Lease {
    recycler: Recycler,
    index: usize,
    generation: u64,
    map: Arc<Mapping>,
    len: usize,
}

impl PixelLease for Lease {
    fn bytes(&self) -> &[u8] {
        &self.map.bytes()[..self.len]
    }
}

impl std::ops::Deref for Lease {
    type Target = [u8];

    fn deref(&self) -> &[u8] {
        self.bytes()
    }
}

impl Drop for Lease {
    fn drop(&mut self) {
        let mut s = self.recycler.state();
        if s.generation == self.generation {
            s.free.push(self.index);
            drop(s);
            self.recycler.0.returned.notify_one();
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use super::*;

    fn mapping(bytes: &[u8]) -> Arc<Mapping> {
        let path = std::env::temp_dir().join(format!(
            "od-shm-pool-test-{}-{}",
            std::process::id(),
            bytes.len()
        ));
        let mut f = File::options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)
            .unwrap();
        f.write_all(bytes).unwrap();
        let _ = std::fs::remove_file(&path);
        Arc::new(Mapping::new(&f, bytes.len()).unwrap())
    }

    #[test]
    fn a_dropped_lease_frees_its_buffer() {
        let r = Recycler::default();
        let map = mapping(b"pixels!!");
        assert_eq!(r.take(), None);
        let lease = r.lease(1, map.clone(), 6);
        assert_eq!(&*lease, b"pixels");
        assert_eq!(r.take(), None);
        drop(lease);
        assert_eq!(r.take(), Some(1));
        assert_eq!(r.take(), None);
    }

    #[test]
    fn leases_from_before_a_reset_are_not_returned() {
        let r = Recycler::default();
        let map = mapping(b"abcd");
        let old = r.lease(0, map.clone(), 4);
        r.reset();
        // The mapping outlives the reset while the lease holds it.
        assert_eq!(&*old, b"abcd");
        drop(old);
        assert_eq!(r.take(), None);
        drop(r.lease(0, map, 4));
        assert_eq!(r.take(), Some(0));
    }

    #[test]
    fn wait_wakes_when_a_lease_returns() {
        let r = Recycler::default();
        let lease = r.lease(2, mapping(b"xy"), 2);
        assert!(!r.wait(Duration::from_millis(5)));
        let t = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            drop(lease);
        });
        assert!(r.wait(Duration::from_secs(5)));
        assert_eq!(r.take(), Some(2));
        t.join().unwrap();
    }
}
