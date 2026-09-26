//! The Linux OpenDisplay receiver: a `ReceiverSession` wired to a TCP listener
//! (one sender at a time, adopt-and-drop, §1), an optional UDP cursor port
//! (§6.3), a Bonjour advertisement (§2.1), and a decode/present pipeline.

pub mod discovery;
pub mod id;
pub mod outputs;
pub mod stats;
pub mod video;

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::net::SocketAddr;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use opendisplay_proto::control::{ControlMessage, Hello};
use opendisplay_session::Now;
use opendisplay_session::receiver::{
    ReceiverAction, ReceiverConfig, ReceiverEvent, ReceiverSession,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::sync::watch;
use tracing::{debug, info, warn};

use video::VideoOutput;

#[derive(Debug, Clone)]
pub struct Config {
    pub listen: SocketAddr,
    pub hello: Hello,
    /// Bind UDP `listen.port + 1` and offer it as `hello.cursorPort`.
    pub cursor_udp: bool,
    pub stats_every: Duration,
}

/// What happened over the receiver's lifetime, for tests and the exit log.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Report {
    pub connections: u32,
    pub adopted_over_live: u32,
    pub welcomes: u32,
    pub video_frames: u64,
    pub idr_frames: u64,
    pub decoder_resets: u32,
    pub decode_errors: u32,
    pub cursor_updates: u64,
    pub closes: u32,
    /// Frames that reached the sink (None when the backend cannot tell).
    pub rendered_frames: Option<u64>,
}

pub struct Receiver {
    cfg: Config,
    listener: TcpListener,
    udp: Option<UdpSocket>,
    video: Box<dyn VideoOutput>,
}

fn now(start: Instant) -> Now {
    let wall_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0);
    Now::new(start.elapsed(), wall_ms)
}

impl Receiver {
    /// Bind the TCP listener (and the UDP cursor port) but do not serve yet.
    pub async fn bind(mut cfg: Config, video: Box<dyn VideoOutput>) -> Result<Receiver> {
        let listener = TcpListener::bind(cfg.listen)
            .await
            .with_context(|| format!("binding {}", cfg.listen))?;
        let local = listener.local_addr()?;
        let udp = if cfg.cursor_udp {
            let port = local.port().wrapping_add(1);
            let addr = SocketAddr::new(local.ip(), port);
            match UdpSocket::bind(addr).await {
                Ok(s) => {
                    cfg.hello.cursor_port = Some(port as u32);
                    Some(s)
                }
                Err(e) => {
                    warn!("cursor UDP port {addr} unavailable ({e}); cursor stays on TCP");
                    cfg.hello.cursor_port = None;
                    None
                }
            }
        } else {
            cfg.hello.cursor_port = None;
            None
        };
        Ok(Receiver {
            cfg,
            listener,
            udp,
            video,
        })
    }

    pub fn local_addr(&self) -> Result<SocketAddr> {
        Ok(self.listener.local_addr()?)
    }

    pub fn hello(&self) -> &Hello {
        &self.cfg.hello
    }

