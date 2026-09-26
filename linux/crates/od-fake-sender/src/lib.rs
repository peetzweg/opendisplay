//! Replays an Annex B H.264 file over the OpenDisplay wire protocol so a
//! receiver can be developed and tested without a Mac. Mirror image of
//! `tools/fake-receiver.swift`.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use opendisplay_proto::control::StreamConfig;
use opendisplay_proto::video::{AccessUnit, SpsInfo, VideoFrame, access_units};
use opendisplay_session::Now;
use opendisplay_session::sender::{SenderAction, SenderConfig, SenderEvent, SenderSession};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tracing::{debug, info, warn};

#[derive(Debug, Clone)]
pub struct Options {
    pub connect: SocketAddr,
    pub clip: PathBuf,
    pub fps: f64,
    /// Stop after this long (all connections included); `None` runs forever.
    pub duration: Option<Duration>,
    /// Redial after the connection drops.
    pub reconnect: bool,
    /// Skip every Nth access unit to provoke decode loss and `kf` recovery.
    pub drop_every: Option<u64>,
    /// Stop writing anything (video and pings) for `pause_for` after
    /// `pause_at`, so the receiver hits its liveness timeout and both ends
    /// exercise reconnect.
    pub pause_at: Option<Duration>,
    pub pause_for: Duration,
    /// Replace the clip at `switch_at` to exercise the SPS/PPS change path (§5.2).
    pub switch_clip: Option<PathBuf>,
    pub switch_at: Option<Duration>,
    /// Emit synthetic cursor motion (a slow circle) at 60 Hz.
    pub cursor: bool,
    pub stats_every: Duration,
}

struct Clip {
    units: Vec<AccessUnit>,
    sps: SpsInfo,
}

fn load_clip(path: &PathBuf) -> Result<Clip> {
    let raw = std::fs::read(path).with_context(|| format!("reading {}", path.display()))?;
    let units = access_units(&raw);
    anyhow::ensure!(
        !units.is_empty(),
        "{}: no access units found",
        path.display()
    );
    anyhow::ensure!(
        units[0].is_idr,
        "{}: stream does not start with an IDR",
        path.display()
    );
    let frame = VideoFrame::parse(&units[0].annexb)?;
    let sps = frame.sps_info().context("first IDR carries no SPS")??;
    Ok(Clip { units, sps })
}

fn now(start: Instant) -> Now {
    let wall_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0);
    Now::new(start.elapsed(), wall_ms)
}

/// Summary of what happened, for tests and the final log line.
#[derive(Debug, Default, Clone, Copy)]
pub struct Summary {
    pub connections: u32,
    pub hellos: u32,
    pub frames_sent: u64,
    pub keyframe_requests: u64,
    pub touches: u64,
    pub stats_received: u64,
}

pub async fn run(opts: Options) -> Result<Summary> {
    let start = Instant::now();
    let main = load_clip(&opts.clip)?;
    let switch = opts.switch_clip.as_ref().map(load_clip).transpose()?;
    info!(
        "clip {}: {} access units, {}x{}, {} fps",
        opts.clip.display(),
        main.units.len(),
        main.sps.width,
        main.sps.height,
        opts.fps
    );
    let mut summary = Summary::default();
    loop {
        if opts.duration.is_some_and(|d| start.elapsed() >= d) {
            break;
        }
        match TcpStream::connect(opts.connect).await {
            Ok(stream) => {
                summary.connections += 1;
                stream.set_nodelay(true)?;
                info!("connected to {}", opts.connect);
                let r = session(stream, &opts, &main, switch.as_ref(), start, &mut summary).await;
                match r {
                    Ok(()) => info!("connection ended"),
                    Err(e) => warn!("connection error: {e:#}"),
                }
            }
            Err(e) => warn!("dial {} failed: {e}", opts.connect),
        }
        if !opts.reconnect {
            break;
        }
        // The official sender redials ~1 s after a failure (§8.2).
        let remaining = opts.duration.map(|d| d.saturating_sub(start.elapsed()));
        if remaining.is_some_and(|r| r.is_zero()) {
            break;
        }
        tokio::time::sleep(
            remaining.map_or(Duration::from_secs(1), |r| r.min(Duration::from_secs(1))),
        )
        .await;
    }
    info!("{summary:?}");
    Ok(summary)
}

