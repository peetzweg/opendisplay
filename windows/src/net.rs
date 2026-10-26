//! TCP session handling (PROTOCOL.md §1, §6, §8.2) and Bonjour advertisement (§2.1).

use crate::PV;
use crate::clock::{ClockSync, now_ms};
use crate::control::{ControlParser, Hello, Incoming, Outgoing, SenderHealth};
use crate::framing::{FrameKind, FrameReader, classify, write_frame};
use socket2::{Domain, Socket, Type};
use std::io::{self, ErrorKind, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

/// Drop the sender after this long without any bytes (§8.2).
pub const LIVENESS: Duration = Duration::from_secs(5);
const PING_EVERY: Duration = Duration::from_secs(2);

/// What the app does with a session's traffic. Called on the network thread, so it must not block.
pub trait Handler: Send + Sync + 'static {
    /// A new sender is connected (hello already sent); reset decoder state. No frame of it has been delivered yet.
    fn connected(&self, session: &Arc<Session>);
    fn video(&self, session: &Session, payload: &[u8]);
    fn control(&self, session: &Session, msg: &Incoming);
}

/// One sender connection. Send from any thread.
pub struct Session {
    pub peer: SocketAddr,
    writer: Mutex<TcpStream>,
    ctl: TcpStream,
    closed: AtomicBool,
    pub clock: Mutex<ClockSync>,
    /// Counters from the sender's last `ping` (§6.2), for the overlay.
    pub health: Mutex<SenderHealth>,
    /// Sender pv from `welcome`; 1 until one arrives (§6.4: no welcome means pv 1).
    sender_pv: AtomicU32,
}

impl Session {
    pub fn send(&self, msg: &Outgoing) -> io::Result<()> {
        let mut buf = Vec::new();
        write_frame(&mut buf, &msg.to_json())
            .map_err(|e| io::Error::new(ErrorKind::InvalidInput, format!("{e:?}")))?;
        let r = self.writer.lock().unwrap().write_all(&buf);
        if r.is_err() {
            self.close();
        }
        r
    }

    pub fn close(&self) {
        if !self.closed.swap(true, Ordering::AcqRel) {
            let _ = self.ctl.shutdown(Shutdown::Both);
        }
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }

    pub fn sender_pv(&self) -> u32 {
        self.sender_pv.load(Ordering::Relaxed)
    }

    fn handle(&self, msg: &Incoming) {
        match msg {
            Incoming::Pong { t, mt } => self.clock.lock().unwrap().add(*t, *mt, now_ms()),
            Incoming::Ping(h) => *self.health.lock().unwrap() = *h,
            Incoming::Welcome { pv, min } => {
                self.sender_pv.store(*pv as u32, Ordering::Relaxed);
                log::info!("welcome: sender pv {pv}, min {min}");
            }
            Incoming::UpdateRequired { message, store, .. } => log::error!(
                "sender requires an update of this receiver: {} {}",
                message.as_deref().unwrap_or("please update"),
                store.as_deref().unwrap_or("")
            ),
            _ => {}
        }
    }
}

/// Dual-stack listener, so senders reach us on whichever address Bonjour resolved.
pub fn listen(port: u16) -> io::Result<TcpListener> {
    let sock = Socket::new(Domain::IPV6, Type::STREAM, None)?;
    sock.set_only_v6(false)?;
    sock.bind(&SocketAddr::from(([0u16; 8], port)).into())?;
    sock.listen(8)?;
    Ok(sock.into())
}

/// Dual-stack UDP socket for the cursor side channel (§6.3).
pub fn bind_udp(port: u16) -> io::Result<UdpSocket> {
    let sock = Socket::new(Domain::IPV6, Type::DGRAM, None)?;
    sock.set_only_v6(false)?;
    sock.bind(&SocketAddr::from(([0u16; 8], port)).into())?;
    Ok(sock.into())
}

