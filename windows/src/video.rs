//! Video path (PROTOCOL.md §5): network thread -> bounded hand-off -> decode thread.

use crate::clock::now_ms;
use crate::control::{self, Hello, Incoming, Outgoing, PencilPhase, SenderHealth, TouchPhase};
use crate::cursor::{Cursor, Datagram, Sprite};
use crate::h264::{scan, split_prefix, telemetry};
use crate::mf::{Decoder, Frame, Gpu};
use crate::monitor;
use crate::net::{Handler, Session};
use crate::present::Presenter;
use crate::window::{self, Event, Ui};
use std::fmt::Write;
use std::io;
use std::net::UdpSocket;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{
    Receiver, RecvTimeoutError, Sender, SyncSender, TrySendError, channel, sync_channel,
};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// Request a keyframe if no IDR arrived this long after connecting.
const KF_PROMPT: Duration = Duration::from_millis(500);
/// Repeat the request this often while still waiting.
const KF_RETRY: Duration = Duration::from_secs(1);
/// Frames that may wait for the decoder. Every P-frame is a reference, so a frame cannot be
/// skipped without losing the picture until the next IDR. A small queue absorbs a one-off decode
/// stall; overflowing it means we are really behind: drop everything, request an IDR.
const QUEUE: usize = 3;
/// Input messages waiting for the socket; beyond this the connection is stalled and input is dropped.
const INPUT_QUEUE: usize = 256;
const STATS_EVERY: Duration = Duration::from_secs(5);
/// Longest wait for the swap chain to take a frame before checking for new work again. Waiting on
/// the frame-latency handle wakes as soon as it is free; a sleep would round up to the 15.6 ms tick.
const PRESENT_WAIT: u32 = 4;

/// Decides which frames are decodable after connect, loss, or error (§5.3).
pub struct Resync {
    waiting: bool,
    since: Instant,
    last_kf: Option<Instant>,
}

impl Resync {
    pub fn new(now: Instant) -> Self {
        Self {
            waiting: true,
            since: now,
            last_kf: None,
        }
    }

    /// Returns (decode this frame, send kf now).
    pub fn on_frame(&mut self, idr: bool, now: Instant) -> (bool, bool) {
        if idr {
            self.waiting = false;
            return (true, false);
        }
        if !self.waiting {
            return (true, false);
        }
        (false, self.request(now, true))
    }

    /// Periodic check while no frames arrive. Returns true if kf should be sent.
    pub fn tick(&mut self, now: Instant) -> bool {
        self.request(now, false)
    }

    /// The reference chain is broken: wait for an IDR and request one right away.
    pub fn lost(&mut self, now: Instant) -> bool {
        *self = Self::new(now);
        self.request(now, true)
    }

    fn request(&mut self, now: Instant, immediate: bool) -> bool {
        let due = self.waiting
            && match self.last_kf {
                None => immediate || now - self.since >= KF_PROMPT,
                Some(t) => now - t >= KF_RETRY,
            };
        if due {
            self.last_kf = Some(now);
        }
        due
    }
}

#[derive(Default)]
pub struct Stats {
    pub frames_in: u64,
    pub frames_out: u64,
    pub skipped: u64,
    pub kf_requests: u64,
    pub rebuilds: u64,
    pub errors: u64,
    /// Times the hand-off queue overflowed (frames dropped before decode, kf sent).
    pub drops: u64,
    /// Decoded frames replaced by a newer one before the swap chain could take them.
    pub stale: u64,
    /// Video payload bytes this interval.
    pub bytes: u64,
    /// Sender send -> our socket read, ms, when the clock offset is known.
    pub net_ms: Vec<f32>,
    /// CPU time inside the decoder per frame, µs (GPU work may still be in flight).
    pub dec_us: Vec<u32>,
    /// Draw + Present call per frame, µs.
    pub present_us: Vec<u32>,
    /// Sender capture -> Present returned, ms, when the clock offset is known.
    pub e2e_ms: Vec<f32>,
    pub size: (u32, u32),
}

/// Sorts `v` and returns the p-th percentile (0..=1).
pub fn percentile<T: Copy + PartialOrd>(v: &mut [T], p: f64) -> Option<T> {
    v.sort_unstable_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    v.get(((v.len() as f64 - 1.0) * p).round() as usize)
        .copied()
}