async fn session(
    mut stream: TcpStream,
    opts: &Options,
    main: &Clip,
    switch: Option<&Clip>,
    start: Instant,
    summary: &mut Summary,
) -> Result<()> {
    let connected_at = Instant::now();
    let mut sess = SenderSession::new(SenderConfig::default());
    sess.handle(now(start), SenderEvent::Connected);
    let mut clip = main;
    let mut switched = false;
    let mut index = 0usize;
    let mut frame_no: u64 = 0;
    let mut paused_until: Option<Instant> = None;
    let mut pause_done = false;
    let mut frame_tick = tokio::time::interval(Duration::from_secs_f64(1.0 / opts.fps));
    frame_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut cursor_tick = tokio::time::interval(Duration::from_millis(1000 / 60));
    let mut tick = tokio::time::interval(Duration::from_millis(100));
    let mut stats_tick = tokio::time::interval(opts.stats_every);
    stats_tick.reset();
    let mut buf = vec![0u8; 64 * 1024];
    let mut window_frames = 0u64;
    let mut window_bytes = 0u64;
    let mut window_start = Instant::now();
    let mut cursor_angle = 0f64;

    loop {
        let paused = paused_until.is_some_and(|u| Instant::now() < u);
        if paused_until.is_some() && !paused {
            paused_until = None;
            info!("pause over");
        }
        let actions: Vec<SenderAction> = tokio::select! {
            r = stream.read(&mut buf) => {
                let n = r.context("read")?;
                if n == 0 {
                    sess.handle(now(start), SenderEvent::Disconnected);
                    return Ok(());
                }
                sess.handle(now(start), SenderEvent::Bytes(&buf[..n]))
            }
            _ = tick.tick() => {
                if opts.duration.is_some_and(|d| start.elapsed() >= d) {
                    return Ok(());
                }
                if let (Some(at), false) = (opts.pause_at, pause_done) {
                    if connected_at.elapsed() >= at {
                        info!("pausing all writes for {:?}", opts.pause_for);
                        paused_until = Some(Instant::now() + opts.pause_for);
                        pause_done = true;
                    }
                }
                if let (Some(at), Some(other), false) = (opts.switch_at, switch, switched) {
                    if connected_at.elapsed() >= at {
                        info!("switching clip to {}x{}", other.sps.width, other.sps.height);
                        clip = other;
                        index = 0;
                        switched = true;
                        // Announce the new operating point (§6.2) before the new stream.
                        let a = sess.stream_config(StreamConfig {
                            codec: "h264".into(),
                            width: other.sps.width,
                            height: other.sps.height,
                            frames_per_second: opts.fps.round() as u32,
                        });
                        apply(&mut stream, &mut sess, vec![a], summary, &mut window_bytes).await?;
                    }
                }
                if paused { vec![] } else { sess.handle(now(start), SenderEvent::Tick) }
            }
            _ = frame_tick.tick(), if sess.ready_for_video() && !paused => {
                if sess.needs_idr() {
                    // Jump to the next IDR at or after the current position (wrapping).
                    let n = clip.units.len();
                    if let Some(off) = (0..n).find(|o| clip.units[(index + o) % n].is_idr) {
                        index = (index + off) % n;
                    }
                }
                let unit = &clip.units[index];
                index = (index + 1) % clip.units.len();
                frame_no += 1;
                if opts.drop_every.is_some_and(|n| frame_no % n == 0) {
                    debug!("dropping frame {frame_no}");
                    vec![]
                } else {
                    let n = now(start);
                    let a = sess.push_encoded_frame(n, &unit.annexb, unit.is_idr, Some(n.wall_ms));
                    if !a.is_empty() { window_frames += 1; }
                    a
                }
            }
            _ = cursor_tick.tick(), if opts.cursor && sess.ready_for_video() && !paused => {
                cursor_angle += std::f64::consts::TAU / 600.0;
                sess.cursor(now(start), 0.5 + 0.3 * cursor_angle.cos(), 0.5 + 0.3 * cursor_angle.sin(), true)
            }
            _ = stats_tick.tick() => {
                let el = window_start.elapsed().as_secs_f64().max(1e-3);
                info!(
                    "sent {:.1} frames/s  {:.1} Mbit/s  sess={:?}",
                    window_frames as f64 / el,
                    window_bytes as f64 * 8.0 / el / 1e6,
                    sess.counters
                );
                window_frames = 0; window_bytes = 0; window_start = Instant::now();
                vec![]
            }
        };
        // A pause means silence: not even pong replies leave, so the receiver
        // hits its liveness window (§8.2) exactly as with a cut cable.
        let actions = if paused {
            actions
                .into_iter()
                .filter(|a| {
                    !matches!(
                        a,
                        SenderAction::Send(_) | SenderAction::SendCursorDatagram(_)
                    )
                })
                .collect()
        } else {
            actions
        };
        apply(&mut stream, &mut sess, actions, summary, &mut window_bytes).await?;
        if !sess.is_connected() {
            return Ok(());
        }
    }
}

