//! The sender session: one receiver, one virtual display, capture -> encode ->
//! wire, driven by `SenderSession` (§1 sender dials, §5, §6, §8). Talks to
//! the compositor only through [`Backend`] / [`VirtualDisplay`] /
//! [`InputSink`].

use std::collections::VecDeque;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use opendisplay_proto::control::{CursorImg, Hello, StreamConfig};
use opendisplay_session::Now;
use opendisplay_session::sender::{SenderAction, SenderConfig, SenderEvent, SenderSession};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, watch};
use tracing::{debug, info, warn};

use crate::backend::lock::{self, LockHeld};
use crate::backend::{
    Backend, CaptureEvent, CaptureOptions, CursorEvent, DisplayInfo, DisplaySpec, Frame, FrameSink,
    InputSink, Position, VirtualDisplay,
};
use crate::config::{self, Config, Layer};
use crate::desktop::{self, Debounce, DesktopOptions, DesktopPlan, PlanError, StreamPlan};
use crate::encoder::{ConvertStage, Encoded, Encoder, EncoderSettings};
use crate::latest;
use crate::wayland::cursor::base64;

/// How the pointer cursor reaches the receiver.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, clap::ValueEnum)]
pub enum CursorMode {
    /// On the cursor side channel (`cursor`/`cursorImg`, PROTOCOL §6.3) when
    /// the receiver offers a `cursorPort` and the compositor can deliver the
    /// cursor separately; painted into the video otherwise.
    #[default]
    Auto,
    /// Always painted into the video.
    Video,
    /// Not shown.
    Off,
}

/// Whether to ask the display for the cursor on its own: `Auto`, a backend
/// that can, and a receiver that renders a cursor (it offers `cursorPort`).
fn cursor_separately(mode: CursorMode, backend_can: bool, receiver_offers: bool) -> bool {
    mode == CursorMode::Auto && backend_can && receiver_offers
}

#[derive(Debug, Clone)]
pub struct RunOptions {
    pub bitrate_mbps: f32,
    /// Output scale policy and frame-rate cap for [`desktop::plan`].
    pub desktop: DesktopOptions,
    pub threads: u16,
    pub encoder: crate::encoder::Backend,
    /// How the cursor reaches the receiver.
    pub cursor: CursorMode,
    /// Where the virtual output goes.
    pub position: Position,
    /// Workspace to show on the virtual output (`--workspace`).
    pub workspace: Option<String>,
    /// Leave the virtual output in place when the session ends.
    pub keep_output: bool,
    pub reconnect: bool,
    pub duration: Option<Duration>,
    /// The receiver's id when discovery told us, so a lock conflict is found
    /// before dialing (the receiver hands itself to whoever connects last).
    pub receiver_id: Option<String>,
    /// How the receiver is named in messages before its `hello` arrives.
    pub receiver_name: String,
    /// What the command line set explicitly; wins over the config file.
    pub cli: Layer,
    /// The config file, for `[receiver."…"]` overrides.
    pub config: Config,
}

impl RunOptions {
    /// These options with the config file's table for this receiver applied
    /// under the command line. `keys`: id, Bonjour name, device name.
    pub fn for_receiver(&self, keys: &[Option<&str>]) -> RunOptions {
        let Some((key, o)) = self.config.receiver(keys) else {
            return self.clone();
        };
        debug!("config: [receiver.\"{key}\"] applies");
        let eff = self
            .cli
            .over(o)
            .over(&self.config.defaults)
            .over(&config::builtin());
        RunOptions {
            position: eff.position.unwrap_or(self.position),
            workspace: eff.workspace.or_else(|| self.workspace.clone()),
            bitrate_mbps: eff.bitrate_mbps.unwrap_or(self.bitrate_mbps),
            desktop: DesktopOptions {
                scale: eff.scale.unwrap_or(self.desktop.scale),
                ..self.desktop
            },
            ..self.clone()
        }
    }
}

fn now(start: Instant) -> Now {
    let wall_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0);
    Now::new(start.elapsed(), wall_ms)
}

/// The output for a receiver with this `hello.id` (equal to its Bonjour TXT
/// `id`, PROTOCOL §2.1): `od-<first 6 chars>`; also the lock key. The id is
/// receiver-supplied and the name reaches compositor IPC, Lua and a file
/// path, so an id whose first 6 characters are not all `[a-z0-9]` (after
/// lower-casing) is named by a hash of the whole id instead.
pub fn output_name(id: Option<&str>) -> String {
    let Some(id) = id.filter(|s| !s.is_empty()) else {
        return "od-anon".into();
    };
    let short: String = id.chars().take(6).collect::<String>().to_lowercase();
    let plain = short.len() == 6
        && short
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit());
    if plain {
        format!("od-{short}")
    } else {
        format!("od-{:06x}", fnv1a(id.as_bytes()) & 0xff_ffff)
    }
}

/// 32-bit FNV-1a; stable across builds, unlike `DefaultHasher`.
fn fnv1a(bytes: &[u8]) -> u32 {
    bytes.iter().fold(0x811c_9dc5, |h, &b| {
        (h ^ u32::from(b)).wrapping_mul(0x0100_0193)
    })
}

/// What a `hello` asks the backend for: the desktop plan plus where and
/// under which name the output goes.
#[derive(Debug, Clone, PartialEq)]
pub struct Target {
    pub spec: DisplaySpec,
    pub plan: DesktopPlan,
}

pub fn target(hello: &Hello, opts: &RunOptions) -> Result<Target, PlanError> {
    let plan = desktop::plan(hello, &opts.desktop)?;
    Ok(Target {
        spec: DisplaySpec {
            name: output_name(hello.id.as_deref()),
            width: plan.output.width,
            height: plan.output.height,
            hz: plan.output.hz,
            scale: plan.output.scale,
            position: opts.position,
        },
        plan,
    })
}

/// The stream to announce for the display as built. A backend that cannot
/// size its output (adopt) streams the output as it is.
fn stream_for(info: &DisplayInfo, target: &Target) -> StreamPlan {
    let s = target.plan.stream;
    if (info.width, info.height) == (target.spec.width, target.spec.height) {
        s
    } else {
        StreamPlan {
            width: info.width & !1,
            height: info.height & !1,
            ..s
        }
    }
}

/// How often a display that vanished under the session (output removed,
/// capture stopped by the compositor) is recreated before giving up.
pub struct LossBudget {
    window: Duration,
    max: usize,
    losses: VecDeque<Instant>,
}

impl Default for LossBudget {
    fn default() -> Self {
        Self {
            window: Duration::from_secs(60),
            max: 3,
            losses: VecDeque::new(),
        }
    }
}

impl LossBudget {
    /// Record a loss at `at`; `false` once more than `max` fall in `window`.
    pub fn allow(&mut self, at: Instant) -> bool {
        while self
            .losses
            .front()
            .is_some_and(|&t| at.duration_since(t) > self.window)
        {
            self.losses.pop_front();
        }
        self.losses.push_back(at);
        self.losses.len() <= self.max
    }
}

/// Spawn a pipeline thread whose panic is reported on `lost` like a lost
/// display, so the session rebuilds (or gives up) instead of waiting on a
/// channel nobody feeds.
fn spawn_reporting_panics(
    name: &str,
    lost: mpsc::UnboundedSender<String>,
    f: impl FnOnce() + Send + 'static,
) -> std::io::Result<std::thread::JoinHandle<()>> {
    struct Report(String, mpsc::UnboundedSender<String>);
    impl Drop for Report {
        fn drop(&mut self) {
            if std::thread::panicking() {
                let _ = self.1.send(format!("{} thread panicked", self.0));
            }
        }
    }
    let report = Report(name.to_string(), lost);
    std::thread::Builder::new()
        .name(name.into())
        .spawn(move || {
            let _report = report;
            f();
        })
}

/// Encoder thread fed by a capture [`FrameSink`]: latest frame wins, rate
/// capped, last frame replayed as an IDR on a static screen (§5.3).
struct EncodePipeline {
    stop: Arc<AtomicBool>,
    force_idr: Arc<AtomicBool>,
    raw_tx: Option<latest::Sender<Frame>>,
    /// Converts large frames ahead of the encoder (encoder/stage.rs).
    stage: ConvertStage,
    encoded_rx: mpsc::Receiver<Encoded>,
    lost_tx: mpsc::UnboundedSender<String>,
    lost_rx: mpsc::UnboundedReceiver<String>,
}