/// A decoded picture and its sender capture time (sender clock, ms).
pub struct Decoded {
    pub frame: Frame,
    pub cap: Option<f64>,
}

/// Per-frame decode logic: parameter-set tracking, resync and the decoder itself. Single-threaded.
pub struct Pipeline {
    pub gpu: Gpu,
    decoder: Option<Decoder>,
    /// Decoders created so far; a new one means a new surface pool.
    pub builds: u64,
    /// Last SPS followed by PPS; a change means a new stream (§5.2).
    params: Vec<u8>,
    resync: Resync,
    pub stats: Stats,
}

impl Pipeline {
    pub fn new(gpu: Gpu) -> Self {
        let n = 4096;
        let stats = Stats {
            net_ms: Vec::with_capacity(n),
            dec_us: Vec::with_capacity(n),
            present_us: Vec::with_capacity(n),
            e2e_ms: Vec::with_capacity(n),
            ..Default::default()
        };
        Self {
            gpu,
            decoder: None,
            builds: 0,
            params: Vec::with_capacity(256),
            resync: Resync::new(Instant::now()),
            stats,
        }
    }

    /// New sender: forget the stream entirely; counters restart for the new session.
    pub fn reset(&mut self, now: Instant) {
        let s = &mut self.stats;
        (
            s.frames_in,
            s.frames_out,
            s.skipped,
            s.kf_requests,
            s.rebuilds,
            s.errors,
            s.drops,
            s.stale,
            s.bytes,
        ) = (0, 0, 0, 0, 0, 0, 0, 0, 0);
        self.decoder = None;
        self.params.clear();
        self.resync = Resync::new(now);
    }

    /// Frames were dropped before reaching us. Returns true if kf should be sent.
    pub fn lost(&mut self, now: Instant) -> bool {
        self.resync.lost(now)
    }

    pub fn tick(&mut self, now: Instant) -> bool {
        self.resync.tick(now)
    }

    pub fn input_pool_size(&self) -> usize {
        self.decoder.as_ref().map_or(0, |d| d.input_pool_size())
    }

    /// Feeds one wire video frame read from the socket at `arrival` (our clock, ms). Returns the
    /// decoded picture (if any) and whether to send kf. `offset` is sender clock minus ours.
    pub fn frame(
        &mut self,
        payload: &[u8],
        arrival: f64,
        now: Instant,
        offset: Option<f64>,
    ) -> (Option<Decoded>, bool) {
        let (prefix, annexb) = split_prefix(payload);
        if annexb.is_empty() {
            return (None, false);
        }
        self.stats.frames_in += 1;
        self.stats.bytes += payload.len() as u64;
        let tel = telemetry(prefix);
        if let (Some(off), Some(snd)) = (offset, tel.as_ref().and_then(|t| t.snd)) {
            self.stats.net_ms.push((arrival + off - snd) as f32);
        }
        let info = scan(annexb);
        let mut kf = false;
        if let (Some(sps), Some(pps)) = (info.sps, info.pps)
            && (self.params.len() != sps.len() + pps.len()
                || self.params[..sps.len()] != *sps
                || self.params[sps.len()..] != *pps)
        {
            if !self.params.is_empty() {
                log::info!("parameter sets changed: rebuilding decoder");
                self.stats.rebuilds += 1;
            }
            self.params.clear();
            self.params.extend_from_slice(sps);
            self.params.extend_from_slice(pps);
            self.decoder = None;
            if !info.idr {
                kf |= self.resync.lost(now);
            }
        }
        let (decode, k) = self.resync.on_frame(info.idr, now);
        kf |= k;
        if !decode {
            self.stats.skipped += 1;
            self.stats.kf_requests += kf as u64;
            return (None, kf);
        }
        if self.decoder.is_none() {
            let t = Instant::now();
            match Decoder::new(&self.gpu) {
                Ok(d) => {
                    log::info!(
                        "decoder created in {:.1} ms",
                        t.elapsed().as_secs_f64() * 1000.0
                    );
                    self.decoder = Some(d);
                    self.builds += 1;
                }
                Err(e) => {
                    log::error!("decoder init failed: {e}");
                    self.stats.errors += 1;
                    kf |= self.resync.lost(now);
                    self.stats.kf_requests += kf as u64;
                    return (None, kf);
                }
            }
        }
        let t0 = Instant::now();
        let out = match self.decoder.as_mut().unwrap().decode(annexb) {
            Ok(f) => f,
            Err(e) => {
                log::warn!("decode error ({e}); waiting for an IDR");
                self.stats.errors += 1;
                self.decoder = None;
                kf |= self.resync.lost(now);
                None
            }
        };
        self.stats.kf_requests += kf as u64;
        if let Some(f) = &out {
            self.stats.frames_out += 1;
            self.stats.dec_us.push(t0.elapsed().as_micros() as u32);
            if (f.width, f.height) != self.stats.size {
                self.stats.size = (f.width, f.height);
                log::info!("decoding {}x{}", f.width, f.height);
            }
        }
        (
            out.map(|frame| Decoded {
                frame,
                cap: tel.and_then(|t| t.cap),
            }),
            kf,
        )
    }

