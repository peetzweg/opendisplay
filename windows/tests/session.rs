//! Drives the real listener over loopback: hello first, ping cadence, pong -> clock offset,
//! connection replacement, liveness timeout, oversize frames, video/control routing.

use od_receiver::control::{Hello, Incoming, Panel};
use od_receiver::framing::FrameReader;
use od_receiver::net::{self, Handler, Session};
use serde_json::{Value, json};
use std::io::{ErrorKind, Read, Write};
use std::net::TcpStream;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Default)]
struct Recorder {
    sessions: Mutex<Vec<Arc<Session>>>,
    video: Mutex<Vec<Vec<u8>>>,
    control: Mutex<Vec<String>>,
}

impl Handler for Recorder {
    fn connected(&self, s: &Arc<Session>) {
        self.sessions.lock().unwrap().push(s.clone());
    }
    fn video(&self, _: &Session, p: &[u8]) {
        self.video.lock().unwrap().push(p.to_vec());
    }
    fn control(&self, _: &Session, m: &Incoming) {
        self.control.lock().unwrap().push(format!("{m:?}"));
    }
}

fn start() -> (u16, Arc<Recorder>) {
    let listener = net::listen(0).unwrap();
    let port = listener.local_addr().unwrap().port();
    let rec = Arc::new(Recorder::default());
    let h = rec.clone();
    thread::spawn(move || {
        let hello = || Hello {
            pixels_wide: 2560,
            pixels_high: 1440,
            scale: 1.5,
            panel: Panel {
                pixels_wide: 2560,
                pixels_high: 1440,
                scale: 1.5,
            },
            device: "Windows".into(),
            id: "test-id".into(),
            pv: 3,
            display_max_frame_rate: 144,
            max_encode_wide: 4096,
            max_encode_high: 2304,
            cursor_port: None,
        };
        net::serve(listener, hello, h)
    });
    (port, rec)
}

struct Client {
    s: TcpStream,
    frames: FrameReader,
}

impl Client {
    fn connect(port: u16) -> Self {
        let s = TcpStream::connect(("127.0.0.1", port)).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        Self {
            s,
            frames: FrameReader::default(),
        }
    }
    /// Next message, or None on EOF/reset.
    fn recv(&mut self) -> Option<Value> {
        loop {
            if let Some(p) = self.frames.next_frame().unwrap() {
                return Some(serde_json::from_slice(p).unwrap());
            }
            match self.frames.read_from(&mut self.s) {
                Ok(0) => return None,
                Ok(_) => {}
                Err(e) if e.kind() == ErrorKind::TimedOut || e.kind() == ErrorKind::WouldBlock => {
                    panic!("client read timed out")
                }
                Err(_) => return None,
            }
        }
    }
    fn send_raw(&mut self, payload: &[u8]) {
        let mut b = (payload.len() as u32).to_be_bytes().to_vec();
        b.extend_from_slice(payload);
        self.s.write_all(&b).unwrap();
    }
    fn send(&mut self, v: Value) {
        self.send_raw(v.to_string().as_bytes());
    }
    /// Reads until EOF, returning how long it took.
    fn wait_closed(&mut self) -> Duration {
        let t = Instant::now();
        while self.recv().is_some() {}
        t.elapsed()
    }
}

fn wait_for(mut cond: impl FnMut() -> bool) {
    let t = Instant::now();
    while !cond() {
        assert!(
            t.elapsed() < Duration::from_secs(3),
            "condition not met in 3 s"
        );
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn hello_first_then_ping_and_clock_sync() {
    let (port, rec) = start();
    let mut c = Client::connect(port);
    let hello = c.recv().unwrap();
    assert_eq!(hello["type"], "hello");
    assert_eq!(hello["id"], "test-id");
    assert_eq!(hello["pv"], 3);
    assert_eq!(hello["panel"]["pixelsWide"], 2560);

    let ping = c.recv().unwrap();
    assert_eq!(ping["type"], "ping");
    let t = ping["t"].as_f64().unwrap();
    // Pretend the sender clock is 1000 ms ahead.
    c.send(json!({"type": "pong", "t": t, "mt": od_receiver::clock::now_ms() + 1000.0}));
    let s = rec.sessions.lock().unwrap()[0].clone();
    wait_for(|| s.clock.lock().unwrap().offset().is_some());
    let off = s.clock.lock().unwrap().offset().unwrap();
    assert!((off - 1000.0).abs() < 50.0, "offset {off}");

    c.send(json!({"type": "welcome", "pv": 3, "min": 1}));
    wait_for(|| s.sender_pv() == 3);

    // Pings keep coming roughly every 2 s.
    let t0 = Instant::now();
    assert_eq!(c.recv().unwrap()["type"], "ping");
    let gap = t0.elapsed();
    assert!(
        gap > Duration::from_millis(1500) && gap < Duration::from_millis(2600),
        "{gap:?}"
    );
}

#[test]
fn routes_video_and_control_frames() {
    let (port, rec) = start();
    let mut c = Client::connect(port);
    c.recv().unwrap();
    c.send_raw(b"{\"cap\":1,\"snd\":2}\x00\x00\x00\x01\x65\x88");
    c.send(json!({"type": "cursor", "x": 0.5, "y": 0.5, "v": 1}));
    c.send(json!({"type": "someFutureThing"}));
    c.send(json!({"type": "ping", "capFps": 60}));
    wait_for(|| rec.control.lock().unwrap().len() == 2);
    assert_eq!(rec.video.lock().unwrap().len(), 1);
    assert!(rec.control.lock().unwrap()[0].starts_with("Cursor"));
}

#[test]
fn new_connection_replaces_old() {
    let (port, rec) = start();
    let mut a = Client::connect(port);
    assert_eq!(a.recv().unwrap()["type"], "hello");
    let mut b = Client::connect(port);
    assert_eq!(b.recv().unwrap()["type"], "hello");
    assert!(a.wait_closed() < Duration::from_secs(1));
    let sessions = rec.sessions.lock().unwrap();
    assert_eq!(sessions.len(), 2);
    assert!(sessions[0].is_closed() && !sessions[1].is_closed());
}

#[test]
fn silent_sender_is_dropped_after_5s() {
    let (port, _) = start();
    let mut c = Client::connect(port);
    let took = c.wait_closed(); // we only read, never write
    assert!(
        took > Duration::from_millis(4500) && took < Duration::from_secs(7),
        "{took:?}"
    );
}

#[test]
fn chatty_sender_stays_connected() {
    let (port, rec) = start();
    let mut c = Client::connect(port);
    c.recv().unwrap();
    for _ in 0..4 {
        thread::sleep(Duration::from_secs(2));
        c.send(json!({"type": "ping"}));
    }
    assert!(!rec.sessions.lock().unwrap()[0].is_closed());
}

#[test]
fn oversize_frame_drops_connection() {
    let (port, _) = start();
    let mut c = Client::connect(port);
    c.recv().unwrap();
    c.s.write_all(&u32::MAX.to_be_bytes()).unwrap();
    assert!(c.wait_closed() < Duration::from_secs(1));
    let mut rest = Vec::new();
    let _ = c.s.read_to_end(&mut rest);
}