impl EncodePipeline {
    fn start(mut settings: EncoderSettings) -> Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let force_idr = Arc::new(AtomicBool::new(true));
        let (raw_tx, raw_rx) = latest::channel::<Frame>();
        let (encoded_tx, encoded_rx) = mpsc::channel::<Encoded>(4);
        let (lost_tx, lost_rx) = mpsc::unbounded_channel();
        let enc_stop = stop.clone();
        let enc_force = force_idr.clone();
        let stage = ConvertStage::new();
        let enc_stage = stage.clone();
        spawn_reporting_panics("encode", lost_tx.clone(), move || {
            let mut encoder: Option<Encoder> = None;
            let mut last: Option<Frame> = None;
            // Newest captured frame not yet encoded. A frame that arrives
            // inside the rate cap waits here for its slot rather than
            // being dropped: on a screen that then goes static it is the
            // last picture, and no further damage would ever replace it.
            let mut pending: Option<Frame> = None;
            let min_interval = Duration::from_secs_f32(1.0 / settings.max_fps.max(1.0));
            // The cap is measured between encode starts, so encode time
            // counts towards the interval instead of adding to it.
            let mut last_start = Instant::now() - min_interval;
            while !enc_stop.load(Ordering::Relaxed) {
                let timeout = if pending.is_some() {
                    min_interval.saturating_sub(last_start.elapsed())
                } else {
                    Duration::from_millis(100)
                };
                match raw_rx.recv_timeout(timeout) {
                    Ok(f) => pending = Some(f),
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                    Err(_) => break,
                }
                let frame = if pending.is_some() {
                    if last_start.elapsed() < min_interval {
                        continue;
                    }
                    pending.take().unwrap()
                } else if enc_force.load(Ordering::Relaxed) && last.is_some() {
                    // Static screen and an IDR was asked for: replay (§5.3).
                    last.take().unwrap()
                } else {
                    continue;
                };
                last_start = Instant::now();
                let (w, h) = frame.dimensions();
                if encoder
                    .as_ref()
                    .is_none_or(|e| e.dimensions() != (w & !1, h & !1))
                {
                    match Encoder::new(w, h, settings) {
                        Ok(e) => {
                            info!(
                                "encoder: {} {}x{} {:.1} Mbit/s, {} threads",
                                e.label(),
                                w & !1,
                                h & !1,
                                settings.bitrate_bps as f64 / 1e6,
                                settings.threads
                            );
                            // A resize reopens the same backend without probing.
                            settings.backend = e.backend();
                            enc_stage.bind(&e);
                            encoder = Some(e);
                            enc_force.store(true, Ordering::Relaxed);
                        }
                        Err(e) => {
                            warn!("encoder init failed: {e:#}");
                            continue;
                        }
                    }
                }
                let force = enc_force.swap(false, Ordering::Relaxed);
                match encoder.as_mut().unwrap().encode(&frame, force) {
                    Ok(units) => {
                        if force && !units.iter().any(|u| u.unit.is_idr) {
                            warn!("encoder ignored the IDR request");
                            enc_force.store(true, Ordering::Relaxed);
                        }
                        if units
                            .into_iter()
                            .any(|enc| encoded_tx.blocking_send(enc).is_err())
                        {
                            break;
                        }
                    }
                    Err(e) => warn!("encode failed: {e:#}"),
                }
                last = Some(frame);
            }
            debug!("encoder thread done");
        })?;
        Ok(Self {
            stop,
            force_idr,
            raw_tx: Some(raw_tx),
            stage,
            encoded_rx,
            lost_tx,
            lost_rx,
        })
    }

    /// The capture side: a frame replaces one the busy encoder has not
    /// taken yet, so encoding starts on the newest picture; reports the end
    /// of capture to the session.
    fn sink(&mut self) -> FrameSink {
        let raw_tx = self.raw_tx.take().expect("one sink per pipeline");
        let lost_tx = self.lost_tx.clone();
        self.stage.sink(Box::new(move |ev| match ev {
            CaptureEvent::Frame(f) => {
                raw_tx.send(f);
            }
            CaptureEvent::Ended(why) => {
                let _ = lost_tx.send(why);
            }
        }))
    }
}

impl Drop for EncodePipeline {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

/// The live display with its encoder and input.
struct Active {
    input: Option<Box<dyn InputSink>>,
    display: Box<dyn VirtualDisplay>,
    pipe: EncodePipeline,
    target: Target,
    cursor: CursorSide,
    /// The newest position while `Pending`, sent once the channel is live.
    held_position: Option<(f64, f64)>,
    /// Which `build` made this; a drift result for an older one is stale.
    generation: u64,
}

/// The cursor side channel for one display.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CursorSide {
    /// Not used: the cursor is painted (or off).
    Off,
    /// Cursor session running, still painting until the first sprite: a
    /// receiver must never be left with no cursor at all.
    Pending,
    /// Sprite sent, frames without the cursor, positions forwarded.
    Live,
    /// Gave up (no sprite): painting again for this display.
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CursorAction {
    Ignore,
    /// Pending: remember the position for when the channel goes live.
    Hold,
    Forward,
    /// First sprite: stop painting, send the sprite and the held position.
    GoLive,
    /// No sprite: paint again; hide the receiver's cursor if it was live.
    Fail,
}

fn cursor_step(side: CursorSide, ev: &CursorEvent) -> (CursorSide, CursorAction) {
    use CursorAction::*;
    use CursorSide::*;
    match (side, ev) {
        (Off | Failed, _) => (side, Ignore),
        (Pending | Live, CursorEvent::SpriteUnavailable(_)) => (Failed, Fail),
        (Pending, CursorEvent::Image { .. }) => (Live, GoLive),
        (Pending, _) => (Pending, Hold),
        (Live, _) => (Live, Forward),
    }
}

impl Active {
    /// Input first, then the display (capture stops before the output goes),
    /// then the encoder.
    fn close(self, keep_output: bool) {
        let Active {
            input,
            display,
            pipe,
            ..
        } = self;
        drop(input);
        let name = display.info().name.clone();
        if let Err(e) = display.close(keep_output) {
            warn!("closing {name}: {e:#}");
        }
        drop(pipe);
    }
}

/// Open (or resize in place) the display for `plan`, then start capture,
/// the encoder and input. On error nothing is active; a display dropped on
/// the way stops its capture and removes its output.
fn build(
    backend: &mut dyn Backend,
    active: &mut Option<Active>,
    target: Target,
    opts: &RunOptions,
    cursor: Option<&mpsc::UnboundedSender<CursorEvent>>,
) -> Result<StreamPlan> {
    let mut display = match active.take() {
        Some(Active {
            input,
            mut display,
            pipe,
            target: old,
            ..
        }) => {
            drop(input);
            display.stop_capture();
            drop(pipe);
            if old.spec.name == target.spec.name {
                display.reconfigure(&target.spec)?;
                display
            } else {
                if let Err(e) = display.close(opts.keep_output) {
                    warn!("closing {}: {e:#}", old.spec.name);
                }
                backend.open(&target.spec)?
            }
        }
        None => backend.open(&target.spec)?,
    };
    let mut pipe = EncodePipeline::start(EncoderSettings {
        backend: opts.encoder,
        bitrate_bps: (opts.bitrate_mbps * 1e6) as u32,
        max_fps: target.plan.stream.fps as f32,
        threads: opts.threads,
    })?;
    // Painted until the side channel has delivered its first sprite.
    let painted = opts.cursor != CursorMode::Off;
    let mut side = CursorSide::Off;
    if let Some(tx) = cursor {
        let tx = tx.clone();
        match display.start_cursor(Box::new(move |ev| {
            let _ = tx.send(ev);
        })) {
            Ok(()) => side = CursorSide::Pending,
            Err(e) => {
                debug!("cursor side channel unavailable ({e:#}); the cursor stays in the video")
            }
        }
    }
    display.start_capture(CaptureOptions { cursor: painted }, pipe.sink())?;
    let input = match display.input() {
        Ok(i) => Some(i),
        Err(e) => {
            warn!("input injection unavailable: {e:#}");
            None
        }
    };
    if let Some(ws) = &opts.workspace {
        place_workspace(backend, &display.info().name, ws);
    }
    let stream = stream_for(display.info(), &target);
    static GENERATION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    *active = Some(Active {
        input,
        display,
        pipe,
        target,
        cursor: side,
        held_position: None,
        generation: GENERATION.fetch_add(1, Ordering::Relaxed),
    });
    Ok(stream)
}

/// Show `--workspace` on the display; a desktop without the feature says
/// so once per process, and a failure never ends the session.
fn place_workspace(backend: &mut dyn Backend, output: &str, ws: &str) {
    static UNSUPPORTED_SAID: AtomicBool = AtomicBool::new(false);
    if !backend.supports_workspaces() {
        if !UNSUPPORTED_SAID.swap(true, Ordering::Relaxed) {
            warn!(
                "--workspace is not supported on this desktop ({}); ignoring it",
                backend.id()
            );
        }
        return;
    }
    match backend.show_workspace(output, ws) {
        Ok(()) => info!("workspace {ws} on {output}"),
        Err(e) => warn!("could not show workspace {ws} on {output}: {e:#}"),
    }
}

/// Resolves to `true` on SIGINT, SIGTERM or SIGHUP. Handled explicitly so the output
/// is torn down in order, and because a sender started in the background by
/// a non-interactive shell inherits SIGINT as ignored.
fn shutdown_signal() -> Result<watch::Receiver<bool>> {
    use tokio::signal::unix::{SignalKind, signal};
    let (tx, rx) = watch::channel(false);
    let mut int = signal(SignalKind::interrupt())?;
    let mut term = signal(SignalKind::terminate())?;
    // The terminal closing (or a systemd reload) must not kill us mid-capture.
    let mut hup = signal(SignalKind::hangup())?;
    tokio::spawn(async move {
        let name = tokio::select! {
            _ = int.recv() => "SIGINT",
            _ = term.recv() => "SIGTERM",
            _ = hup.recv() => "SIGHUP",
        };
        info!("{name}: shutting down");
        let _ = tx.send(true);
    });
    Ok(rx)
}

/// How a session ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionEnd {
    /// Another sender drives this receiver's output: stop, do not redial
    /// (each redial would take the receiver from the other sender).
    LockConflict { held: LockHeld, receiver: String },
    /// Connection dropped or shutdown; redial if allowed.
    Ended,
    /// The receiver said `closing`: do not redial.
    ReceiverClosed,
    /// The display kept vanishing or could not be recreated: stop.
    DisplayLost,
    /// No stream this sender can produce suits the receiver: stop.
    Incompatible,
}

/// Redial delay: doubles from `min` to `max` while sessions keep failing;
/// back to `min` after a session that lasted `healthy`.
pub struct Backoff {
    min: Duration,
    max: Duration,
    healthy: Duration,
    next: Duration,
}

impl Default for Backoff {
    fn default() -> Self {
        Self::new(
            Duration::from_millis(500),
            Duration::from_secs(10),
            Duration::from_secs(30),
        )
    }
}

impl Backoff {
    pub fn new(min: Duration, max: Duration, healthy: Duration) -> Self {
        Self {
            min,
            max,
            healthy,
            next: min,
        }
    }

    /// The delay before the next dial. `lasted` is how long the session
    /// that just ended ran (`None` when the dial itself failed).
    pub fn delay(&mut self, lasted: Option<Duration>) -> Duration {
        if lasted.is_some_and(|l| l >= self.healthy) {
            self.next = self.min;
        }
        let d = self.next;
        self.next = (self.next * 2).min(self.max);
        d
    }
}