    /// Records a frame whose draw + Present took `took`.
    pub fn presented(&mut self, cap: Option<f64>, took: Duration, offset: Option<f64>) {
        self.stats.present_us.push(took.as_micros() as u32);
        if let (Some(off), Some(cap)) = (offset, cap) {
            self.stats.e2e_ms.push((now_ms() + off - cap) as f32);
        }
    }

    /// Live overlay text for the current interval, written into `out` (reused, so no allocation
    /// once it has grown). Sorts the sample vectors in place.
    pub fn overlay(&mut self, out: &mut String, since: Duration, queued: usize) {
        let s = &mut self.stats;
        let us =
            |out: &mut String, v: &mut Vec<u32>| match (percentile(v, 0.5), percentile(v, 0.95)) {
                (Some(a), Some(b)) => write!(
                    out,
                    "{:6.2} {:6.2} ms",
                    a as f64 / 1000.0,
                    b as f64 / 1000.0
                ),
                _ => write!(out, "     -      -"),
            };
        let ms =
            |out: &mut String, v: &mut Vec<f32>| match (percentile(v, 0.5), percentile(v, 0.95)) {
                (Some(a), Some(b)) => write!(out, "{a:6.2} {b:6.2} ms"),
                _ => write!(out, "     -      -    (no clock offset yet)"),
            };
        out.clear();
        let fps = s.present_us.len() as f64 / since.as_secs_f64().max(0.001);
        let _ = writeln!(
            out,
            "{}x{}  in {}  out {}  fps {fps:.1}",
            s.size.0, s.size.1, s.frames_in, s.frames_out
        );
        let _ = writeln!(out, "            p50    p95");
        let _ = out.write_str("net     ");
        let _ = ms(out, &mut s.net_ms);
        let _ = out.write_str("\ndecode  ");
        let _ = us(out, &mut s.dec_us);
        let _ = out.write_str("\npresent ");
        let _ = us(out, &mut s.present_us);
        let _ = out.write_str("\ne2e     ");
        let _ = ms(out, &mut s.e2e_ms);
        let _ = write!(
            out,
            "\nqueue {queued}  drops {}  stale {}  kf {}  skipped {}",
            s.drops, s.stale, s.kf_requests, s.skipped
        );
    }