    /// Serve until `shutdown` flips to true. Sends `closing` to a live sender
    /// on the way out.
    pub async fn run(mut self, mut shutdown: watch::Receiver<bool>) -> Result<Report> {
        let start = Instant::now();
        let mut report = Report::default();
        let mut sess = ReceiverSession::new(ReceiverConfig::new(self.cfg.hello.clone()));
        let mut current: Option<TcpStream> = None;
        let mut peer: Option<SocketAddr> = None;
        let mut buf = vec![0u8; 1 << 20];
        let mut udp_buf = vec![0u8; 2048];
        let mut tick = tokio::time::interval(Duration::from_millis(100));
        let mut stats_tick = tokio::time::interval(self.cfg.stats_every);
        stats_tick.reset();
        let mut window = stats::Window::default();
        let mut last_rendered: u64 = 0;
        info!(
            "listening on {} ({}x{} @{} scale {}, cursor UDP {:?}, video: {})",
            self.listener.local_addr()?,
            self.cfg.hello.pixels_wide,
            self.cfg.hello.pixels_high,
            self.cfg.hello.display_max_frame_rate.unwrap_or(60),
            self.cfg.hello.scale,
            self.cfg.hello.cursor_port,
            self.video.describe()
        );

        loop {
            let actions: Vec<ReceiverAction> = tokio::select! {
                _ = shutdown.changed() => {
                    if *shutdown.borrow() { break; } else { continue; }
                }
                accepted = self.listener.accept() => {
                    let (stream, addr) = accepted.context("accept")?;
                    let _ = stream.set_nodelay(true);
                    report.connections += 1;
                    if current.is_some() {
                        // §1: a new inbound connection replaces the current one.
                        report.adopted_over_live += 1;
                        info!("sender {addr} replaces {}", peer.map(|p| p.to_string()).unwrap_or_default());
                    } else {
                        info!("sender connected from {addr}");
                    }
                    current = Some(stream);
                    peer = Some(addr);
                    sess.handle(now(start), ReceiverEvent::Connected)
                }
                read = read_current(&mut current, &mut buf) => {
                    match read {
                        Ok(0) | Err(_) => {
                            info!("sender {} disconnected", peer.map(|p| p.to_string()).unwrap_or_default());
                            current = None;
                            sess.handle(now(start), ReceiverEvent::Disconnected)
                        }
                        Ok(n) => sess.handle(now(start), ReceiverEvent::Bytes(&buf[..n])),
                    }
                }
                dgram = recv_udp(&self.udp, &mut udp_buf) => {
                    let (n, from) = dgram.context("udp recv")?;
                    let mut h = DefaultHasher::new();
                    from.hash(&mut h);
                    sess.handle(now(start), ReceiverEvent::CursorDatagram { flow: h.finish(), payload: &udp_buf[..n] })
                }
                _ = tick.tick() => {
                    let mut a = sess.handle(now(start), ReceiverEvent::Tick);
                    if let Some(err) = self.video.poll_error() {
                        warn!("decoder error: {err}");
                        report.decode_errors += 1;
                        window.decode_error();
                        a.extend(sess.handle(now(start), ReceiverEvent::DecodeLost));
                    }
                    a
                }
                _ = stats_tick.tick() => {
                    let mut extra = serde_json::Map::new();
                    extra.insert("transport".into(), "wifi".into());
                    extra.insert("offsetKnown".into(), sess.clock().offset_ms().is_some().into());
                    if let Some(r) = sess.clock().best_rtt_ms() { extra.insert("rtt".into(), r.into()); }
                    extra.insert("stalls".into(), sess.counters.dropped_awaiting_idr.into());
                    extra.insert("decoder".into(), self.video.describe().into());
                    if let Some(r) = self.video.rendered() {
                        let delta = r - last_rendered;
                        last_rendered = r;
                        extra.insert("renderFps".into(), ((delta as f64 / self.cfg.stats_every.as_secs_f64() * 10.0).round() / 10.0).into());
                    }
                    let stats = window.flush(extra);
                    info!("stats {stats}");
                    if sess.is_connected() { vec![sess.control(&ControlMessage::Stats(stats))] } else { vec![] }
                }
            };
            let mut pending_decode_lost = false;
            for action in actions {
                match action {
                    ReceiverAction::Send(bytes) => {
                        if let Some(s) = current.as_mut() {
                            if let Err(e) = s.write_all(&bytes).await {
                                warn!("write to sender failed: {e}");
                                current = None;
                                sess.handle(now(start), ReceiverEvent::Disconnected);
                            }
                        }
                    }
                    ReceiverAction::ResetDecoder => {
                        report.decoder_resets += 1;
                        if let Err(e) = self.video.reset() {
                            warn!("decoder reset failed: {e:#}");
                        }
                    }
                    ReceiverAction::Video(v) => {
                        let n = now(start);
                        let e2e = v.captured_local_ms.map(|c| n.wall_ms - c);
                        let net = v.sent_local_ms.map(|s| n.wall_ms - s);
                        window.frame(v.annexb.len(), v.is_idr, e2e, net);
                        report.video_frames += 1;
                        if v.is_idr {
                            report.idr_frames += 1;
                        }
                        if let Some(s) = v.sps {
                            debug!(
                                "stream {}x{} profile {} level {}",
                                s.width, s.height, s.profile_idc, s.level_idc
                            );
                        }
                        if let Err(e) = self.video.push(&v.annexb, v.is_idr) {
                            warn!("decoder push failed: {e:#}");
                            report.decode_errors += 1;
                            window.decode_error();
                            pending_decode_lost = true;
                        }
                    }
                    ReceiverAction::Cursor { .. } => report.cursor_updates += 1, // v1 renders no cursor (§6.2 MAY)
                    ReceiverAction::CursorImage(_) => {}
                    ReceiverAction::Welcome(w) => {
                        report.welcomes += 1;
                        info!("welcome: sender pv {} min {}", w.pv, w.min);
                    }
                    ReceiverAction::SenderOutdated {
                        sender_pv,
                        required,
                    } => {
                        warn!(
                            "sender speaks pv {sender_pv}, this receiver needs {required}: update the sender"
                        );
                    }
                    ReceiverAction::UpdateRequired(u) => {
                        warn!(
                            "sender says this receiver must update: {} ({})",
                            u.message, u.store
                        );
                    }
                    ReceiverAction::StreamConfig(s) => {
                        info!(
                            "streamConfig {} {}x{} @{}",
                            s.codec, s.width, s.height, s.frames_per_second
                        );
                    }
                    ReceiverAction::SenderHealth(p) => debug!("sender health {p:?}"),
                    ReceiverAction::Close(reason) => {
                        report.closes += 1;
                        info!("closing connection: {reason:?}");
                        current = None;
                    }
                    ReceiverAction::Warn(m) => warn!("{m}"),
                }
            }
            if pending_decode_lost {
                let a = sess.handle(now(start), ReceiverEvent::DecodeLost);
                for action in a {
                    if let (ReceiverAction::Send(bytes), Some(s)) = (action, current.as_mut()) {
                        let _ = s.write_all(&bytes).await;
                    }
                }
            }
        }
        if let Some(s) = current.as_mut() {
            if let ReceiverAction::Send(bytes) = sess.control(&ControlMessage::Closing) {
                let _ = s.write_all(&bytes).await;
            }
        }
        report.rendered_frames = self.video.rendered();
        info!("{report:?}");
        Ok(report)
    }
}

async fn read_current(current: &mut Option<TcpStream>, buf: &mut [u8]) -> std::io::Result<usize> {
    match current {
        Some(s) => s.read(buf).await,
        None => std::future::pending().await,
    }
}

async fn recv_udp(udp: &Option<UdpSocket>, buf: &mut [u8]) -> std::io::Result<(usize, SocketAddr)> {
    match udp {
        Some(s) => s.recv_from(buf).await,
        None => std::future::pending().await,
    }
}
