//! A KWin virtual output: `zkde_screencast_unstable_v1.stream_virtual_output`
//! makes the output and a PipeWire stream of it in one go. The output lives
//! exactly as long as the Wayland stream object, so a thread owns the
//! connection and closes the stream on drop (or KWin drops it when the
//! process dies: nothing is ever left behind).

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use tracing::{debug, warn};
use wayland_client::protocol::wl_registry;
use wayland_client::{Connection, Dispatch, QueueHandle};

use super::protocols::screencast::{
    zkde_screencast_stream_unstable_v1 as zstream, zkde_screencast_unstable_v1 as zmgr,
};
use crate::wayland::dispatch_with_timeout;

/// What KWin draws for the pointer in the stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pointer {
    Hidden,
    Embedded,
}

impl Pointer {
    fn raw(self) -> u32 {
        match self {
            Pointer::Hidden => zmgr::Pointer::Hidden as u32,
            Pointer::Embedded => zmgr::Pointer::Embedded as u32,
        }
    }
}

/// Where the PipeWire side of the stream lives.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Node {
    pub id: u32,
    /// `object.serial` (zkde v6), preferred over the id, which is reused.
    pub serial: Option<u64>,
}

pub struct VirtualOutputStream {
    pub node: Node,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

/// What the request asks for; `width`/`height` are the mode in pixels (what
/// KWin does with them, whatever the protocol text says).
#[derive(Debug, Clone)]
pub struct Request {
    pub name: String,
    pub description: String,
    pub width: i32,
    pub height: i32,
    pub scale: f64,
    pub pointer: Pointer,
}

impl VirtualOutputStream {
    pub fn open(req: Request) -> Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let (tx, rx) = mpsc::channel::<Result<Node>>();
        let s = stop.clone();
        let thread = std::thread::Builder::new()
            .name("kde-screencast".into())
            .spawn(move || {
                if let Err(e) = run(req, &s, &tx) {
                    let _ = tx.send(Err(e));
                }
            })?;
        let node = rx
            .recv_timeout(Duration::from_secs(10))
            .map_err(|_| anyhow!("KWin did not answer the virtual output request within 10 s"))
            .and_then(|r| r);
        let mut this = Self {
            node: Node {
                id: 0,
                serial: None,
            },
            stop,
            thread: Some(thread),
        };
        this.node = node?;
        Ok(this)
    }
}

impl Drop for VirtualOutputStream {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

#[derive(Default)]
struct State {
    manager: Option<(zmgr::ZkdeScreencastUnstableV1, u32)>,
    serial: Option<u64>,
    node: Option<u32>,
    failed: Option<String>,
    closed: bool,
}

fn run(req: Request, stop: &AtomicBool, ready: &mpsc::Sender<Result<Node>>) -> Result<()> {
    let conn = Connection::connect_to_env().context("connecting to Wayland")?;
    let mut queue = conn.new_event_queue::<State>();
    let qh = queue.handle();
    conn.display().get_registry(&qh, ());
    let mut st = State::default();
    queue.roundtrip(&mut st)?;
    let (manager, version) = st.manager.clone().context(
        "KWin does not offer zkde_screencast_unstable_v1 to od-sender (KWin < 6.8 lists it only for programs named in a .desktop file's X-KDE-Wayland-Interfaces)",
    )?;
    if version < 2 {
        bail!("zkde_screencast_unstable_v1 v{version} cannot create virtual outputs (needs v2)");
    }
    let stream = if version >= 4 {
        manager.stream_virtual_output_with_description(
            req.name.clone(),
            req.description.clone(),
            req.width,
            req.height,
            req.scale,
            req.pointer.raw(),
            &qh,
            (),
        )
    } else {
        manager.stream_virtual_output(
            req.name.clone(),
            req.width,
            req.height,
            req.scale,
            req.pointer.raw(),
            &qh,
            (),
        )
    };
    let deadline = Instant::now() + Duration::from_secs(10);
    while st.node.is_none() && st.failed.is_none() && !st.closed {
        if Instant::now() > deadline {
            bail!("no PipeWire node for the virtual output within 10 s");
        }
        dispatch_with_timeout(&conn, &mut queue, &mut st, Duration::from_millis(250))?;
    }
    if let Some(e) = st.failed.take() {
        stream.close();
        let _ = conn.flush();
        bail!("KWin refused the virtual output: {e}");
    }
    let Some(id) = st.node else {
        bail!("KWin closed the virtual output stream before it started");
    };
    let _ = ready.send(Ok(Node {
        id,
        serial: st.serial,
    }));
    while !stop.load(Ordering::Relaxed) && !st.closed {
        dispatch_with_timeout(&conn, &mut queue, &mut st, Duration::from_millis(100))?;
    }
    if st.closed {
        // Capture notices through its PipeWire stream ending.
        warn!("KWin closed the virtual output {}", req.name);
    }
    stream.close();
    manager.destroy();
    let _ = queue.roundtrip(&mut st);
    debug!("virtual output {} released", req.name);
    Ok(())
}

impl Dispatch<wl_registry::WlRegistry, ()> for State {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global {
            name,
            interface,
            version,
        } = event
        {
            if interface == "zkde_screencast_unstable_v1" {
                let v = version.min(6);
                state.manager = Some((registry.bind(name, v, qh, ()), v));
            }
        }
    }
}

impl Dispatch<zmgr::ZkdeScreencastUnstableV1, ()> for State {
    fn event(
        _: &mut Self,
        _: &zmgr::ZkdeScreencastUnstableV1,
        _: zmgr::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<zstream::ZkdeScreencastStreamUnstableV1, ()> for State {
    fn event(
        state: &mut Self,
        _: &zstream::ZkdeScreencastStreamUnstableV1,
        event: zstream::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            zstream::Event::Serial {
                object_serial_hi,
                object_serial_low,
            } => state.serial = Some(((object_serial_hi as u64) << 32) | object_serial_low as u64),
            zstream::Event::Created { node } => state.node = Some(node),
            zstream::Event::Failed { error } => state.failed = Some(error),
            zstream::Event::Closed => state.closed = true,
        }
    }
}