    /// One summary line and the `stats` message (transport, rtt and offsetKnown left for the
    /// caller); clears the per-interval samples.
    pub fn report(&mut self, period: Duration) -> (String, control::Stats) {
        let s = &mut self.stats;
        let secs = period.as_secs_f64();
        let ms_of = |v: Option<u32>| v.map(|x| x as f64 / 1000.0);
        let msg = control::Stats {
            fps: s.present_us.len() as f64 / secs,
            mbps: s.bytes as f64 * 8.0 / secs / 1e6,
            dec50: ms_of(percentile(&mut s.dec_us, 0.5)),
            ph50: ms_of(percentile(&mut s.present_us, 0.5)),
            ph95: ms_of(percentile(&mut s.present_us, 0.95)),
            e2e50: percentile(&mut s.e2e_ms, 0.5).map(f64::from),
            e2e95: percentile(&mut s.e2e_ms, 0.95).map(f64::from),
            stalls: s.stale,
            kf: s.kf_requests,
            drops: s.drops,
            ..Default::default()
        };
        let us = |v: &mut Vec<u32>, p| {
            percentile(v, p).map_or("-".into(), |x| format!("{:.2}ms", x as f64 / 1000.0))
        };
        let ms = |v: &mut Vec<f32>, p| percentile(v, p).map_or("-".into(), |x| format!("{x:.1}ms"));
        let line = format!(
            "{}x{} in {} out {} skipped {} kf {} rebuilds {} errors {} drops {} stale {} | fps {:.1} {:.1} Mbit/s | net50 {} | dec50 {} dec95 {} | ph50 {} ph95 {} | e2e50 {} e2e95 {}",
            s.size.0,
            s.size.1,
            s.frames_in,
            s.frames_out,
            s.skipped,
            s.kf_requests,
            s.rebuilds,
            s.errors,
            s.drops,
            s.stale,
            msg.fps,
            msg.mbps,
            ms(&mut s.net_ms, 0.5),
            us(&mut s.dec_us, 0.5),
            us(&mut s.dec_us, 0.95),
            us(&mut s.present_us, 0.5),
            us(&mut s.present_us, 0.95),
            ms(&mut s.e2e_ms, 0.5),
            ms(&mut s.e2e_ms, 0.95),
        );
        s.net_ms.clear();
        s.dec_us.clear();
        s.present_us.clear();
        s.e2e_ms.clear();
        s.bytes = 0;
        (line, msg)
    }
}

enum Work {
    Reset(Arc<Session>),
    /// Payload and its socket read time (our clock, ms).
    Frame(Vec<u8>, f64),
    /// Cursor position or sprite changed: redraw even without a new frame.
    Cursor,
}

/// Network-side end of the video path. Implements [`Handler`] for the session layer.
pub struct VideoIn {
    tx: SyncSender<Work>,
    pool: Mutex<Pool>,
    overflow: Arc<AtomicBool>,
    /// Frames handed off and not yet taken by the decode thread.
    queued: Arc<AtomicUsize>,
    /// The live session, for re-sending `hello` and for `cursorAck`.
    session: Arc<Mutex<Option<Arc<Session>>>>,
    hello: Arc<dyn Fn() -> Hello + Send + Sync>,
    cursor: Arc<Cursor>,
    /// The Windows session is locked: senders are turned away with `sleeping`.
    locked: Arc<AtomicBool>,
}

struct Pool {
    /// Empty buffers coming back from the decoder.
    free: Receiver<Vec<u8>>,
    /// Returns a buffer we could not queue.
    back: Sender<Vec<u8>>,
}

/// Opens the window and starts the decode+present thread. Buffers are preallocated and
/// recycled, so steady state does not allocate. `hello` builds the current hello, re-sent on the
/// live session whenever the display changes (§6.1, §6.7).
pub fn spawn(
    name: String,
    hello: impl Fn() -> Hello + Send + Sync + 'static,
) -> io::Result<Arc<VideoIn>> {
    let hello: Arc<dyn Fn() -> Hello + Send + Sync> = Arc::new(hello);
    let session: Arc<Mutex<Option<Arc<Session>>>> = Arc::default();
    let (live, h) = (session.clone(), hello.clone());
    let (input_tx, input_rx) = sync_channel(INPUT_QUEUE);
    let target = session.clone();
    thread::Builder::new()
        .name("input-tx".into())
        .spawn(move || send_input(input_rx, &target))?;
    let locked = Arc::new(AtomicBool::new(false));
    let l = locked.clone();
    let ui = window::spawn(move |e| match e {
        Event::DisplayChanged => rehello(&live, &*h, "display changed"),
        Event::Input(m) => {
            let _ = input_tx.try_send((m, now_ms()));
        }
        Event::Quit => end(&live, &Outgoing::Closing, "quitting"),
        Event::Locked(on) => {
            l.store(on, Ordering::Release);
            if on {
                end(&live, &Outgoing::Sleeping, "session locked");
            }
        }
    })?;
    // One slot more than QUEUE for a cursor wake-up; `video` keeps frames to QUEUE.
    let (tx, rx) = sync_channel(QUEUE + 1);
    let (free_tx, free_rx) = channel();
    for _ in 0..QUEUE + 2 {
        let _ = free_tx.send(Vec::with_capacity(1 << 20));
    }
    let overflow = Arc::new(AtomicBool::new(false));
    let queued = Arc::new(AtomicUsize::new(0));
    let cursor = Arc::new(Cursor::default());
    let (o, f, q, c) = (
        overflow.clone(),
        free_tx.clone(),
        queued.clone(),
        cursor.clone(),
    );
    thread::Builder::new()
        .name("decode".into())
        .spawn(move || run(rx, f, o, q, ui, c, &name))?;
    Ok(Arc::new(VideoIn {
        tx,
        pool: Mutex::new(Pool {
            free: free_rx,
            back: free_tx,
        }),
        overflow,
        queued,
        session,
        hello,
        cursor,
        locked,
    }))
}

