//! End to end over a real TCP socket: the fake sender against a null-sink
//! receiver built on `ReceiverSession`. This is the CI conformance run.

use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use opendisplay_proto::control::Hello;
use opendisplay_session::Now;
use opendisplay_session::receiver::{
    ReceiverAction, ReceiverConfig, ReceiverEvent, ReceiverSession,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

fn testdata(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../testdata")
        .join(name)
}

#[derive(Debug, Default)]
struct Seen {
    welcome: u32,
    videos: u64,
    idrs: u64,
    resets: u32,
    dims: Vec<(u32, u32)>,
    stream_configs: u32,
    sender_health: u32,
    closes: u32,
}

/// Accepts connections one at a time (adopt-and-drop is not needed here) and
/// runs a ReceiverSession that discards video. Stops when `deadline` passes.
async fn null_receiver(listener: TcpListener, deadline: Instant) -> Seen {
    let start = Instant::now();
    let now = |start: Instant| {
        Now::new(
            start.elapsed(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs_f64()
                * 1000.0,
        )
    };
    let mut seen = Seen::default();
    let hello = Hello {
        pixels_wide: 1920,
        pixels_high: 1080,
        scale: 1.0,
        device: Some("Linux".into()),
        id: Some("e2e".into()),
        ..Default::default()
    };
    let mut cfg = ReceiverConfig::new(hello);
    cfg.first_ping_after = Duration::from_millis(100);
    let mut sess = ReceiverSession::new(cfg);
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return seen;
        }
        let Ok(Ok((mut stream, _))) = tokio::time::timeout(remaining, listener.accept()).await
        else {
            return seen;
        };
        let mut buf = vec![0u8; 256 * 1024];
        let mut tick = tokio::time::interval(Duration::from_millis(50));
        let mut actions = sess.handle(now(start), ReceiverEvent::Connected);
        loop {
            for a in actions.drain(..) {
                match a {
                    ReceiverAction::Send(b) => {
                        let _ = stream.write_all(&b).await;
                    }
                    ReceiverAction::ResetDecoder => seen.resets += 1,
                    ReceiverAction::Video(v) => {
                        seen.videos += 1;
                        if v.is_idr {
                            seen.idrs += 1;
                        }
                        if let Some(s) = v.sps {
                            if seen.dims.last() != Some(&(s.width, s.height)) {
                                seen.dims.push((s.width, s.height));
                            }
                        }
                    }
                    ReceiverAction::Welcome(_) => seen.welcome += 1,
                    ReceiverAction::StreamConfig(_) => seen.stream_configs += 1,
                    ReceiverAction::SenderHealth(_) => seen.sender_health += 1,
                    ReceiverAction::Close(_) => seen.closes += 1,
                    _ => {}
                }
            }
            if !sess.is_connected() {
                break;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return seen;
            }
            actions = tokio::select! {
                r = stream.read(&mut buf) => match r {
                    Ok(0) | Err(_) => { sess.handle(now(start), ReceiverEvent::Disconnected); break; }
                    Ok(n) => sess.handle(now(start), ReceiverEvent::Bytes(&buf[..n])),
                },
                _ = tick.tick() => sess.handle(now(start), ReceiverEvent::Tick),
                _ = tokio::time::sleep(remaining) => return seen,
            };
        }
    }
}

fn base_options(addr: std::net::SocketAddr, secs: f64) -> od_fake_sender::Options {
    od_fake_sender::Options {
        connect: addr,
        clip: testdata("clip-320x180-30.h264"),
        fps: 60.0,
        duration: Some(Duration::from_secs_f64(secs)),
        reconnect: true,
        drop_every: None,
        pause_at: None,
        pause_for: Duration::from_secs(1),
        switch_clip: None,
        switch_at: None,
        cursor: true,
        stats_every: Duration::from_secs(60),
    }
}

#[tokio::test]
async fn streams_video_after_handshake() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let rx = tokio::spawn(null_receiver(
        listener,
        Instant::now() + Duration::from_millis(2500),
    ));
    let summary = od_fake_sender::run(base_options(addr, 2.0)).await.unwrap();
    let seen = rx.await.unwrap();
    assert_eq!(summary.connections, 1);
    assert_eq!(summary.hellos, 1);
    assert_eq!(seen.welcome, 1);
    assert!(
        seen.videos >= 60,
        "got {} frames in 2 s at 60 fps",
        seen.videos
    );
    assert!(
        seen.idrs >= 2,
        "IDR on connect plus at least one GOP boundary: {}",
        seen.idrs
    );
    assert_eq!(seen.dims, vec![(320, 180)]);
    assert_eq!(seen.resets, 1, "only the connect-time reset");
    assert_eq!(seen.closes, 0);
    assert_eq!(
        summary.frames_sent, seen.videos,
        "every sent frame was decodable in order"
    );
}

#[tokio::test]
async fn clip_switch_is_a_parameter_set_change() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let rx = tokio::spawn(null_receiver(
        listener,
        Instant::now() + Duration::from_millis(2500),
    ));
    let mut o = base_options(addr, 2.0);
    o.switch_clip = Some(testdata("clip-640x360-30.h264"));
    o.switch_at = Some(Duration::from_millis(800));
    od_fake_sender::run(o).await.unwrap();
    let seen = rx.await.unwrap();
    assert_eq!(seen.dims, vec![(320, 180), (640, 360)]);
    assert_eq!(seen.resets, 2, "connect + SPS change");
    assert_eq!(seen.stream_configs, 1);
}

#[tokio::test]
async fn pause_times_out_and_reconnects() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    // Receiver liveness is 5 s; pause 6 s at t=0.5 s; sender redials ~1 s after EOF.
    let rx = tokio::spawn(null_receiver(
        listener,
        Instant::now() + Duration::from_millis(9500),
    ));
    let mut o = base_options(addr, 9.0);
    o.pause_at = Some(Duration::from_millis(500));
    o.pause_for = Duration::from_secs(6);
    let summary = od_fake_sender::run(o).await.unwrap();
    let seen = rx.await.unwrap();
    assert_eq!(seen.closes, 1, "receiver closed on liveness timeout");
    assert!(summary.connections >= 2, "sender redialed: {summary:?}");
    assert!(seen.welcome >= 2);
    assert!(
        seen.idrs >= 2,
        "stream restarted with an IDR after reconnect"
    );
}
