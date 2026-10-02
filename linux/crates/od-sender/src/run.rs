//! The sender session: one receiver, one virtual output, capture -> encode ->
//! wire, driven by `SenderSession` (§1 sender dials, §5, §6, §8).

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use opendisplay_proto::control::{Hello, StreamConfig};
use opendisplay_session::Now;
use opendisplay_session::sender::{SenderAction, SenderConfig, SenderEvent, SenderSession};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use crate::capture::{self, FrameInfo};
use crate::encoder::{Encoded, Encoder, EncoderSettings};
use crate::hyprland::HyprlandIpc;
use crate::input::{InputCmd, InputInjector};

#[derive(Debug, Clone)]
pub struct RunOptions {
    pub bitrate_mbps: f32,
    pub max_fps: f32,
    pub threads: u16,
    /// Bake the cursor into the video (receivers without cursor rendering).
    pub cursor_in_video: bool,
    /// Hyprland position spec for the virtual output.
    pub position: String,
    /// Leave the headless output in place when the session ends.
    pub keep_output: bool,
    pub reconnect: bool,
    pub duration: Option<Duration>,
}

struct RawFrame {
    info: FrameInfo,
    pixels: Vec<u8>,
    captured_at: Instant,
}

/// The virtual display plus its capture and encode threads.
struct Display {
    name: String,
    stop: Arc<AtomicBool>,
    force_idr: Arc<AtomicBool>,
    encoded_rx: mpsc::Receiver<Encoded>,
    hello: Hello,
    input: Option<InputInjector>,
}

fn now(start: Instant) -> Now {
    let wall_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0);
    Now::new(start.elapsed(), wall_ms)
}

fn short_id(hello: &Hello) -> String {
    hello
        .id
        .as_deref()
        .map(|s| s.chars().take(6).collect::<String>().to_lowercase())
        .unwrap_or_else(|| "anon".into())
}