/// Sends `msg` (`closing` or `sleeping`, §6.1) best-effort and closes the live session.
fn end(session: &Mutex<Option<Arc<Session>>>, msg: &Outgoing, why: &str) {
    let live = session.lock().unwrap().clone();
    if let Some(s) = live.filter(|s| !s.is_closed()) {
        log::info!("{why}: closing the session");
        let _ = s.send(msg);
        s.close();
    }
}

/// Sends input off the UI thread, so a stalled connection never freezes the window. Stamps `t`
/// in the sender's clock (§8.1) and degrades the stylus to `touch` for senders below pv 3 (§6.1).
fn send_input(rx: Receiver<(Outgoing, f64)>, live: &Mutex<Option<Arc<Session>>>) {
    for (mut msg, at) in rx {
        let Some(s) = live.lock().unwrap().clone().filter(|s| !s.is_closed()) else {
            continue;
        };
        if s.sender_pv() < 3 {
            msg = match msg {
                Outgoing::Pencil { phase, x, y, .. } => {
                    let phase = match phase {
                        PencilPhase::Down => TouchPhase::Began,
                        PencilPhase::Move => TouchPhase::Moved,
                        PencilPhase::Up => TouchPhase::Ended,
                        PencilPhase::Hover => continue,
                    };
                    Outgoing::Touch {
                        phase,
                        x,
                        y,
                        t: None,
                    }
                }
                Outgoing::Proximity { .. } => continue,
                m => m,
            };
        }
        if let Outgoing::Touch { t, .. } | Outgoing::Pencil { t, .. } = &mut msg {
            *t = s.clock.lock().unwrap().offset().map(|o| at + o);
        }
        let _ = s.send(&msg);
    }
}

fn rehello(session: &Mutex<Option<Arc<Session>>>, hello: &dyn Fn() -> Hello, why: &str) {
    // Cloned out so a slow send never holds the lock.
    let live = session.lock().unwrap().clone();
    if let Some(s) = live.filter(|s| !s.is_closed()) {
        log::info!("{why}: re-sending hello");
        let _ = s.send(&Outgoing::Hello(hello()));
    }
}

impl VideoIn {
    /// Re-sends `hello` on the live session, e.g. to withdraw `cursorPort` (§6.3).
    pub fn rehello(&self, why: &str) {
        rehello(&self.session, &*self.hello, why);
    }

    /// Wakes the present thread to redraw the cursor; at most one wake-up is ever queued.
    fn wake(&self) {
        if !self.cursor.woken.swap(true, Ordering::AcqRel)
            && self.tx.try_send(Work::Cursor).is_err()
        {
            self.cursor.woken.store(false, Ordering::Release);
        }
    }