async fn apply(
    stream: &mut TcpStream,
    sess: &mut SenderSession,
    actions: Vec<SenderAction>,
    summary: &mut Summary,
    bytes_out: &mut u64,
) -> Result<()> {
    for a in actions {
        match a {
            SenderAction::Send(bytes) => {
                *bytes_out += bytes.len() as u64;
                if opendisplay_proto::classify(&bytes[4..]) == opendisplay_proto::Channel::Video {
                    summary.frames_sent += 1;
                }
                stream.write_all(&bytes).await.context("write")?;
            }
            SenderAction::SendCursorDatagram(_) => {
                // The fake sender has no UDP socket; the session mirrors onto
                // TCP until an ack arrives, which never comes, so it falls back.
            }
            SenderAction::Hello(h) => {
                summary.hellos += 1;
                info!(
                    "hello: {}x{} @{} scale {} device {:?} id {:?} pv {} cursorPort {:?} maxEncode {:?}x{:?}",
                    h.pixels_wide,
                    h.pixels_high,
                    h.display_max_frame_rate.unwrap_or(60),
                    h.scale,
                    h.device,
                    h.id,
                    sess.receiver_pv(),
                    h.cursor_port,
                    h.max_encode_wide,
                    h.max_encode_high
                );
            }
            SenderAction::RequestKeyframe => {
                summary.keyframe_requests += 1;
                debug!("keyframe requested");
            }
            SenderAction::Touch(t) => {
                summary.touches += 1;
                debug!("touch {:?} {:.3},{:.3} t={:?}", t.phase, t.x, t.y, t.t);
            }
            SenderAction::Scroll(s) => debug!("scroll {} {}", s.dx, s.dy),
            SenderAction::Pencil(p) => debug!(
                "pencil {:?} {:.3},{:.3} p={:.2}",
                p.phase, p.x, p.y, p.pressure
            ),
            SenderAction::Proximity(p) => {
                debug!("proximity entering={} {:.3},{:.3}", p.entering, p.x, p.y)
            }
            SenderAction::Stats(v) => {
                summary.stats_received += 1;
                info!("PHONE-STATS {v}");
            }
            SenderAction::ReceiverSleeping => info!("receiver sleeping"),
            SenderAction::ReceiverClosing => info!("receiver closing"),
            SenderAction::Close(reason) => {
                warn!("closing: {reason:?}");
                return Ok(());
            }
            SenderAction::Warn(msg) => warn!("{msg}"),
        }
    }
    Ok(())
}