impl Display {
    fn create(ipc: &HyprlandIpc, hello: &Hello, opts: &RunOptions) -> Result<Display> {
        let name = format!("od-{}", short_id(hello));
        let hz = hello.display_max_frame_rate.unwrap_or(60).clamp(30, 240);
        let scale = if hello.scale >= 1.0 { hello.scale } else { 1.0 };
        if ipc.monitor(&name)?.is_none() {
            ipc.create_headless(&name)
                .with_context(|| format!("creating headless output {name}"))?;
        }
        let m = ipc.configure(
            &name,
            hello.pixels_wide,
            hello.pixels_high,
            hz,
            scale,
            &opts.position,
        )?;
        info!(
            "virtual display {} = {}x{} @{:.0} scale {} at {},{} ({} logical)",
            m.name,
            m.width,
            m.height,
            m.refresh_rate,
            m.scale,
            m.x,
            m.y,
            format!(
                "{}x{}",
                (m.width as f64 / m.scale).round(),
                (m.height as f64 / m.scale).round()
            )
        );

        let stop = Arc::new(AtomicBool::new(false));
        let force_idr = Arc::new(AtomicBool::new(true));
        let (raw_tx, raw_rx) = std::sync::mpsc::sync_channel::<RawFrame>(1);
        let (encoded_tx, encoded_rx) = mpsc::channel::<Encoded>(4);

        // Capture thread: latest wins at the channel; a busy encoder drops the older frame.
        let cap_stop = stop.clone();
        let cap_name = name.clone();
        let cursor = opts.cursor_in_video;
        std::thread::Builder::new()
            .name("capture".into())
            .spawn(move || {
                let r = capture::capture_shm(
                    Some(&cap_name),
                    cursor,
                    Duration::from_secs(u64::MAX / 4),
                    cap_stop,
                    |info, pixels| {
                        let _ = raw_tx.try_send(RawFrame {
                            info: *info,
                            pixels: pixels.to_vec(),
                            captured_at: Instant::now(),
                        });
                    },
                );
                if let Err(e) = r {
                    warn!("capture ended: {e:#}");
                }
            })?;

        // Encoder thread: re-encodes the last frame as an IDR when one is
        // requested and the screen is static (§5.3).
        let enc_stop = stop.clone();
        let enc_force = force_idr.clone();
        let settings = EncoderSettings {
            bitrate_bps: (opts.bitrate_mbps * 1e6) as u32,
            max_fps: opts.max_fps,
            threads: opts.threads,
        };
        std::thread::Builder::new()
            .name("encode".into())
            .spawn(move || {
                let mut encoder: Option<Encoder> = None;
                let mut last: Option<RawFrame> = None;
                let min_interval = Duration::from_secs_f32(1.0 / settings.max_fps.max(1.0));
                let mut last_sent = Instant::now() - min_interval;
                while !enc_stop.load(Ordering::Relaxed) {
                    let (frame, replay) = match raw_rx.recv_timeout(Duration::from_millis(100)) {
                        Ok(f) => (Some(f), false),
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                            if enc_force.load(Ordering::Relaxed) && last.is_some() {
                                (last.take(), true)
                            } else {
                                continue;
                            }
                        }
                        Err(_) => break,
                    };
                    let Some(frame) = frame else { continue };
                    if !replay && last_sent.elapsed() < min_interval {
                        // Rate cap: keep the newest frame for a possible replay, skip encoding it.
                        last = Some(frame);
                        continue;
                    }
                    let (w, h) = (frame.info.width, frame.info.height);
                    if encoder
                        .as_ref()
                        .is_none_or(|e| e.dimensions() != (w & !1, h & !1))
                    {
                        match Encoder::new(w, h, settings) {
                            Ok(e) => {
                                info!(
                                    "encoder: OpenH264 {}x{} {:.1} Mbit/s, {} threads",
                                    w & !1,
                                    h & !1,
                                    settings.bitrate_bps as f64 / 1e6,
                                    settings.threads
                                );
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
                    match encoder.as_mut().unwrap().encode(
                        &frame.pixels,
                        frame.info.stride,
                        force,
                        frame.captured_at,
                    ) {
                        Ok(Some(enc)) => {
                            if force && !enc.unit.is_idr {
                                warn!("encoder ignored the IDR request");
                                enc_force.store(true, Ordering::Relaxed);
                            }
                            last_sent = Instant::now();
                            if encoded_tx.blocking_send(enc).is_err() {
                                break;
                            }
                        }
                        Ok(None) => {}
                        Err(e) => warn!("encode failed: {e:#}"),
                    }
                    last = Some(frame);
                }
                debug!("encoder thread done");
            })?;

        let input = match InputInjector::start(&name, scale) {
            Ok(i) => Some(i),
            Err(e) => {
                warn!("input injection unavailable: {e:#}");
                None
            }
        };
        Ok(Display {
            name,
            stop,
            force_idr,
            encoded_rx,
            hello: hello.clone(),
            input,
        })
    }

    fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

pub async fn run(addr: SocketAddr, opts: RunOptions) -> Result<()> {
    let start = Instant::now();
    let ipc = HyprlandIpc::from_env()?;
    info!("{}", ipc.version()?);
    loop {
        if opts.duration.is_some_and(|d| start.elapsed() >= d) {
            break;
        }
        match TcpStream::connect(addr).await {
            Ok(stream) => {
                let _ = stream.set_nodelay(true);
                info!("connected to receiver {addr}");
                match session(stream, &ipc, &opts, start).await {
                    Ok(true) => {
                        info!("receiver closed the session for good");
                        break;
                    }
                    Ok(false) => info!("connection ended"),
                    Err(e) => warn!("session error: {e:#}"),
                }
            }
            Err(e) => warn!("dial {addr}: {e}"),
        }
        if !opts.reconnect {
            break;
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    Ok(())
}

/// Returns `Ok(true)` when the receiver said `closing` (do not redial).
async fn session(
    mut stream: TcpStream,
    ipc: &HyprlandIpc,
    opts: &RunOptions,
    start: Instant,
) -> Result<bool> {
    let mut sess = SenderSession::new(SenderConfig::default());
    sess.handle(now(start), SenderEvent::Connected);
    let mut display: Option<Display> = None;
    let mut buf = vec![0u8; 64 * 1024];
    let mut tick = tokio::time::interval(Duration::from_millis(100));
    let mut stats_tick = tokio::time::interval(Duration::from_secs(5));
    stats_tick.reset();
    let (mut win_frames, mut win_bytes, mut win_enc_ms, mut win_lat_ms) =
        (0u64, 0u64, Vec::<f64>::new(), Vec::<f64>::new());
    let mut closing = false;

    let result: Result<()> = async {
        loop {
            let actions: Vec<SenderAction> = tokio::select! {
                r = stream.read(&mut buf) => {
                    let n = r.context("read")?;
                    if n == 0 { return Ok(()); }
                    sess.handle(now(start), SenderEvent::Bytes(&buf[..n]))
                }
                enc = recv_encoded(&mut display) => {
                    let Some(enc) = enc else { continue };
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
                _ = tick.tick() => {
                    if opts.duration.is_some_and(|d| start.elapsed() >= d) { return Ok(()); }
                    sess.handle(now(start), SenderEvent::Tick)
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
            for a in actions {
                match a {
                    SenderAction::Send(bytes) => stream.write_all(&bytes).await.context("write")?,
                    SenderAction::SendCursorDatagram(_) => {}
                    SenderAction::Hello(h) => {
                        info!(
                            "hello: {}x{} @{} scale {} device {:?} id {:?} pv {}",
                            h.pixels_wide, h.pixels_high, h.display_max_frame_rate.unwrap_or(60), h.scale, h.device, h.id, sess.receiver_pv()
                        );
                        let rebuild = display.as_ref().is_none_or(|d| d.hello.pixels_wide != h.pixels_wide || d.hello.pixels_high != h.pixels_high || d.hello.scale != h.scale);
                        if rebuild {
                            if let Some(d) = display.take() {
                                d.stop();
                            }
                            display = Some(Display::create(ipc, &h, opts)?);
                            let cfg = sess.stream_config(StreamConfig {
                                codec: "h264".into(),
                                width: h.pixels_wide & !1,
                                height: h.pixels_high & !1,
                                frames_per_second: (opts.max_fps.round() as u32).min(h.display_max_frame_rate.unwrap_or(60)),
                            });
                            if let SenderAction::Send(b) = cfg {
                                stream.write_all(&b).await.context("write")?;
                            }
                        }
                    }
                    SenderAction::RequestKeyframe => {
                        if let Some(d) = &display {
                            d.force_idr.store(true, Ordering::Relaxed);
                        }
                    }
                    SenderAction::Touch(t) => {
                        debug!("touch {:?} {:.3},{:.3}", t.phase, t.x, t.y);
                        if let Some(i) = display.as_ref().and_then(|d| d.input.as_ref()) {
                            i.send(InputCmd::Touch(t));
                        }
                    }
                    SenderAction::Scroll(s) => {
                        debug!("scroll {} {}", s.dx, s.dy);
                        if let Some(i) = display.as_ref().and_then(|d| d.input.as_ref()) {
                            i.send(InputCmd::Scroll(s));
                        }
                    }
                    SenderAction::Pencil(_) | SenderAction::Proximity(_) => {}
                    SenderAction::Stats(v) => info!("PHONE-STATS {v}"),
                    SenderAction::ReceiverSleeping => info!("receiver sleeping"),
                    SenderAction::ReceiverClosing => {
                        closing = true;
                        return Ok(());
                    }
                    SenderAction::Close(reason) => {
                        warn!("closing: {reason:?}");
                        return Ok(());
                    }
                    SenderAction::Warn(m) => warn!("{m}"),
                }
            }
            if !sess.is_connected() {
                return Ok(());
            }
        }
    }
    .await;

    if let Some(d) = display.take() {
        d.stop();
        if !opts.keep_output {
            match ipc.remove_output(&d.name) {
                Ok(()) => info!("removed virtual display {}", d.name),
                Err(e) => warn!("removing {}: {e:#}", d.name),
            }
        }
    }
    result.map(|_| closing)
}

async fn recv_encoded(display: &mut Option<Display>) -> Option<Encoded> {
    match display {
        Some(d) => d.encoded_rx.recv().await,
        None => std::future::pending().await,
    }
}