    /// The UDP cursor side channel (§6.3); returns when the socket fails. Accepts datagrams only
    /// from the live sender's host and only from its most recent flow. No allocation per datagram.
    pub fn serve_cursor(&self, sock: &UdpSocket) -> io::Error {
        let mut buf = [0u8; 1500];
        let (mut flow, mut conn, mut acked) = (None, 0, false);
        loop {
            let (n, from) = match sock.recv_from(&mut buf) {
                Ok(r) => r,
                // WSAEMSGSIZE: larger than any cursor message, and already discarded.
                Err(e) if e.raw_os_error() == Some(10040) => continue,
                Err(e) => return e,
            };
            let Some(session) = self
                .session
                .lock()
                .unwrap()
                .clone()
                .filter(|s| !s.is_closed())
            else {
                continue;
            };
            if session.peer.ip().to_canonical() != from.ip().to_canonical() {
                continue;
            }
            let Ok(d) = serde_json::from_slice::<Datagram>(&buf[..n]) else {
                continue;
            };
            if d.t != "cursor" {
                continue;
            }
            let c = self.cursor.conn.load(Ordering::Acquire);
            if flow != Some(from) || conn != c {
                (flow, conn, acked) = (Some(from), c, false);
                self.cursor.new_flow();
            }
            let (accepted, changed) = self.cursor.apply(d.x, d.y, d.v, Some(d.s));
            if changed {
                self.wake();
            }
            if accepted && !acked {
                acked = true;
                let _ = session.send(&Outgoing::CursorAck);
            }
        }
    }
}

impl Handler for VideoIn {
    fn connected(&self, session: &Arc<Session>) {
        if self.locked.load(Ordering::Acquire) {
            log::info!("session locked: turning the sender away with sleeping");
            let _ = session.send(&Outgoing::Sleeping);
            session.close();
            return;
        }
        // Before publishing the session, so the UDP thread never pairs it with the old flow.
        self.cursor.new_connection();
        *self.session.lock().unwrap() = Some(session.clone());
        let _ = self.tx.send(Work::Reset(session.clone()));
    }

    fn video(&self, _: &Session, payload: &[u8]) {
        let arrival = now_ms();
        // The channel has a slot more than QUEUE, kept for a cursor wake-up.
        if self.queued.load(Ordering::Relaxed) >= QUEUE {
            self.overflow.store(true, Ordering::Relaxed);
            return;
        }
        let pool = self.pool.lock().unwrap(); // only ever taken by the network thread
        let Ok(mut buf) = pool.free.try_recv() else {
            self.overflow.store(true, Ordering::Relaxed);
            return;
        };
        buf.clear();
        buf.extend_from_slice(payload);
        match self.tx.try_send(Work::Frame(buf, arrival)) {
            Ok(()) => {
                self.queued.fetch_add(1, Ordering::Relaxed);
            }
            Err(
                TrySendError::Full(Work::Frame(b, _))
                | TrySendError::Disconnected(Work::Frame(b, _)),
            ) => {
                let _ = pool.back.send(b);
                self.overflow.store(true, Ordering::Relaxed);
            }
            Err(_) => {}
        }
    }

    fn control(&self, _: &Session, msg: &Incoming) {
        match msg {
            Incoming::Cursor { x, y, v, s } => {
                if self.cursor.apply(*x, *y, *v, *s).1 {
                    self.wake();
                }
            }
            Incoming::CursorImg {
                nw,
                nh,
                ax,
                ay,
                png,
            } => {
                *self.cursor.sprite.lock().unwrap() = Some(Sprite {
                    nw: *nw,
                    nh: *nh,
                    ax: *ax,
                    ay: *ay,
                    png: png.clone(),
                });
                self.wake();
            }
            // §6.2: surface it prominently; the sender may keep streaming, so nothing else changes.
            Incoming::UpdateRequired { message, store, .. } => {
                let mut text = message
                    .clone()
                    .unwrap_or_else(|| "The sender requires an update of this receiver.".into());
                if let Some(url) = store {
                    text = format!("{text}\n\n{url}");
                }
                window::alert(text);
            }
            _ => {}
        }
    }
}

