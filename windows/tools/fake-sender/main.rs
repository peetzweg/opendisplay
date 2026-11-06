//! Test sender: finds (Bonjour) or dials a receiver, reads hello, replies welcome, then streams an
//! H.264 Annex B file one access unit per wire frame with a telemetry prefix. Answers ping with pong
//! and jumps to the next IDR on kf.
//!
//! usage: fake-sender [--cursor] [--no-welcome] <stream.h264> [host:port|auto] [fps] [start-frame]
//! A start frame that is not an IDR simulates joining mid-GOP.
//!
//! `--cursor` also sends a cursorImg and circles the cursor at 120 Hz with `s` (§6.3): over UDP
//! when hello offers `cursorPort` (mirrored on TCP until cursorAck), injecting a reordered and a
//! stale datagram every 60 ticks, and switching to a new UDP flow after 4 s.
//!
//! `--no-welcome` skips `welcome`, so the receiver treats us as pv 1 (stylus degrades to touch).
//! Input messages carrying `t` are printed with their age (our clock minus `t`).

use mdns_sd::{ServiceDaemon, ServiceEvent};
use od_receiver::clock::now_ms;
use od_receiver::framing::FrameReader;
use od_receiver::h264::access_units;
use serde_json::{Value, json};
use std::error::Error;
use std::io::{self, ErrorKind, Read, Write};
use std::net::{SocketAddr, TcpStream, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use std::{env, fs, process, thread};

fn main() -> Result<(), Box<dyn Error>> {
    let mut args: Vec<String> = env::args().collect();
    let with_cursor = args.iter().any(|a| a == "--cursor");
    let welcome = !args.iter().any(|a| a == "--no-welcome");
    args.retain(|a| a != "--cursor" && a != "--no-welcome");
    let Some(path) = args.get(1) else {
        eprintln!(
            "usage: fake-sender [--cursor] [--no-welcome] <stream.h264> [host:port|auto] [fps] [start-frame]"
        );
        process::exit(2);
    };
    let fps: f64 = args.get(3).map_or(Ok(60.0), |s| s.parse())?;
    let aus = access_units(&fs::read(path)?);
    let idr_count = aus.iter().filter(|a| a.0).count();
    println!("{path}: {} access units, {idr_count} IDR", aus.len());
    if idr_count == 0 {
        return Err("stream has no IDR frame".into());
    }
    let addr = match args.get(2).map(String::as_str) {
        None | Some("auto") => discover()?,
        Some(a) => a.to_string(),
    };

    let mut stream = TcpStream::connect(&addr)?;
    stream.set_nodelay(true)?;
    println!("connected to {addr}");
    let writer = Arc::new(Mutex::new(stream.try_clone()?));
    let mut frames = FrameReader::default();
    let hello = read_msg(&mut stream, &mut frames)?;
    println!("<- {hello}");
    if welcome {
        send(&writer, &json!({"type": "welcome", "pv": 3, "min": 1}))?;
    }

    let kf = Arc::new(AtomicBool::new(false));
    let acks = Arc::new(AtomicUsize::new(0));
    if with_cursor {
        let udp = hello["cursorPort"]
            .as_u64()
            .map(|p| SocketAddr::new(stream.peer_addr().unwrap().ip(), p as u16));
        let (w, a) = (writer.clone(), acks.clone());
        thread::spawn(move || {
            if let Err(e) = cursor(&w, udp, &a) {
                println!("cursor thread stopped: {e}");
            }
        });
    }
    let (w, k, a) = (writer.clone(), kf.clone(), acks.clone());
    thread::spawn(move || {
        let err = loop {
            let m = match read_msg(&mut stream, &mut frames) {
                Ok(m) => m,
                Err(e) => break e,
            };
            let r = match m["type"].as_str() {
                Some("ping") => send(&w, &json!({"type": "pong", "t": m["t"], "mt": now_ms()})),
                Some("kf") => {
                    k.store(true, Ordering::Relaxed);
                    Ok(())
                }
                Some("cursorAck") => {
                    println!("<- {m} (#{})", a.fetch_add(1, Ordering::Relaxed) + 1);
                    Ok(())
                }
                _ => {
                    match m["t"].as_f64() {
                        Some(t) => println!("<- {m} (age {:.2} ms)", now_ms() - t),
                        None => println!("<- {m}"),
                    }
                    Ok(())
                }
            };
            if let Err(e) = r {
                break e;
            }
        };
        println!("receiver gone: {err}");
        process::exit(0);
    });
    let w = writer.clone();
    thread::spawn(move || {
        while send(&w, &json!({"type": "ping", "capFps": fps})).is_ok() {
            thread::sleep(Duration::from_secs(2));
        }
    });

    let period = Duration::from_secs_f64(1.0 / fps);
    let mut i = match args.get(4) {
        Some(s) => s.parse::<usize>()? % aus.len(),
        None => aus.iter().position(|a| a.0).unwrap(),
    };
    let mut next = Instant::now();
    let mut buf = Vec::new();
    loop {
        if kf.swap(false, Ordering::Relaxed) {
            i = (0..aus.len())
                .map(|d| (i + d) % aus.len())
                .find(|&j| aus[j].0)
                .unwrap();
            println!("kf requested: jumping to IDR at {i}");
        }
        let ts = now_ms() as u64;
        let prefix = format!(r#"{{"cap":{ts},"snd":{ts}}}"#);
        buf.clear();
        buf.extend_from_slice(&((prefix.len() + aus[i].1.len()) as u32).to_be_bytes());
        buf.extend_from_slice(prefix.as_bytes());
        buf.extend_from_slice(&aus[i].1);
        writer.lock().unwrap().write_all(&buf)?;
        i = (i + 1) % aus.len();
        next += period;
        thread::sleep(next.saturating_duration_since(Instant::now()));
    }
}

/// A 32x32 arrow, hotspot top-left.
const ARROW_PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAYElEQVR42u3XMQrAQAwDQf3/0wopDw5CEuzVgRfcD+osSRZcBMADIBGmERmAOwqRA6AQC4BA5AG6EVtAJyIX0IXIBnQgHgHViDMAlYgvACOAqhVeASoQ/nE4AP8ppun8LqWZ+xMAOnehAAAAAElFTkSuQmCC";

/// Circles the cursor. Prints how many messages the receiver should have dropped as stale:
/// one per TCP mirror (the second copy of each `s`) plus the injected ones, give or take one
/// per flow switch (a new flow resets the receiver's tracker).
fn cursor(w: &Mutex<TcpStream>, udp: Option<SocketAddr>, acks: &AtomicUsize) -> io::Result<()> {
    send(
        w,
        &json!({"type": "cursorImg", "nw": 32.0 / 1920.0, "nh": 32.0 / 1080.0, "ax": 0, "ay": 0, "png": ARROW_PNG}),
    )?;
    let flow = |to: SocketAddr| -> io::Result<UdpSocket> {
        let u = UdpSocket::bind(if to.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" })?;
        u.connect(to)?;
        println!("cursor: UDP flow {} -> {to}", u.local_addr()?);
        Ok(u)
    };
    let mut sock = udp.map(flow).transpose()?;
    let (mut s, mut mirrored, mut injected, mut flows, mut acks_at_flow) = (0u64, 0u64, 0u64, 1, 0);
    let msg = |x: f64, y: f64, s: u64| json!({"type": "cursor", "x": x, "y": y, "v": 1, "s": s});
    let start = Instant::now();
    let mut next = start;
    for tick in 1u64.. {
        let t = start.elapsed().as_secs_f64();
        let (x, y) = (0.5 + 0.3 * (t * 2.0).cos(), 0.5 + 0.3 * (t * 2.0).sin());
        if let (Some(to), true) = (udp, flows == 1 && t > 4.0) {
            sock = Some(flow(to)?);
            (flows, acks_at_flow) = (2, acks.load(Ordering::Relaxed));
        }
        s += 1;
        match &sock {
            Some(u) => {
                let _ = u.send(msg(x, y, s).to_string().as_bytes());
                if acks.load(Ordering::Relaxed) == acks_at_flow {
                    send(w, &msg(x, y, s))?;
                    mirrored += 1;
                } else if tick % 60 == 0 {
                    // Reordered pair (s+2 before s+1) and a stale repeat of an old s.
                    let _ = u.send(msg(x, y, s + 2).to_string().as_bytes());
                    let _ = u.send(msg(0.0, 0.0, s + 1).to_string().as_bytes());
                    let _ = u.send(msg(1.0, 1.0, s - 5).to_string().as_bytes());
                    (s, injected) = (s + 2, injected + 2);
                }
            }
            None => send(w, &msg(x, y, s))?,
        }
        if tick % 240 == 0 {
            println!(
                "cursor: s {s}, TCP mirrors {mirrored}, injected stale {injected}, expected receiver stale ~{}, acks {}",
                mirrored + injected,
                acks.load(Ordering::Relaxed)
            );
        }
        next += Duration::from_secs_f64(1.0 / 120.0);
        thread::sleep(next.saturating_duration_since(Instant::now()));
    }
    Ok(())
}

fn send(w: &Mutex<TcpStream>, msg: &Value) -> io::Result<()> {
    let p = msg.to_string();
    let mut buf = (p.len() as u32).to_be_bytes().to_vec();
    buf.extend_from_slice(p.as_bytes());
    w.lock().unwrap().write_all(&buf)
}

/// Receiver-to-sender frames are always JSON (§4).
fn read_msg(r: &mut impl Read, frames: &mut FrameReader) -> io::Result<Value> {
    loop {
        if let Some(p) = frames
            .next_frame()
            .map_err(|e| io::Error::new(ErrorKind::InvalidData, format!("{e:?}")))?
        {
            return serde_json::from_slice(p)
                .map_err(|e| io::Error::new(ErrorKind::InvalidData, e));
        }
        if frames.read_from(r)? == 0 {
            return Err(ErrorKind::UnexpectedEof.into());
        }
    }
}

fn discover() -> Result<String, Box<dyn Error>> {
    let mdns = ServiceDaemon::new()?;
    let rx = mdns.browse("_opensidecar._tcp.local.")?;
    let deadline = Instant::now() + Duration::from_secs(10);
    while let Ok(ev) = rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
        if let ServiceEvent::ServiceResolved(info) = ev {
            println!(
                "found {} id={:?} pv={:?} addrs={:?}",
                info.get_fullname(),
                info.get_property_val_str("id"),
                info.get_property_val_str("pv"),
                info.get_addresses()
            );
            if let Some(ip) = info.get_addresses_v4().iter().next() {
                return Ok(format!("{ip}:{}", info.get_port()));
            }
        }
    }
    Err("no _opensidecar._tcp receiver found in 10 s".into())
}