/// Accepts senders forever. A new connection replaces the current one (§1).
/// Ambiguity: §6.4 mentions the official receiver waiting for a newcomer's first bytes; §1's MUST adopt wins here.
pub fn serve(
    listener: TcpListener,
    hello: impl Fn() -> Hello,
    handler: Arc<dyn Handler>,
) -> io::Result<()> {
    let mut current: Option<(Arc<Session>, JoinHandle<()>)> = None;
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(s) => s,
            Err(e) => {
                log::warn!("accept failed: {e}");
                continue;
            }
        };
        if let Some((old, reader)) = current.take() {
            old.close();
            let _ = reader.join();
        }
        match start(stream, &hello, &handler) {
            Ok(c) => current = Some(c),
            Err(e) => log::warn!("session setup failed: {e}"),
        }
    }
    Ok(())
}

fn start(
    stream: TcpStream,
    hello: &impl Fn() -> Hello,
    handler: &Arc<dyn Handler>,
) -> io::Result<(Arc<Session>, JoinHandle<()>)> {
    stream.set_nodelay(true)?;
    stream.set_read_timeout(Some(LIVENESS))?;
    stream.set_write_timeout(Some(LIVENESS))?;
    let s = Arc::new(Session {
        peer: stream.peer_addr()?,
        writer: Mutex::new(stream.try_clone()?),
        ctl: stream.try_clone()?,
        closed: AtomicBool::new(false),
        clock: Mutex::default(),
        health: Mutex::default(),
        sender_pv: AtomicU32::new(1),
    });
    s.send(&Outgoing::Hello(hello()))?; // hello first, always (§6.1)
    log::info!("sender connected from {}", s.peer);
    handler.connected(&s);

    let ping = s.clone();
    thread::Builder::new().name("ping".into()).spawn(move || {
        while !ping.is_closed() && ping.send(&Outgoing::Ping { t: now_ms() as u64 }).is_ok() {
            thread::sleep(PING_EVERY);
        }
    })?;

    let (rs, h) = (s.clone(), handler.clone());
    let reader = thread::Builder::new()
        .name("net-rx".into())
        .spawn(move || {
            let why = match read_loop(stream, &rs, &*h) {
                Ok(()) => "closed by sender".into(),
                Err(e) if matches!(e.kind(), ErrorKind::TimedOut | ErrorKind::WouldBlock) => {
                    "no bytes for 5 s".into()
                }
                Err(e) => e.to_string(),
            };
            if !rs.is_closed() {
                log::info!("sender {} disconnected: {why}", rs.peer);
            }
            rs.close();
        })?;
    Ok((s, reader))
}

/// Hot path: no logging, no per-frame allocation for video.
fn read_loop(mut stream: TcpStream, s: &Session, h: &dyn Handler) -> io::Result<()> {
    let mut frames = FrameReader::default();
    let mut parser = ControlParser::default();
    loop {
        if frames.read_from(&mut stream)? == 0 {
            return Ok(());
        }
        while let Some(p) = frames
            .next_frame()
            .map_err(|e| io::Error::new(ErrorKind::InvalidData, format!("{e:?}")))?
        {
            match classify(p) {
                FrameKind::Video => h.video(s, p),
                FrameKind::Control => {
                    if let Some(m) = parser.parse(p) {
                        s.handle(&m);
                        h.control(s, &m);
                    }
                }
            }
        }
    }
}

/// Registers `_opensidecar._tcp` with TXT `id` and `pv` (§2.1). Keep the daemon alive to stay advertised.
pub fn advertise(
    name: &str,
    id: &str,
    port: u16,
) -> Result<mdns_sd::ServiceDaemon, mdns_sd::Error> {
    let daemon = mdns_sd::ServiceDaemon::new()?;
    // A sender resolving our ::1 would dial its own loopback.
    daemon.disable_interface(vec![
        mdns_sd::IfKind::LoopbackV4,
        mdns_sd::IfKind::LoopbackV6,
    ])?;
    let host = format!(
        "{}.local.",
        std::env::var("COMPUTERNAME")
            .unwrap_or_else(|_| "od-receiver".into())
            .to_lowercase()
    );
    let pv = PV.to_string();
    let info = mdns_sd::ServiceInfo::new(
        "_opensidecar._tcp.local.",
        name,
        &host,
        "",
        port,
        &[("id", id), ("pv", pv.as_str())][..],
    )?
    .enable_addr_auto();
    daemon.register(info)?;
    Ok(daemon)
}