/// The decode+present thread: decodes every frame, presents only the newest.
fn run(
    rx: Receiver<Work>,
    free: Sender<Vec<u8>>,
    overflow: Arc<AtomicBool>,
    queued: Arc<AtomicUsize>,
    ui: Arc<Ui>,
    cursor: Arc<Cursor>,
    name: &str,
) {
    let gpu = match Gpu::new(monitor::current().ok().map(|m| m.device).as_ref()) {
        Ok(g) => g,
        Err(e) => return log::error!("GPU init failed, video disabled: {e}"),
    };
    let mut presenter = match Presenter::new(&gpu, ui.hwnd(), name) {
        Ok(p) => p,
        Err(e) => return log::error!("swap chain init failed, video disabled: {e}"),
    };
    let mut pl = Pipeline::new(gpu);
    let mut session: Option<Arc<Session>> = None;
    let mut offset = None;
    let mut last_report = Instant::now();
    let mut builds = 0;
    // Decoded but not yet taken by the swap chain; a newer frame replaces it.
    let mut pending: Option<Decoded> = None;
    // On screen; holding it keeps its decoder surface from being reused.
    let mut shown: Option<Decoded> = None;
    // Redraw `shown` (resize, overlay toggle) even without a new frame.
    let mut dirty = true;
    let mut overlay_on = false;
    // Cursor state last drawn; a different one means redraw.
    let mut drawn_cursor = 0;
    let (mut text, mut wide) = (String::with_capacity(1024), Vec::<u16>::with_capacity(1024));
    let send_kf = |s: &Option<Arc<Session>>| {
        if let Some(s) = s {
            let _ = s.send(&Outgoing::Kf);
        }
    };
    loop {
        let wait = if pending.is_some() || dirty {
            Duration::ZERO
        } else {
            Duration::from_millis(100)
        };
        let work = rx.recv_timeout(wait);
        let now = Instant::now();
        match work {
            Ok(Work::Reset(s)) => {
                presenter.set_status(Some(s.peer.ip().to_canonical()));
                pl.reset(now);
                session = Some(s);
                offset = None;
                (pending, shown, dirty) = (None, None, true);
            }
            Ok(Work::Frame(buf, arrival)) => {
                queued.fetch_sub(1, Ordering::Relaxed);
                let lost = overflow.swap(false, Ordering::Relaxed);
                pl.stats.drops += lost as u64;
                let lost = lost && pl.lost(now);
                let (frame, kf) = pl.frame(&buf, arrival, now, offset);
                let _ = free.send(buf);
                if let Some(f) = frame {
                    pl.stats.stale += pending.replace(f).is_some() as u64;
                }
                if lost || kf {
                    send_kf(&session);
                }
            }
            Ok(Work::Cursor) => {
                cursor.woken.store(false, Ordering::Release);
                if let Some(s) = cursor.sprite.lock().unwrap().take() {
                    if let Err(e) = presenter.set_cursor(&s) {
                        log::warn!("cursor sprite rejected: {e}");
                    }
                    dirty = true;
                }
            }
            Err(RecvTimeoutError::Timeout) => {
                if pl.tick(now) {
                    send_kf(&session);
                }
            }
            Err(RecvTimeoutError::Disconnected) => return,
        }
        // The sender left: back to the idle screen.
        if session.as_ref().is_some_and(|s| s.is_closed()) {
            session = None;
            offset = None;
            presenter.set_status(None);
            (pending, shown, dirty) = (None, None, true);
        }
        if pl.builds != builds {
            builds = pl.builds;
            presenter.forget();
        }
        if ui.resized.swap(false, Ordering::AcqRel) {
            if let Err(e) = presenter.resize() {
                log::error!("swap chain resize failed: {e}");
            }
            dirty = true;
        }
        if ui.overlay.load(Ordering::Acquire) != overlay_on {
            overlay_on = !overlay_on;
            dirty = true;
        }
        let c = cursor.raw();
        dirty |= c != drawn_cursor;
        if pending.is_some() || dirty {
            drawn_cursor = c;
            let t0 = Instant::now();
            let overlay = overlay_on.then(|| {
                pl.overlay(&mut text, now - last_report, queued.load(Ordering::Relaxed));
                if let Some(s) = &session {
                    sender_lines(
                        &mut text,
                        s.clock.lock().unwrap().rtt(),
                        *s.health.lock().unwrap(),
                        cursor.stale.load(Ordering::Relaxed),
                    );
                }
                wide.clear();
                wide.extend(text.encode_utf16());
                wide.as_slice()
            });
            let frame = pending.as_ref().or(shown.as_ref()).map(|d| &d.frame);
            let size = frame.map(|f| (f.width, f.height));
            match presenter.present(frame, Cursor::unpack(c), overlay) {
                Ok(true) => {
                    dirty = false;
                    ui.set_video(presenter.video_rect, size);
                    if let Some(d) = pending.take() {
                        pl.presented(d.cap, t0.elapsed(), offset);
                        shown = Some(d);
                    }
                }
                // Swap chain busy (e.g. still showing a cursor-only redraw): retry with the newest frame once free.
                Ok(false) => presenter.wait(PRESENT_WAIT),
                Err(e) => {
                    // shortcut: no device-lost recovery; a removed GPU (driver update, TDR) needs a restart.
                    log::error!("present failed: {e}");
                    dirty = false;
                    shown = pending.take().or(shown);
                }
            }
        }
        if now - last_report >= STATS_EVERY {
            offset = session
                .as_ref()
                .and_then(|s| s.clock.lock().unwrap().offset());
            if let Some(s) = session.as_ref().filter(|s| !s.is_closed()) {
                let (line, mut msg) = pl.report(now - last_report);
                log::info!(
                    "{line} | cursor stale {}",
                    cursor.stale.load(Ordering::Relaxed)
                );
                // Loopback stands in for a cable; anything else is the LAN binding (§2).
                msg.transport = if s.peer.ip().to_canonical().is_loopback() {
                    "usb"
                } else {
                    "wifi"
                };
                msg.rtt = s.clock.lock().unwrap().rtt();
                msg.offset_known = offset.is_some();
                let _ = s.send(&Outgoing::Stats(msg));
            }
            last_report = now;
        }
    }
}