/// How a receiver is named in messages: device and id from its `hello`.
fn receiver_label(h: &Hello) -> String {
    match (&h.device, &h.id) {
        (Some(d), Some(id)) => format!("{d} ({id})"),
        (Some(d), None) => d.clone(),
        (None, Some(id)) => id.clone(),
        (None, None) => "this receiver".into(),
    }
}

/// `Some` when the lock `spec` needs is held by another process. Our own
/// display holding it (a rebuild for the same receiver) is no conflict.
fn lock_conflict(
    backend: &dyn Backend,
    active: Option<&Active>,
    spec: &DisplaySpec,
) -> Result<Option<LockHeld>> {
    let name = backend.lock_name(spec);
    if active.is_some_and(|a| backend.lock_name(&a.target.spec) == name) {
        return Ok(None);
    }
    Ok(match lock::try_lock(&name)? {
        Some(_probe) => None,
        None => Some(LockHeld {
            pid: lock::holder_pid(&name),
            name,
        }),
    })
}

/// Before dialing: `Some` when the output for receiver `id` is already
/// driven by another sender.
fn pre_dial_conflict(
    backend: &dyn Backend,
    id: &str,
    position: Position,
) -> Result<Option<LockHeld>> {
    let spec = DisplaySpec {
        name: output_name(Some(id)),
        width: 0,
        height: 0,
        hz: 0,
        scale: 1.0,
        position,
    };
    lock_conflict(backend, None, &spec)
}

/// A lock conflict surfacing from `open` (a sender that started between our
/// check and our open) ends the session like the check would have.
fn conflict_or(e: anyhow::Error, receiver: String) -> Result<SessionEnd> {
    match e.downcast_ref::<LockHeld>() {
        Some(held) => Ok(SessionEnd::LockConflict {
            held: held.clone(),
            receiver,
        }),
        None => Err(e),
    }
}

/// Destination endpoint for a session: network or USB cable.
#[derive(Debug, Clone)]
pub enum Endpoint {
    Network(SocketAddr),
    Usb(Option<u32>),
}

impl std::fmt::Display for Endpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Endpoint::Network(addr) => write!(f, "{addr}"),
            Endpoint::Usb(Some(id)) => write!(f, "USB device {id}"),
            Endpoint::Usb(None) => write!(f, "USB"),
        }
    }
}

pub enum Stream {
    Tcp(TcpStream),
    Unix(tokio::net::UnixStream),
}

impl AsyncRead for Stream {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        match self.get_mut() {
            Stream::Tcp(s) => std::pin::Pin::new(s).poll_read(cx, buf),
            Stream::Unix(s) => std::pin::Pin::new(s).poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for Stream {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        match self.get_mut() {
            Stream::Tcp(s) => std::pin::Pin::new(s).poll_write(cx, buf),
            Stream::Unix(s) => std::pin::Pin::new(s).poll_write(cx, buf),
        }
    }

    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        match self.get_mut() {
            Stream::Tcp(s) => std::pin::Pin::new(s).poll_flush(cx),
            Stream::Unix(s) => std::pin::Pin::new(s).poll_flush(cx),
        }
    }

    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        match self.get_mut() {
            Stream::Tcp(s) => std::pin::Pin::new(s).poll_shutdown(cx),
            Stream::Unix(s) => std::pin::Pin::new(s).poll_shutdown(cx),
        }
    }
}

pub async fn run(endpoint: Endpoint, backend: &mut dyn Backend, opts: RunOptions) -> Result<()> {
    let start = Instant::now();
    info!(
        "backend {}: {} ({})",
        backend.id(),
        backend.describe(),
        backend.caps()
    );
    let mut shutdown = shutdown_signal()?;
    backend.set_cursor_visible(opts.cursor != CursorMode::Off);
    let mut losses = LossBudget::default();
    let mut backoff = Backoff::default();
    if let Some(id) = &opts.receiver_id {
        if let Some(held) = pre_dial_conflict(backend, id, opts.position)? {
            anyhow::bail!("{held} for {}; stop it first", opts.receiver_name);
        }
    }
    loop {
        let mut lasted = None;
        if *shutdown.borrow() || opts.duration.is_some_and(|d| start.elapsed() >= d) {
            break;
        }
        let dial = async {
            match &endpoint {
                Endpoint::Network(addr) => {
                    let s = TcpStream::connect(addr).await?;
                    let _ = s.set_nodelay(true);
                    Ok::<_, anyhow::Error>((Stream::Tcp(s), Some(*addr)))
                }
                Endpoint::Usb(dev_id) => {
                    let s = crate::usbmux::connect(*dev_id).await?;
                    Ok((Stream::Unix(s), None))
                }
            }
        };
        let dialed = tokio::select! {
            r = dial => r,
            _ = shutdown.changed() => break,
        };
        match dialed {
            Ok((stream, peer)) => {
                info!("connected to receiver {endpoint}");
                let began = Instant::now();
                let end = session(
                    stream,
                    backend,
                    &opts,
                    start,
                    shutdown.clone(),
                    &mut losses,
                    peer,
                )
                .await;
                lasted = Some(began.elapsed());
                match end {
                    Ok(SessionEnd::LockConflict { held, receiver }) => {
                        anyhow::bail!("{held} for {receiver}; stop it first");
                    }
                    Ok(SessionEnd::ReceiverClosed) => {
                        info!("receiver closed the session for good");
                        break;
                    }
                    Ok(SessionEnd::Incompatible) => {
                        warn!("giving up: the receiver accepts no stream this sender can produce");
                        break;
                    }
                    Ok(SessionEnd::DisplayLost) => {
                        warn!("giving up: the virtual display could not be kept alive");
                        break;
                    }
                    Ok(SessionEnd::Ended) => info!("connection ended"),
                    Err(e) => warn!("session error: {e:#}"),
                }
            }
            Err(e) => warn!("dial {endpoint}: {e}"),
        }
        if !opts.reconnect || *shutdown.borrow() {
            break;
        }
        let delay = backoff.delay(lasted);
        debug!("redialing in {delay:?}");
        tokio::select! {
            _ = tokio::time::sleep(delay) => {}
            _ = shutdown.changed() => break,
        }
    }
    Ok(())
}

enum DisplayEvent {
    Encoded(Encoded),
    Lost(String),
}

async fn next_display_event(active: &mut Option<Active>) -> DisplayEvent {
    let Some(a) = active else {
        return std::future::pending().await;
    };
    tokio::select! {
        Some(e) = a.pipe.encoded_rx.recv() => DisplayEvent::Encoded(e),
        Some(why) = a.pipe.lost_rx.recv() => DisplayEvent::Lost(why),
        // Encoder gone and capture silent: nothing more will come.
        else => std::future::pending().await,
    }
}

async fn send_stream_config<S: AsyncWrite + Unpin>(
    stream: &mut S,
    sess: &SenderSession,
    plan: &StreamPlan,
) -> Result<()> {
    let cfg = sess.stream_config(StreamConfig {
        codec: plan.codec.into(),
        width: plan.width,
        height: plan.height,
        frames_per_second: plan.fps,
    });
    if let SenderAction::Send(b) = cfg {
        stream.write_all(&b).await.context("write")?;
    }
    Ok(())
}

/// A cursor event as the messages for the receiver.
fn cursor_out(sess: &mut SenderSession, now: Now, ev: CursorEvent) -> Vec<SenderAction> {
    match ev {
        CursorEvent::Moved { x, y } => sess.cursor(now, x, y, true),
        CursorEvent::Hidden => sess.cursor(now, 0.0, 0.0, false),
        CursorEvent::Image {
            png,
            nw,
            nh,
            ax,
            ay,
        } => {
            vec![sess.cursor_image(CursorImg {
                nw,
                nh,
                ax,
                ay,
                png: base64(&png),
            })]
        }
        CursorEvent::SpriteUnavailable(_) => vec![],
    }
}

/// A drift probe running on a blocking thread, for the display `build`
/// generation it was taken from.
type DriftCheck = (u64, tokio::task::JoinHandle<Option<String>>);

/// The result of the running drift probe; pending while none runs.
/// Cancel-safe: the slot is cleared only once the probe has finished.
async fn drift_done(slot: &mut Option<DriftCheck>) -> (u64, Option<String>) {
    let Some((_, probe)) = slot.as_mut() else {
        return std::future::pending().await;
    };
    let why = probe.await.unwrap_or(None);
    let (generation, _) = slot.take().expect("checked above");
    (generation, why)
}

async fn sleep_until_opt(at: Option<Instant>) {
    match at {
        Some(at) => tokio::time::sleep_until(at.into()).await,
        None => std::future::pending().await,
    }
}

/// Build the display for `target` and announce its stream.
async fn apply<S: AsyncWrite + Unpin>(
    stream: &mut S,
    sess: &SenderSession,
    backend: &mut dyn Backend,
    active: &mut Option<Active>,
    target: Target,
    opts: &RunOptions,
    cursor: Option<&mpsc::UnboundedSender<CursorEvent>>,
) -> Result<()> {
    info!("plan: {}", target.plan);
    let position = target.spec.position;
    let plan = build(backend, active, target, opts, cursor)?;
    if let (Some(a), Some(h)) = (active.as_ref(), sess.hello()) {
        info!(
            "{}",
            extending_line(&receiver_label(h), a.display.info(), position)
        );
    }
    send_stream_config(stream, sess, &plan).await
}

/// The one plain-language line a user looks for after `run`.
fn extending_line(receiver: &str, info: &DisplayInfo, position: Position) -> String {
    let scale = info.scale.max(0.1);
    let (lw, lh) = (
        (info.width as f64 / scale).round(),
        (info.height as f64 / scale).round(),
    );
    let place = match position {
        Position::AutoRight => "right of your other displays".to_string(),
        Position::AutoLeft => "left of your other displays".to_string(),
        Position::AutoUp => "above your other displays".to_string(),
        Position::AutoDown => "below your other displays".to_string(),
        Position::At(x, y) => format!("at {x},{y}"),
    };
    let scale = format!("{:.2}", info.scale);
    let scale = scale.trim_end_matches('0').trim_end_matches('.');
    format!(
        "Extending onto {receiver}: {lw}x{lh} logical at {scale}x ({}, {place}). Ctrl+C to stop.",
        info.name
    )
}