/// Overlay lines about the link and the sender's own health (from its `ping`).
fn sender_lines(out: &mut String, rtt: Option<f64>, h: SenderHealth, cursor_stale: u64) {
    let opt = |out: &mut String, v: Option<f64>| match v {
        Some(v) => write!(out, "{v:.1}"),
        None => out.write_str("-"),
    };
    let _ = out.write_str("\nrtt ");
    let _ = opt(out, rtt);
    let _ = write!(out, " ms  cursor stale {cursor_stale}\nsender cap ");
    let _ = opt(out, h.cap_fps);
    let _ = out.write_str(" fps  drops enc ");
    let _ = opt(out, h.enc_drops.or(h.drops));
    let _ = out.write_str(" net ");
    let _ = opt(out, h.net_drops);
    let _ = out.write_str("  pending ");
    let _ = opt(out, h.pending);
    let _ = out.write_str("\nsender input p50 ");
    let _ = opt(out, h.inp50);
    let _ = out.write_str(" p95 ");
    let _ = opt(out, h.inp95);
    let _ = out.write_str(" ms");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resync_waits_for_idr_and_paces_kf() {
        let t0 = Instant::now();
        let ms = |n| t0 + Duration::from_millis(n);
        let mut r = Resync::new(t0);
        assert!(!r.tick(ms(100)), "no kf before the prompt delay");
        assert!(r.tick(ms(600)), "kf when no IDR arrives promptly");
        assert_eq!(
            r.on_frame(false, ms(700)),
            (false, false),
            "P-frame skipped, kf not repeated yet"
        );
        assert_eq!(
            r.on_frame(false, ms(1700)),
            (false, true),
            "kf repeated after 1 s"
        );
        assert_eq!(r.on_frame(true, ms(1750)), (true, false));
        assert_eq!(r.on_frame(false, ms(1760)), (true, false));
        assert!(!r.tick(ms(9000)), "no kf while decoding");
    }

    #[test]
    fn joining_mid_gop_requests_kf_immediately() {
        let t0 = Instant::now();
        let mut r = Resync::new(t0);
        assert_eq!(r.on_frame(false, t0), (false, true));
    }

    #[test]
    fn loss_requests_kf_immediately() {
        let t0 = Instant::now();
        let mut r = Resync::new(t0);
        r.on_frame(true, t0);
        assert!(r.lost(t0));
        assert_eq!(r.on_frame(false, t0), (false, false));
        assert_eq!(r.on_frame(true, t0), (true, false));
    }

    #[test]
    fn percentiles() {
        let mut v = vec![5, 1, 4, 2, 3];
        assert_eq!(percentile(&mut v, 0.5), Some(3));
        assert_eq!(percentile(&mut v, 1.0), Some(5));
        assert_eq!(percentile::<u32>(&mut [], 0.5), None);
    }
}