async fn session<S: AsyncRead + AsyncWrite + Unpin>(
    mut stream: S,
    backend: &mut dyn Backend,
    opts: &RunOptions,
    start: Instant,
    mut shutdown: watch::Receiver<bool>,
    losses: &mut LossBudget,
    peer: Option<SocketAddr>,
) -> Result<SessionEnd> {
    let mut config = SenderConfig::default();
    if peer.is_none() {
        // Must be false on the USB binding (§6.3).
        config.use_cursor_udp = false;
    }
    let mut sess = SenderSession::new(config);
    // Cursor events from the display's cursor thread, and the UDP socket for
    // the side channel (bound on the first datagram).
    let (cursor_tx, mut cursor_rx) = mpsc::unbounded_channel::<CursorEvent>();
    // One warning per session when the side channel cannot be used.
    let mut cursor_warned = false;
    let mut udp: Option<tokio::net::UdpSocket> = None;
    let cursor_for = |opts: &RunOptions, backend: &dyn Backend, sess: &SenderSession| {
        let offers = sess.hello().is_some_and(|h| h.cursor_port.is_some());
        cursor_separately(opts.cursor, backend.caps().cursor_metadata, offers)
            .then(|| cursor_tx.clone())
    };
    sess.handle(now(start), SenderEvent::Connected);
    let mut active: Option<Active> = None;
    // `opts` with this receiver's config table applied, once its hello names it.
    let mut ropts = opts.clone();
    let mut debounce: Debounce<Target> = Debounce::new(desktop::HELLO_DEBOUNCE);
    // Restores after the compositor changed the display behind our back; past
    // the budget the sender stops fighting and leaves it as configured.
    let mut drifts = LossBudget::default();
    let mut drift_given_up = false;
    // Compositor IPC: off the session thread, one at a time.
    let mut drift_check: Option<DriftCheck> = None;
    let mut buf = vec![0u8; 64 * 1024];
    let mut tick = tokio::time::interval(Duration::from_millis(100));
    let mut stats_tick = tokio::time::interval(Duration::from_secs(5));
    stats_tick.reset();
    let (mut win_frames, mut win_bytes, mut win_enc_ms, mut win_lat_ms) =
        (0u64, 0u64, Vec::<f64>::new(), Vec::<f64>::new());

    let result: Result<SessionEnd> = async {
        loop {
            let actions: Vec<SenderAction> = tokio::select! {
                _ = shutdown.changed() => return Ok(SessionEnd::Ended),
                r = stream.read(&mut buf) => {
                    let n = r.context("read")?;
                    if n == 0 { return Ok(SessionEnd::Ended); }
                    sess.handle(now(start), SenderEvent::Bytes(&buf[..n]))
                }
                ev = next_display_event(&mut active) => match ev {
                    DisplayEvent::Encoded(enc) => {
                        let n = now(start);
                        let cap_wall = n.wall_ms - enc.captured_at.elapsed().as_secs_f64() * 1000.0;
                        let a = sess.push_encoded_frame(n, &enc.unit.annexb, enc.unit.is_idr, Some(cap_wall));
                        if !a.is_empty() {
                            win_frames += 1;
                            win_bytes += enc.unit.annexb.len() as u64;
                            win_enc_ms.push(enc.encode_ms);
                            win_lat_ms.push(enc.captured_at.elapsed().as_secs_f64() * 1000.0);
                        }
                        a
                    }
                    DisplayEvent::Lost(why) => {
                        let target = active.as_ref().map(|a| a.target.clone()).expect("lost implies active");
                        let name = target.spec.name.clone();
                        warn!("virtual display {name} lost: {why}");
                        if !losses.allow(Instant::now()) {
                            warn!("{name} lost too often; closing the connection");
                            return Ok(SessionEnd::DisplayLost);
                        }
                        let cur = cursor_for(&ropts, backend, &sess);
                        match build(backend, &mut active, target, &ropts, cur.as_ref()) {
                            Ok(plan) => {
                                info!("recreated virtual display {name}");
                                send_stream_config(&mut stream, &sess, &plan).await?;
                            }
                            Err(e) => {
                                warn!("cannot recreate the virtual display: {e:#}; closing the connection");
                                return Ok(SessionEnd::DisplayLost);
                            }
                        }
                        vec![]
                    }
                },
                Some(ev) = cursor_rx.recv() => {
                    let Some(a) = active.as_mut() else { continue };
                    let (next, action) = cursor_step(a.cursor, &ev);
                    a.cursor = next;
                    let mut out = Vec::new();
                    match action {
                        CursorAction::Ignore => {}
                        CursorAction::Hold => {
                            a.held_position = match ev {
                                CursorEvent::Moved { x, y } => Some((x, y)),
                                _ => None,
                            };
                        }
                        CursorAction::GoLive => match a.display.set_cursor_painted(false) {
                            Ok(()) => {
                                info!("cursor: side channel live, video without the cursor");
                                out.extend(cursor_out(&mut sess, now(start), ev));
                                if let Some((x, y)) = a.held_position.take() {
                                    out.extend(sess.cursor(now(start), x, y, true));
                                }
                            }
                            Err(e) => {
                                a.cursor = CursorSide::Failed;
                                if !cursor_warned {
                                    cursor_warned = true;
                                    warn!("cursor side channel unusable ({e:#}); the cursor stays in the video");
                                }
                            }
                        },
                        CursorAction::Forward => out.extend(cursor_out(&mut sess, now(start), ev)),
                        CursorAction::Fail => {
                            if let Err(e) = a.display.set_cursor_painted(true) {
                                warn!("painting the cursor again: {e:#}");
                            }
                            // The receiver may be drawing it: hide it there.
                            out.extend(sess.cursor(now(start), 0.0, 0.0, false));
                            if !cursor_warned {
                                cursor_warned = true;
                                if let CursorEvent::SpriteUnavailable(why) = &ev {
                                    warn!("cursor side channel off ({why}); the cursor stays in the video");
                                }
                            }
                        }
                    }
                    out
                }
                _ = sleep_until_opt(debounce.deadline()) => {
                    if let Some(t) = debounce.poll(Instant::now()) {
                        let cur = cursor_for(&ropts, backend, &sess);
                        if let Err(e) = apply(&mut stream, &sess, backend, &mut active, t, &ropts, cur.as_ref()).await {
                            return conflict_or(e, sess.hello().map_or_else(|| "this receiver".into(), receiver_label));
                        }
                    }
                    vec![]
                }
                _ = tick.tick() => {
                    if opts.duration.is_some_and(|d| start.elapsed() >= d) { return Ok(SessionEnd::Ended); }
                    if !drift_given_up && drift_check.is_none() {
                        if let Some(a) = active.as_mut() {
                            if let Some(probe) = a.display.drift_probe() {
                                drift_check = Some((a.generation, tokio::task::spawn_blocking(probe)));
                            }
                        }
                    }
                    sess.handle(now(start), SenderEvent::Tick)
                }
                (generation, why) = drift_done(&mut drift_check) => {
                    // A rebuild since the probe started makes its answer stale.
                    let current = active.as_ref().is_some_and(|a| a.generation == generation);
                    if let Some(why) = why.filter(|_| current && !drift_given_up) {
                        let target = active.as_ref().map(|a| a.target.clone()).expect("drift implies active");
                        let spec = &target.spec;
                        if drifts.allow(Instant::now()) {
                            info!(
                                "{why}: restoring {} to {}x{} @{} scale {} ({:?})",
                                spec.name, spec.width, spec.height, spec.hz, spec.scale, spec.position
                            );
                            let cur = cursor_for(&ropts, backend, &sess);
                            match build(backend, &mut active, target, &ropts, cur.as_ref()) {
                                Ok(plan) => send_stream_config(&mut stream, &sess, &plan).await?,
                                Err(e) => {
                                    warn!("cannot restore the virtual display: {e:#}; closing the connection");
                                    return Ok(SessionEnd::DisplayLost);
                                }
                            }
                        } else {
                            drift_given_up = true;
                            warn!("{why}: {} keeps changing; leaving it as the compositor configured it", spec.name);
                        }
                    }
                    vec![]
                }
                _ = stats_tick.tick() => {
                    win_enc_ms.sort_by(f64::total_cmp);
                    win_lat_ms.sort_by(f64::total_cmp);
                    let p = |v: &[f64], q: f64| v.get(((v.len() as f64 - 1.0) * q).round() as usize).copied().unwrap_or(0.0);
                    info!(
                        "sent {:.1} fps {:.1} Mbit/s | encode p50 {:.1} ms p95 {:.1} ms | capture->send p50 {:.1} ms p95 {:.1} ms | {:?}",
                        win_frames as f64 / 5.0, win_bytes as f64 * 8.0 / 5.0 / 1e6,
                        p(&win_enc_ms, 0.5), p(&win_enc_ms, 0.95), p(&win_lat_ms, 0.5), p(&win_lat_ms, 0.95), sess.counters
                    );
                    win_frames = 0; win_bytes = 0; win_enc_ms.clear(); win_lat_ms.clear();
                    vec![]
                }
            };
            let mut apply_now: Option<(Target, String)> = None;
            for a in actions {
                match a {
                    SenderAction::Send(bytes) => stream.write_all(&bytes).await.context("write")?,
                    SenderAction::SendCursorDatagram(d) => {
                        if let (Some(peer), Some(port)) = (peer, sess.cursor_udp_port()) {
                            if udp.is_none() {
                                let any: SocketAddr = if peer.is_ipv4() { ([0, 0, 0, 0], 0).into() } else { ([0u16; 8], 0).into() };
                                udp = tokio::net::UdpSocket::bind(any).await.map_err(|e| warn!("cursor UDP socket: {e}")).ok();
                            }
                            if let Some(u) = &udp {
                                // Latest wins: a full socket buffer drops this one.
                                let _ = u.try_send_to(&d, SocketAddr::new(peer.ip(), port));
                            }
                        }
                    }
                    SenderAction::Hello(h) => {
                        info!(
                            "hello: {}x{} @{} scale {} device {:?} id {:?} pv {}",
                            h.pixels_wide, h.pixels_high, h.display_max_frame_rate.unwrap_or(60), h.scale, h.device, h.id, sess.receiver_pv()
                        );
                        ropts = opts.for_receiver(&[
                            h.id.as_deref(),
                            Some(opts.receiver_name.as_str()),
                            h.device.as_deref(),
                        ]);
                        let t = match target(&h, &ropts) {
                            Ok(t) => t,
                            Err(e) => {
                                warn!("cannot plan a desktop for this receiver: {e}; closing the connection");
                                return Ok(SessionEnd::Incompatible);
                            }
                        };
                        // Before `welcome` (it follows `Hello` in this batch):
                        // a receiver another sender drives is left alone.
                        if let Some(held) = lock_conflict(backend, active.as_ref(), &t.spec)? {
                            return Ok(SessionEnd::LockConflict { held, receiver: receiver_label(&h) });
                        }
                        // The first plan applies at once; re-sent hellos settle first (§6.1).
                        // At once means after this batch: `welcome` (and any
                        // `updateRequired`) go out before the streamConfig.
                        if let Some(t) = debounce.on_hello(t, Instant::now()) {
                            apply_now = Some((t, receiver_label(&h)));
                        }
                    }
                    SenderAction::RequestKeyframe => {
                        if let Some(a) = &active {
                            a.pipe.force_idr.store(true, Ordering::Relaxed);
                        }
                    }
                    SenderAction::Touch(t) => {
                        debug!("touch {:?} {:.3},{:.3}", t.phase, t.x, t.y);
                        if let Some(i) = active.as_mut().and_then(|a| a.input.as_mut()) {
                            i.touch(&t);
                        }
                    }
                    SenderAction::Scroll(s) => {
                        debug!("scroll {} {}", s.dx, s.dy);
                        if let Some(i) = active.as_mut().and_then(|a| a.input.as_mut()) {
                            i.scroll(&s);
                        }
                    }
                    SenderAction::Pencil(p) => {
                        if let Some(i) = active.as_mut().and_then(|a| a.input.as_mut()) {
                            i.pencil(&p);
                        }
                    }
                    SenderAction::Proximity(_) => {}
                    SenderAction::Stats(v) => info!("PHONE-STATS {v}"),
                    SenderAction::ReceiverSleeping => info!("receiver sleeping"),
                    SenderAction::ReceiverClosing => return Ok(SessionEnd::ReceiverClosed),
                    SenderAction::Close(reason) => {
                        warn!("closing: {reason:?}");
                        return Ok(SessionEnd::Ended);
                    }
                    SenderAction::Warn(m) => warn!("{m}"),
                }
            }
            if !sess.is_connected() {
                return Ok(SessionEnd::Ended);
            }
            if let Some((t, receiver)) = apply_now {
                let cur = cursor_for(&ropts, backend, &sess);
                if let Err(e) = apply(&mut stream, &sess, backend, &mut active, t, &ropts, cur.as_ref()).await {
                    return conflict_or(e, receiver);
                }
            }
        }
    }
    .await;

    if let Some(a) = active.take() {
        a.close(opts.keep_output);
    }
    result
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use opendisplay_session::receiver::{
        ReceiverAction, ReceiverConfig, ReceiverEvent, ReceiverSession,
    };

    use super::*;
    use crate::backend::{BackendId, Caps};

    #[test]
    fn output_names_are_safe_for_ipc_lua_and_paths() {
        // A UUID keeps its readable prefix, as before.
        assert_eq!(
            output_name(Some("3F31ED2A-0C1B-4D6E-9F00-123456789ABC")),
            "od-3f31ed"
        );
        assert_eq!(output_name(None), "od-anon");
        assert_eq!(output_name(Some("")), "od-anon");
        for hostile in [
            "\"})--x",
            "a b c d e f",
            "../../x",
            "ab\ncd\nef",
            "ÄÖÜäöü",
            "abc",
        ] {
            let n = output_name(Some(hostile));
            let suffix = n.strip_prefix("od-").unwrap();
            assert_eq!(suffix.len(), 6, "{hostile:?} -> {n}");
            assert!(
                suffix
                    .bytes()
                    .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()),
                "{hostile:?} -> {n}"
            );
        }
        // Stable across runs and builds (the lock key depends on it), and
        // ids differing after the prefix are told apart when hashed.
        assert_eq!(output_name(Some("a b c")), output_name(Some("a b c")));
        assert_ne!(output_name(Some("a b c1")), output_name(Some("a b c2")));
    }

    fn opts() -> RunOptions {
        RunOptions {
            bitrate_mbps: 20.0,
            desktop: DesktopOptions::default(),
            threads: 1,
            encoder: crate::encoder::Backend::Auto,
            cursor: CursorMode::Auto,
            position: Position::AutoRight,
            workspace: None,
            keep_output: false,
            reconnect: false,
            duration: None,
            receiver_id: None,
            receiver_name: "test".into(),
            cli: Layer::default(),
            config: Config::default(),
        }
    }

    fn hello() -> Hello {
        Hello {
            pixels_wide: 2532,
            pixels_high: 1170,
            scale: 3.0,
            device: Some("iPhone".into()),
            id: Some("3F9A1C77-0000".into()),
            display_max_frame_rate: Some(120),
            ..Default::default()
        }
    }

    #[test]
    fn target_names_the_output_after_the_receiver() {
        let t = target(&hello(), &opts()).unwrap();
        assert_eq!(t.spec.name, "od-3f9a1c");
        assert_eq!(
            (t.spec.width, t.spec.height, t.spec.hz),
            (t.plan.output.width, t.plan.output.height, t.plan.output.hz)
        );
        let anon = target(
            &Hello {
                id: None,
                ..hello()
            },
            &opts(),
        )
        .unwrap();
        assert_eq!(anon.spec.name, "od-anon");
    }

    #[test]
    fn adopted_outputs_stream_at_their_own_size() {
        let t = target(&hello(), &opts()).unwrap();
        let mut info = info_of(&t.spec);
        assert_eq!(stream_for(&info, &t), t.plan.stream);
        (info.width, info.height) = (1921, 1080);
        let s = stream_for(&info, &t);
        assert_eq!((s.width, s.height, s.fps), (1920, 1080, t.plan.stream.fps));
    }

    #[test]
    fn loss_budget_allows_three_per_minute() {
        let mut b = LossBudget::default();
        let t = Instant::now();
        assert!(b.allow(t));
        assert!(b.allow(t + Duration::from_secs(1)));
        assert!(b.allow(t + Duration::from_secs(2)));
        assert!(!b.allow(t + Duration::from_secs(3)));
        // The oldest ones age out.
        assert!(b.allow(t + Duration::from_secs(120)));
    }

    /// What the fake backend records, plus the capture sink so a test can
    /// end capture the way a removed output does.
    #[derive(Clone, Default)]
    struct Shared {
        log: Arc<Mutex<Vec<String>>>,
        sink: Arc<Mutex<Option<FrameSink>>>,
        fail_reconfigure: Arc<AtomicBool>,
        panic_on_input: Arc<AtomicBool>,
        /// Reported once by the next drift probe while a display exists.
        drift: Arc<Mutex<Option<String>>>,
        /// How long that probe blocks, like IPC to a slow compositor.
        drift_delay: Arc<Mutex<Duration>>,
        /// The size of the display being captured.
        capture_size: Arc<Mutex<(u32, u32)>>,
        cursor_sink: Arc<Mutex<Option<crate::backend::CursorSink>>>,
        painted: Arc<Mutex<Option<bool>>>,
    }

    impl Shared {
        fn log(&self, s: impl Into<String>) {
            self.log.lock().unwrap().push(s.into());
        }
        fn entries(&self) -> Vec<String> {
            self.log.lock().unwrap().clone()
        }
    }

    struct FakeBackend(Shared);
    /// The third field: `close` ran.
    struct FakeDisplay(Shared, DisplayInfo, bool);

    impl Drop for FakeDisplay {
        fn drop(&mut self) {
            if !self.2 {
                self.0.log("dropped without close");
            }
        }
    }
    struct FakeInput;

    impl InputSink for FakeInput {
        fn touch(&mut self, _: &opendisplay_proto::control::Touch) {}
        fn scroll(&mut self, _: &opendisplay_proto::control::Scroll) {}
    }

    fn info_of(spec: &DisplaySpec) -> DisplayInfo {
        DisplayInfo {
            name: spec.name.clone(),
            width: spec.width,
            height: spec.height,
            refresh_hz: spec.hz as f64,
            scale: spec.scale,
            x: 0,
            y: 0,
        }
    }

    impl Backend for FakeBackend {
        fn set_capture(&mut self, _: crate::backend::capture::CapturePath) {}
        fn id(&self) -> BackendId {
            BackendId::Adopt
        }
        fn describe(&self) -> String {
            "fake".into()
        }
        fn caps(&self) -> Caps {
            Caps {
                cursor_metadata: true,
                dmabuf: false,
                resize_in_place: true,
                creates_outputs: true,
            }
        }
        fn open(&mut self, spec: &DisplaySpec) -> Result<Box<dyn VirtualDisplay>> {
            self.0.log(format!("open {}", spec.name));
            Ok(Box::new(FakeDisplay(self.0.clone(), info_of(spec), false)))
        }
        fn clean(&mut self) -> Result<Vec<String>> {
            Ok(vec![])
        }
    }

    impl VirtualDisplay for FakeDisplay {
        fn drift_probe(&mut self) -> Option<crate::backend::DriftProbe> {
            let why = self.0.drift.lock().unwrap().take()?;
            let delay = *self.0.drift_delay.lock().unwrap();
            Some(Box::new(move || {
                std::thread::sleep(delay);
                Some(why)
            }))
        }
        fn info(&self) -> &DisplayInfo {
            &self.1
        }
        fn start_cursor(&mut self, sink: crate::backend::CursorSink) -> Result<()> {
            self.0.log("start_cursor");
            *self.0.cursor_sink.lock().unwrap() = Some(sink);
            Ok(())
        }
        fn set_cursor_painted(&mut self, painted: bool) -> Result<()> {
            *self.0.painted.lock().unwrap() = Some(painted);
            self.0.log(format!("set_cursor_painted {painted}"));
            Ok(())
        }
        fn start_capture(&mut self, o: CaptureOptions, sink: FrameSink) -> Result<()> {
            *self.0.painted.lock().unwrap() = Some(o.cursor);
            *self.0.capture_size.lock().unwrap() = (self.1.width, self.1.height);
            if self.0.cursor_sink.lock().unwrap().is_some() {
                self.0.log(format!("start_capture painted={}", o.cursor));
            } else {
                self.0.log("start_capture");
            }
            *self.0.sink.lock().unwrap() = Some(sink);
            Ok(())
        }
        fn stop_capture(&mut self) {
            if self.0.sink.lock().unwrap().take().is_some() {
                self.0.log("stop_capture");
            }
        }
        fn reconfigure(&mut self, spec: &DisplaySpec) -> Result<()> {
            self.stop_capture();
            self.0.log("reconfigure");
            if self.0.fail_reconfigure.load(Ordering::Relaxed) {
                anyhow::bail!("output is gone for good");
            }
            self.1 = info_of(spec);
            Ok(())
        }
        fn input(&mut self) -> Result<Box<dyn InputSink>> {
            if self.0.panic_on_input.load(Ordering::Relaxed) {
                panic!("injected panic in the session");
            }
            Ok(Box::new(FakeInput))
        }
        fn close(mut self: Box<Self>, keep_output: bool) -> Result<()> {
            self.2 = true;
            self.stop_capture();
            self.0.log(format!("close keep={keep_output}"));
            Ok(())
        }
    }

    /// A receiver `hello` whose output name is unique to `tag` and this
    /// process, because sessions probe the real lock directory and tests run
    /// in parallel. Returns the hello and the output name.
    fn test_hello(tag: &str) -> (Hello, String) {
        let id = format!("{tag}{:06x}-test", std::process::id());
        let name = output_name(Some(&id));
        (
            Hello {
                id: Some(id),
                ..hello()
            },
            name,
        )
    }

    fn forget_lock(name: &str) {
        let _ = std::fs::remove_file(lock::dir().join(format!("{name}.lock")));
    }

    /// Drive one session against a `ReceiverSession` over an in-memory pipe.
    /// After each `streamConfig`, capture ends like an output removed under
    /// it, `losses` times; then the receiver hangs up. Returns the backend
    /// log, the receiver's actions and how the session ended.
    async fn drive(
        hello: Hello,
        losses: usize,
        fail_reconfigure: bool,
    ) -> (Vec<String>, Vec<ReceiverAction>, SessionEnd) {
        let shared = Shared::default();
        shared
            .fail_reconfigure
            .store(fail_reconfigure, Ordering::Relaxed);
        drive_with(shared, hello, losses).await
    }

    async fn drive_with(
        shared: Shared,
        hello: Hello,
        losses: usize,
    ) -> (Vec<String>, Vec<ReceiverAction>, SessionEnd) {
        let (sender_io, mut receiver_io) = tokio::io::duplex(1 << 16);
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);
        let mut backend = FakeBackend(shared.clone());
        let session_task = tokio::spawn(async move {
            let mut budget = LossBudget::default();
            session(
                sender_io,
                &mut backend,
                &opts(),
                Instant::now(),
                shutdown_rx,
                &mut budget,
                None,
            )
            .await
        });

        let mut rx = ReceiverSession::new(ReceiverConfig::new(hello));
        let rx_now = || Now::new(Duration::from_secs(1), 1e6);
        for a in rx.handle(rx_now(), ReceiverEvent::Connected) {
            if let ReceiverAction::Send(b) = a {
                receiver_io.write_all(&b).await.unwrap();
            }
        }
        let mut seen = Vec::new();
        let mut buf = vec![0u8; 1 << 16];
        let mut lost = 0;
        loop {
            let n = tokio::time::timeout(Duration::from_secs(5), receiver_io.read(&mut buf))
                .await
                .expect("sender went quiet")
                .unwrap();
            if n == 0 {
                break;
            }
            for a in rx.handle(rx_now(), ReceiverEvent::Bytes(&buf[..n])) {
                let config = matches!(a, ReceiverAction::StreamConfig(_));
                seen.push(a);
                if !config {
                    continue;
                }
                if lost == losses {
                    drop(receiver_io);
                    let end = session_task.await.unwrap().unwrap();
                    return (shared.entries(), seen, end);
                }
                lost += 1;
                let mut sink = shared.sink.lock().unwrap().take().expect("capturing");
                sink(CaptureEvent::Ended("output removed".into()));
            }
        }
        let end = session_task.await.unwrap().unwrap();
        (shared.entries(), seen, end)
    }

    async fn lose_display(
        tag: &str,
        losses: usize,
        fail_reconfigure: bool,
    ) -> (Vec<String>, SessionEnd, String) {
        let (hello, name) = test_hello(tag);
        let (log, _, end) = drive(hello, losses, fail_reconfigure).await;
        forget_lock(&name);
        (log, end, name)
    }

    /// §9's sequence: `welcome` answers the first `hello` before the display
    /// is built and its streamConfig sent.
    #[tokio::test]
    async fn welcome_goes_out_before_the_first_stream_config() {
        let (hello, name) = test_hello("wf");
        let (_, seen, _) = drive(hello, 0, false).await;
        forget_lock(&name);
        let at = |f: fn(&ReceiverAction) -> bool| seen.iter().position(f).expect("present");
        let welcome = at(|a| matches!(a, ReceiverAction::Welcome(_)));
        let config = at(|a| matches!(a, ReceiverAction::StreamConfig(_)));
        assert!(welcome < config, "{seen:?}");
    }

    #[tokio::test]
    async fn a_lost_display_is_recreated_from_the_last_plan() {
        let (log, end, name) = lose_display("la", 1, false).await;
        assert_eq!(end, SessionEnd::Ended);
        assert_eq!(
            log,
            [
                format!("open {name}").as_str(),
                "start_capture",
                "reconfigure",
                "start_capture",
                "stop_capture",
                "close keep=false",
            ]
        );
    }

    #[tokio::test]
    async fn a_display_lost_too_often_ends_the_run() {
        let (log, end, _) = lose_display("lb", 4, false).await;
        assert_eq!(end, SessionEnd::DisplayLost);
        assert_eq!(log.iter().filter(|l| *l == "reconfigure").count(), 3);
        assert_eq!(log.last().unwrap(), "close keep=false");
    }

    #[tokio::test]
    async fn a_display_that_cannot_be_recreated_ends_the_run() {
        let (log, end, name) = lose_display("lc", 1, true).await;
        assert_eq!(end, SessionEnd::DisplayLost);
        assert_eq!(
            log,
            [
                format!("open {name}").as_str(),
                "start_capture",
                "reconfigure",
                // Dropped on the error path: a real display removes its output.
                "dropped without close"
            ]
        );
    }

    #[tokio::test]
    async fn a_receiver_another_sender_drives_is_left_before_welcome() {
        let (hello, name) = test_hello("lk");
        // The other sender; within one process a second open file is a
        // second lock holder, as another process would be.
        let other = lock::lock_output(&name).unwrap();
        let (log, seen, end) = drive(hello, 0, false).await;
        drop(other);
        forget_lock(&name);
        match end {
            SessionEnd::LockConflict { held, receiver } => {
                assert_eq!(held.name, name);
                assert_eq!(held.pid, Some(std::process::id()));
                assert!(receiver.starts_with("iPhone ("), "{receiver}");
            }
            e => panic!("expected a lock conflict, got {e:?}"),
        }
        assert!(log.is_empty(), "nothing opened: {log:?}");
        assert!(
            !seen.iter().any(|a| matches!(a, ReceiverAction::Welcome(_))),
            "welcome must not be sent: {seen:?}"
        );
    }

    #[test]
    fn a_held_receiver_is_found_before_dialing() {
        let (hello, name) = test_hello("pd");
        let id = hello.id.unwrap();
        let backend = FakeBackend(Shared::default());
        assert_eq!(
            pre_dial_conflict(&backend, &id, Position::AutoRight).unwrap(),
            None
        );
        let other = lock::lock_output(&name).unwrap();
        let held = pre_dial_conflict(&backend, &id, Position::AutoRight)
            .unwrap()
            .expect("conflict");
        assert_eq!(held.name, name);
        drop(other);
        forget_lock(&name);
    }

    #[tokio::test]
    async fn a_panicking_pipeline_thread_reports_a_lost_display() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let h = spawn_reporting_panics("encode", tx, || panic!("injected")).unwrap();
        assert!(h.join().is_err());
        assert_eq!(rx.recv().await.as_deref(), Some("encode thread panicked"));
        // A thread that returns normally reports nothing.
        let (tx, mut rx) = mpsc::unbounded_channel();
        spawn_reporting_panics("encode", tx, || {})
            .unwrap()
            .join()
            .unwrap();
        assert_eq!(rx.recv().await, None);
    }

    #[tokio::test]
    async fn a_panic_in_the_session_still_drops_the_display() {
        let (hello, name) = test_hello("pn");
        let shared = Shared::default();
        shared.panic_on_input.store(true, Ordering::Relaxed);
        let log = shared.clone();
        let r = tokio::spawn(drive_with(shared, hello, 0)).await;
        forget_lock(&name);
        assert!(r.is_err_and(|e| e.is_panic()));
        // Dropping a real display stops capture and then removes the output
        // (wayland::display tests); here: it was dropped, not leaked.
        assert_eq!(
            log.entries(),
            [
                format!("open {name}").as_str(),
                "start_capture",
                "dropped without close"
            ]
        );
    }

    #[test]
    fn receiver_tables_apply_under_the_command_line() {
        let (hello, _) = test_hello("cf");
        let id = hello.id.clone().unwrap();
        let config = Config::parse(&format!(
            "scale = \"mac\"\nbitrate-mbps = 12\n[receiver.\"{id}\"]\nposition = \"auto-left\"\nscale = 2\nbitrate-mbps = 30\n"
        ))
        .unwrap();
        let base = RunOptions {
            cli: Layer {
                bitrate_mbps: Some(8.0),
                ..Layer::default()
            },
            config,
            ..opts()
        };
        let r = base.for_receiver(&[hello.id.as_deref(), Some("test"), Some("iPhone")]);
        assert_eq!(r.position, Position::AutoLeft);
        assert_eq!(r.desktop.scale, crate::desktop::ScalePolicy::Fixed(2.0));
        assert_eq!(r.bitrate_mbps, 8.0, "the command line wins");
        let t = target(&hello, &r).unwrap();
        assert_eq!((t.spec.scale, t.spec.position), (2.0, Position::AutoLeft));
        // Another receiver gets the options as they were.
        let other = base.for_receiver(&[Some("someone-else"), None, None]);
        assert_eq!(other.position, base.position);
    }

    #[test]
    fn the_cursor_goes_separately_only_when_everyone_can() {
        assert!(cursor_separately(CursorMode::Auto, true, true));
        assert!(!cursor_separately(CursorMode::Auto, false, true));
        assert!(!cursor_separately(CursorMode::Auto, true, false));
        assert!(!cursor_separately(CursorMode::Video, true, true));
        assert!(!cursor_separately(CursorMode::Off, true, true));
    }

    /// A session with a receiver offering `cursorPort`: after its first
    /// `streamConfig`, `events` come from the display's cursor thread. Returns
    /// the receiver's cursor messages (cursor, cursorImg) in order, and the
    /// fake's shared state.
    /// The compositor changed the display (a Hyprland config reload): the
    /// session rebuilds it from the same spec and announces the stream again.
    /// One captured frame of the display's size, as a compositor delivers it.
    fn push_frame(shared: &Shared, shade: u8) -> bool {
        let (w, h) = *shared.capture_size.lock().unwrap();
        let mut sink = shared.sink.lock().unwrap();
        let Some(sink) = sink.as_mut() else {
            return false;
        };
        sink(CaptureEvent::Frame(crate::backend::Frame {
            captured_at: Instant::now(),
            presentation_ns: None,
            buf: crate::backend::FrameBuf::Cpu {
                pixels: crate::backend::Pixels::Owned(vec![shade; (w * h * 4) as usize]),
                width: w,
                height: h,
                stride: w * 4,
                format: crate::backend::PixelFormat::Xrgb8888,
            },
        }));
        true
    }

    /// A small receiver, so the real encoder in these tests stays quick.
    fn small_hello(tag: &str) -> (Hello, String) {
        let (h, name) = test_hello(tag);
        (
            Hello {
                pixels_wide: 640,
                pixels_high: 360,
                scale: 1.0,
                display_max_frame_rate: Some(60),
                ..h
            },
            name,
        )
    }

    /// The whole session against the stub backend over an in-memory pipe,
    /// with the real encoder: hello, build, streamConfig, an IDR reaching
    /// the receiver; the output lost and rebuilt with a new streamConfig
    /// and IDR; then the receiver's `closing` ends the run and the display
    /// is closed.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_session_streams_rebuilds_and_ends_on_closing() {
        let (hello, name) = small_hello("e2");
        let shared = Shared::default();
        let (sender_io, mut receiver_io) = tokio::io::duplex(1 << 20);
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);
        let mut backend = FakeBackend(shared.clone());
        let task = tokio::spawn(async move {
            let mut budget = LossBudget::default();
            let o = RunOptions {
                encoder: crate::encoder::Backend::Openh264,
                ..opts()
            };
            session(
                sender_io,
                &mut backend,
                &o,
                Instant::now(),
                shutdown_rx,
                &mut budget,
                None,
            )
            .await
        });
        let mut rx = ReceiverSession::new(ReceiverConfig::new(hello));
        let rx_now = || Now::new(Duration::from_secs(1), 1e6);
        for a in rx.handle(rx_now(), ReceiverEvent::Connected) {
            if let ReceiverAction::Send(b) = a {
                receiver_io.write_all(&b).await.unwrap();
            }
        }
        // configs and IDRs seen, in order: "config" / "idr".
        let mut seen: Vec<&str> = Vec::new();
        let mut buf = vec![0u8; 1 << 20];
        let deadline = Instant::now() + Duration::from_secs(20);
        let mut shade = 0u8;
        while seen.iter().filter(|s| **s == "idr").count() < 2 {
            assert!(Instant::now() < deadline, "stalled after {seen:?}");
            match tokio::time::timeout(Duration::from_millis(20), receiver_io.read(&mut buf)).await
            {
                Ok(n) => {
                    let n = n.unwrap();
                    assert!(n > 0, "sender hung up after {seen:?}");
                    for a in rx.handle(rx_now(), ReceiverEvent::Bytes(&buf[..n])) {
                        match a {
                            ReceiverAction::StreamConfig(_) => seen.push("config"),
                            ReceiverAction::Video(v)
                                if v.is_idr && seen.last() == Some(&"config") =>
                            {
                                seen.push("idr");
                                if seen.len() == 2 {
                                    // The output goes away under the capture.
                                    let mut sink =
                                        shared.sink.lock().unwrap().take().expect("capturing");
                                    sink(CaptureEvent::Ended("output removed".into()));
                                }
                            }
                            ReceiverAction::Send(b) => receiver_io.write_all(&b).await.unwrap(),
                            _ => {}
                        }
                    }
                }
                Err(_) => {
                    shade = shade.wrapping_add(17);
                    push_frame(&shared, shade);
                }
            }
        }
        assert_eq!(seen, ["config", "idr", "config", "idr"]);
        if let ReceiverAction::Send(b) =
            rx.control(&opendisplay_proto::control::ControlMessage::Closing)
        {
            receiver_io.write_all(&b).await.unwrap();
        }
        let end = tokio::time::timeout(Duration::from_secs(5), task)
            .await
            .expect("closing did not end the session")
            .unwrap()
            .unwrap();
        forget_lock(&name);
        assert_eq!(end, SessionEnd::ReceiverClosed);
        let log = shared.entries();
        assert_eq!(
            log,
            [
                format!("open {name}").as_str(),
                "start_capture",
                "reconfigure",
                "start_capture",
                "stop_capture",
                "close keep=false",
            ]
        );
    }

    /// Compositor IPC for the drift check runs off the session thread: a
    /// probe stuck for seconds neither delays the receiver's `closing` nor
    /// acts on a session that has ended.
    #[tokio::test]
    async fn a_slow_drift_probe_does_not_stall_the_session() {
        let (hello, name) = test_hello("sp");
        let shared = Shared::default();
        *shared.drift.lock().unwrap() = Some("slow compositor".into());
        *shared.drift_delay.lock().unwrap() = Duration::from_millis(1500);
        let (sender_io, mut receiver_io) = tokio::io::duplex(1 << 16);
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);
        let mut backend = FakeBackend(shared.clone());
        let task = tokio::spawn(async move {
            let mut budget = LossBudget::default();
            session(
                sender_io,
                &mut backend,
                &opts(),
                Instant::now(),
                shutdown_rx,
                &mut budget,
                None,
            )
            .await
        });
        let mut rx = ReceiverSession::new(ReceiverConfig::new(hello));
        let rx_now = || Now::new(Duration::from_secs(1), 1e6);
        for a in rx.handle(rx_now(), ReceiverEvent::Connected) {
            if let ReceiverAction::Send(b) = a {
                receiver_io.write_all(&b).await.unwrap();
            }
        }
        let mut buf = vec![0u8; 1 << 16];
        loop {
            let n = tokio::time::timeout(Duration::from_secs(5), receiver_io.read(&mut buf))
                .await
                .expect("no streamConfig")
                .unwrap();
            let acts = rx.handle(rx_now(), ReceiverEvent::Bytes(&buf[..n]));
            if acts
                .iter()
                .any(|a| matches!(a, ReceiverAction::StreamConfig(_)))
            {
                break;
            }
        }
        // A few ticks: the probe is now blocking on its thread.
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(shared.drift.lock().unwrap().is_none(), "probe not started");
        if let ReceiverAction::Send(b) =
            rx.control(&opendisplay_proto::control::ControlMessage::Closing)
        {
            receiver_io.write_all(&b).await.unwrap();
        }
        let began = Instant::now();
        let end = tokio::time::timeout(Duration::from_secs(5), task)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert!(
            began.elapsed() < Duration::from_millis(800),
            "took {:?}",
            began.elapsed()
        );
        forget_lock(&name);
        assert_eq!(end, SessionEnd::ReceiverClosed);
        assert!(
            !shared.entries().iter().any(|l| l == "reconfigure"),
            "{:?}",
            shared.entries()
        );
    }

    #[tokio::test]
    async fn a_drifted_display_is_restored_from_its_spec() {
        let (hello, name) = test_hello("dr");
        let shared = Shared::default();
        *shared.drift.lock().unwrap() = Some("Hyprland config reloaded".into());
        let (sender_io, mut receiver_io) = tokio::io::duplex(1 << 16);
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);
        let mut backend = FakeBackend(shared.clone());
        let task = tokio::spawn(async move {
            let mut budget = LossBudget::default();
            session(
                sender_io,
                &mut backend,
                &opts(),
                Instant::now(),
                shutdown_rx,
                &mut budget,
                None,
            )
            .await
        });
        let mut rx = ReceiverSession::new(ReceiverConfig::new(hello));
        let rx_now = || Now::new(Duration::from_secs(1), 1e6);
        for a in rx.handle(rx_now(), ReceiverEvent::Connected) {
            if let ReceiverAction::Send(b) = a {
                receiver_io.write_all(&b).await.unwrap();
            }
        }
        let mut buf = vec![0u8; 1 << 16];
        let mut configs = 0;
        while configs < 2 {
            let n = tokio::time::timeout(Duration::from_secs(5), receiver_io.read(&mut buf))
                .await
                .expect("no second streamConfig")
                .unwrap();
            assert!(n > 0);
            configs += rx
                .handle(rx_now(), ReceiverEvent::Bytes(&buf[..n]))
                .iter()
                .filter(|a| matches!(a, ReceiverAction::StreamConfig(_)))
                .count();
        }
        drop(receiver_io);
        task.await.unwrap().unwrap();
        forget_lock(&name);
        let log = shared.entries();
        assert_eq!(
            &log[..4],
            [
                format!("open {name}").as_str(),
                "start_capture",
                "stop_capture",
                "reconfigure"
            ],
            "{log:?}"
        );
        assert_eq!(log[4], "start_capture");
    }

    async fn cursor_session(tag: &str, events: Vec<CursorEvent>) -> (Vec<ReceiverAction>, Shared) {
        let (mut hello, name) = test_hello(tag);
        hello.cursor_port = Some(9001);
        let shared = Shared::default();
        let (sender_io, mut receiver_io) = tokio::io::duplex(1 << 16);
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);
        let mut backend = FakeBackend(shared.clone());
        let task = tokio::spawn(async move {
            let mut budget = LossBudget::default();
            session(
                sender_io,
                &mut backend,
                &opts(),
                Instant::now(),
                shutdown_rx,
                &mut budget,
                None,
            )
            .await
        });
        let mut rx = ReceiverSession::new(ReceiverConfig::new(hello));
        let rx_now = || Now::new(Duration::from_secs(1), 1e6);
        for a in rx.handle(rx_now(), ReceiverEvent::Connected) {
            if let ReceiverAction::Send(b) = a {
                receiver_io.write_all(&b).await.unwrap();
            }
        }
        let mut buf = vec![0u8; 1 << 16];
        let mut seen = Vec::new();
        let mut events = Some(events);
        // Until the sender has been quiet for a moment after the events.
        loop {
            let wait = if events.is_some() { 5000 } else { 300 };
            let Ok(r) =
                tokio::time::timeout(Duration::from_millis(wait), receiver_io.read(&mut buf)).await
            else {
                assert!(events.is_none(), "sender went quiet before streamConfig");
                break;
            };
            let n = r.unwrap();
            assert!(n > 0, "sender hung up");
            for a in rx.handle(rx_now(), ReceiverEvent::Bytes(&buf[..n])) {
                match a {
                    ReceiverAction::StreamConfig(_) => {
                        if let Some(evs) = events.take() {
                            let mut sink = shared
                                .cursor_sink
                                .lock()
                                .unwrap()
                                .take()
                                .expect("cursor started");
                            for ev in evs {
                                sink(ev);
                            }
                            *shared.cursor_sink.lock().unwrap() = Some(sink);
                        }
                    }
                    a @ (ReceiverAction::Cursor { .. } | ReceiverAction::CursorImage(_)) => {
                        seen.push(a)
                    }
                    _ => {}
                }
            }
        }
        drop(receiver_io);
        task.await.unwrap().unwrap();
        forget_lock(&name);
        (seen, shared)
    }

    fn sprite() -> CursorEvent {
        CursorEvent::Image {
            png: b"PNG".to_vec(),
            nw: 0.02,
            nh: 0.04,
            ax: 0.25,
            ay: 0.5,
        }
    }

    #[test]
    fn the_cursor_goes_live_on_the_first_sprite_and_back_on_failure() {
        use CursorAction::*;
        use CursorSide::*;
        let moved = CursorEvent::Moved { x: 0.1, y: 0.2 };
        let fail = CursorEvent::SpriteUnavailable("x".into());
        assert_eq!(cursor_step(Pending, &moved), (Pending, Hold));
        assert_eq!(cursor_step(Pending, &CursorEvent::Hidden), (Pending, Hold));
        assert_eq!(cursor_step(Pending, &sprite()), (Live, GoLive));
        assert_eq!(cursor_step(Live, &moved), (Live, Forward));
        assert_eq!(cursor_step(Live, &sprite()), (Live, Forward));
        assert_eq!(cursor_step(Live, &fail), (Failed, Fail));
        assert_eq!(cursor_step(Pending, &fail), (Failed, Fail));
        assert_eq!(cursor_step(Failed, &sprite()), (Failed, Ignore));
        assert_eq!(cursor_step(Off, &moved), (Off, Ignore));
    }

    /// The video keeps its cursor until the first sprite is out; positions
    /// before that are held, and the newest one follows the sprite.
    #[tokio::test]
    async fn the_cursor_rides_the_side_channel_once_a_sprite_exists() {
        let (seen, shared) = cursor_session(
            "cu",
            vec![
                CursorEvent::Moved { x: 0.1, y: 0.1 },
                CursorEvent::Moved { x: 0.5, y: 0.25 },
                sprite(),
                CursorEvent::Moved { x: 0.6, y: 0.3 },
            ],
        )
        .await;
        let ReceiverAction::CursorImage(img) = &seen[0] else {
            panic!("sprite first: {seen:?}")
        };
        assert_eq!((img.nw, img.nh, img.ax, img.ay), (0.02, 0.04, 0.25, 0.5));
        assert_eq!(img.png, base64(b"PNG"));
        let cursor = |x: f64, y: f64| ReceiverAction::Cursor {
            x: Some(x),
            y: Some(y),
            visible: true,
        };
        assert_eq!(&seen[1..], [cursor(0.5, 0.25), cursor(0.6, 0.3)]);
        let log = shared.entries();
        assert_eq!(&log[1..3], ["start_cursor", "start_capture painted=true"]);
        assert!(
            log.contains(&"set_cursor_painted false".to_string()),
            "{log:?}"
        );
        assert_eq!(*shared.painted.lock().unwrap(), Some(false));
    }

    /// No sprite, no side channel: positions never reach the receiver and
    /// the video keeps its cursor.
    #[tokio::test]
    async fn without_a_sprite_the_cursor_stays_in_the_video() {
        let (seen, shared) = cursor_session(
            "cn",
            vec![
                CursorEvent::Moved { x: 0.5, y: 0.5 },
                CursorEvent::SpriteUnavailable("no ARGB".into()),
                CursorEvent::Moved { x: 0.6, y: 0.6 },
            ],
        )
        .await;
        assert!(
            seen.iter()
                .all(|a| matches!(a, ReceiverAction::Cursor { visible: false, .. })),
            "{seen:?}"
        );
        assert_eq!(*shared.painted.lock().unwrap(), Some(true));
    }

    /// A sprite that fails after going live: paint again, hide the
    /// receiver's cursor, ignore what follows.
    #[tokio::test]
    async fn a_failing_sprite_after_going_live_paints_again() {
        let (seen, shared) = cursor_session(
            "cf",
            vec![
                sprite(),
                CursorEvent::Moved { x: 0.5, y: 0.5 },
                CursorEvent::SpriteUnavailable("captures failing".into()),
                CursorEvent::Moved { x: 0.6, y: 0.6 },
            ],
        )
        .await;
        assert_eq!(*shared.painted.lock().unwrap(), Some(true));
        assert_eq!(
            seen.last(),
            Some(&ReceiverAction::Cursor {
                x: None,
                y: None,
                visible: false
            })
        );
        assert!(
            !seen
                .iter()
                .any(|a| matches!(a, ReceiverAction::Cursor { x: Some(x), .. } if *x == 0.6))
        );
    }

    #[tokio::test]
    async fn without_a_cursor_port_the_cursor_is_painted() {
        let (hello, name) = test_hello("cv");
        let shared = Shared::default();
        let _ = drive_with(shared.clone(), hello, 0).await;
        forget_lock(&name);
        assert_eq!(*shared.painted.lock().unwrap(), Some(true));
        assert!(!shared.entries().iter().any(|l| l == "start_cursor"));
    }

    #[test]
    fn the_success_line_reads_plainly() {
        let info = DisplayInfo {
            name: "od-1f046d".into(),
            width: 4096,
            height: 2304,
            refresh_hz: 60.0,
            scale: 2.0,
            x: 0,
            y: 0,
        };
        assert_eq!(
            extending_line("iMac (1F04…)", &info, Position::AutoLeft),
            "Extending onto iMac (1F04…): 2048x1152 logical at 2x (od-1f046d, left of your other displays). Ctrl+C to stop."
        );
        let frac = DisplayInfo {
            scale: 2.6666667,
            width: 2424,
            height: 1080,
            ..info
        };
        assert!(
            extending_line("Pixel", &frac, Position::At(10, 20))
                .contains("909x405 logical at 2.67x (od-1f046d, at 10,20)")
        );
    }

    #[test]
    fn backoff_doubles_to_the_cap_and_resets_after_a_healthy_session() {
        let ms = Duration::from_millis;
        let mut b = Backoff::default();
        let delays: Vec<_> = (0..7).map(|_| b.delay(None)).collect();
        assert_eq!(
            delays,
            [
                ms(500),
                ms(1000),
                ms(2000),
                ms(4000),
                ms(8000),
                ms(10_000),
                ms(10_000)
            ]
        );
        // A short session keeps backing off.
        assert_eq!(b.delay(Some(Duration::from_secs(5))), ms(10_000));
        // One that ran long enough starts over.
        assert_eq!(b.delay(Some(Duration::from_secs(31))), ms(500));
        assert_eq!(b.delay(None), ms(1000));
    }
}
