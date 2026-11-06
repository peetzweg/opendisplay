//! The receiver binary's core against the fake sender over TCP. With `--sink
//! none` this needs no display and no GStreamer; the decode variant runs when
//! an H.264 decoder element is installed and is skipped otherwise.

use std::path::PathBuf;
use std::time::Duration;

use od_receiver::video::NullOutput;
#[cfg(feature = "gstreamer")]
use od_receiver::video::{SinkKind, VideoConfig};
use od_receiver::{Config, Receiver};
use opendisplay_proto::control::Hello;

fn testdata(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../testdata")
        .join(name)
}

fn hello() -> Hello {
    Hello {
        pixels_wide: 1920,
        pixels_high: 1080,
        scale: 1.0,
        device: Some("Linux".into()),
        id: Some("E2E".into()),
        ..Default::default()
    }
}

fn sender_opts(addr: std::net::SocketAddr, secs: f64) -> od_fake_sender::Options {
    od_fake_sender::Options {
        connect: addr,
        clip: testdata("clip-320x180-30.h264"),
        fps: 60.0,
        duration: Some(Duration::from_secs_f64(secs)),
        reconnect: false,
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
async fn null_sink_receives_stream_and_adopts_new_sender() {
    let cfg = Config {
        listen: "127.0.0.1:0".parse().unwrap(),
        hello: hello(),
        cursor_udp: true,
        stats_every: Duration::from_millis(500),
    };
    let rx = Receiver::bind(cfg, Box::new(NullOutput::default()))
        .await
        .unwrap();
    let addr = rx.local_addr().unwrap();
    assert_eq!(rx.hello().cursor_port, Some(addr.port() as u32 + 1));
    let (stop, stop_rx) = tokio::sync::watch::channel(false);
    let task = tokio::spawn(rx.run(stop_rx));

    let s1 = od_fake_sender::run(sender_opts(addr, 1.0)).await.unwrap();
    // run() returns once the last frame is written; give the receiver time to
    // see the first connection close, or the second sender counts as
    // replacing a live one (x86_64 runner on #298: adopted_over_live 2).
    tokio::time::sleep(Duration::from_millis(300)).await;
    // A second sender while the first is gone, then a third overlapping one.
    let s2 = tokio::spawn(od_fake_sender::run(sender_opts(addr, 1.5)));
    tokio::time::sleep(Duration::from_millis(500)).await;
    let s3 = od_fake_sender::run(sender_opts(addr, 0.7)).await.unwrap();
    let s2 = s2.await.unwrap().unwrap();
    stop.send(true).unwrap();
    let report = task.await.unwrap().unwrap();

    assert_eq!(s1.hellos, 1);
    assert!(s1.frames_sent >= 45, "{s1:?}");
    assert_eq!(report.connections, 3);
    assert_eq!(
        report.adopted_over_live, 1,
        "third sender replaced the live second one: {report:?}"
    );
    // The third sender proves itself by answering the provisional hello it
    // got while parked, then hears the full one once adopted: two welcomes.
    assert_eq!(report.welcomes, 4);
    assert_eq!(s3.hellos, 2, "{s3:?}");
    assert!(
        report.video_frames >= s1.frames_sent + s3.frames_sent,
        "{report:?} vs {s1:?} {s3:?}"
    );
    assert!(report.idr_frames >= 3);
    assert_eq!(report.decode_errors, 0);
    assert!(
        report.cursor_updates > 0,
        "cursor over TCP mirror while no UDP ack: {report:?}"
    );
    assert!(s2.frames_sent > 0);
}

#[cfg(feature = "gstreamer")]
#[tokio::test]
async fn decodes_with_fakesink_when_a_decoder_is_installed() {
    let video = match od_receiver::video::open(&VideoConfig {
        sink: SinkKind::Fake,
        decoder: "decodebin3".into(),
        fullscreen: false,
        output: None,
        videoconvert: true,
        gl: false,
    }) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("skipping decode test: {e:#}");
            return;
        }
    };
    let cfg = Config {
        listen: "127.0.0.1:0".parse().unwrap(),
        hello: hello(),
        cursor_udp: false,
        stats_every: Duration::from_millis(700),
    };
    let rx = Receiver::bind(cfg, video).await.unwrap();
    let addr = rx.local_addr().unwrap();
    let (stop, stop_rx) = tokio::sync::watch::channel(false);
    let task = tokio::spawn(rx.run(stop_rx));
    let mut o = sender_opts(addr, 2.0);
    o.switch_clip = Some(testdata("clip-640x360-30.h264"));
    o.switch_at = Some(Duration::from_millis(900));
    let s = od_fake_sender::run(o).await.unwrap();
    // The sender returns once its last frame is written; let the receiver
    // read it before stopping, or the count below is one short (seen on the
    // aarch64 runner: 120 of 121).
    tokio::time::sleep(Duration::from_millis(300)).await;
    stop.send(true).unwrap();
    let report = task.await.unwrap().unwrap();
    assert!(s.frames_sent >= 90, "{s:?}");
    if report.decode_errors == 0 {
        assert_eq!(report.video_frames, s.frames_sent);
        assert_eq!(report.decoder_resets, 2, "connect + SPS change: {report:?}");
    } else {
        // A hardware decoder that cannot feed this sink (a V4L2 stateless one
        // on Apple silicon, say) is skipped once; the session then drops
        // delta frames until the next IDR (§5.3).
        assert_eq!(report.decode_errors, 1, "one decoder fallback: {report:?}");
        assert!(report.video_frames >= s.frames_sent / 2, "{report:?}");
    }
    let rendered = report
        .rendered_frames
        .expect("gst backend counts rendered frames");
    assert!(
        rendered >= s.frames_sent / 2,
        "frames must reach the sink: rendered {rendered} of {}",
        s.frames_sent
    );
    let rendered = report
        .rendered_frames
        .expect("gst backend counts rendered frames");
    assert!(
        rendered >= s.frames_sent / 2,
        "frames must reach the sink: rendered {rendered} of {}",
        s.frames_sent
    );
}

/// #387: after `reset` (every reconnect, every parameter-set change) the
/// IDR that restarts decoding and the frames after it must share one
/// timeline. A flush that reset the running time re-based the live pipeline
/// asynchronously, so the IDR still carried the old running time and every
/// later frame the new one; the decoder stamped all of them with the IDR's
/// PTS and real sinks (GL, GTK) stopped presenting. fakesink does not care,
/// so this checks the timestamps reaching the sink instead: `take_decode_ms`
/// only reports frames whose PTS is not in the future.
#[cfg(feature = "gstreamer")]
#[test]
fn frames_after_a_reset_stay_on_one_timeline() {
    let mut video = match od_receiver::video::open(&VideoConfig {
        sink: SinkKind::Fake,
        decoder: "decodebin3".into(),
        fullscreen: false,
        output: None,
        videoconvert: true,
        gl: false,
    }) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("skipping reset timeline test: {e:#}");
            return;
        }
    };
    let clip = std::fs::read(testdata("clip-320x180-30.h264")).unwrap();
    let units = opendisplay_proto::video::access_units(&clip);
    assert!(units[0].is_idr);
    let play = |video: &mut Box<dyn od_receiver::video::VideoOutput>, secs: f64| {
        let start = std::time::Instant::now();
        for au in units.iter().cycle() {
            if start.elapsed().as_secs_f64() >= secs {
                break;
            }
            video.push(&au.annexb, au.is_idr).unwrap();
            std::thread::sleep(Duration::from_millis(16));
        }
    };
    // Long enough that the old running time is well ahead of a new one.
    play(&mut video, 1.5);
    std::thread::sleep(Duration::from_millis(200));
    if video.poll_error().is_some() || video.take_decode_ms().is_empty() {
        eprintln!("skipping reset timeline test: no frame decoded before the reset");
        return;
    }
    video.reset().unwrap();
    play(&mut video, 0.6);
    std::thread::sleep(Duration::from_millis(200));
    let after = video.take_decode_ms();
    assert!(
        after.len() >= 15,
        "frames after the reset must reach the sink on the current timeline: {} did",
        after.len()
    );
    assert!(
        after.iter().all(|&ms| ms < 500.0),
        "push -> sink times after the reset: {after:?}"
    );
}

/// A connection that reads `hello` and leaves (#435's Tailscale probe, a
/// §6.4 cable-upgrade probe that goes nowhere), or one that just sits
/// there, does not end the live session: newcomers prove themselves with
/// bytes first (§1).
#[tokio::test]
async fn silent_newcomers_leave_a_streaming_sender_alone() {
    use tokio::io::AsyncReadExt;

    let cfg = Config {
        listen: "127.0.0.1:0".parse().unwrap(),
        hello: hello(),
        cursor_udp: true,
        stats_every: Duration::from_millis(500),
    };
    let rx = Receiver::bind(cfg, Box::new(NullOutput::default()))
        .await
        .unwrap();
    let addr = rx.local_addr().unwrap();
    let (stop, stop_rx) = tokio::sync::watch::channel(false);
    let task = tokio::spawn(rx.run(stop_rx));

    let sender = tokio::spawn(od_fake_sender::run(sender_opts(addr, 2.0)));
    tokio::time::sleep(Duration::from_millis(500)).await;

    // The probe: connect, read hello, close without a byte.
    let mut probe = tokio::net::TcpStream::connect(addr).await.unwrap();
    let mut len = [0u8; 4];
    probe.read_exact(&mut len).await.unwrap();
    let mut payload = vec![0u8; u32::from_be_bytes(len) as usize];
    probe.read_exact(&mut payload).await.unwrap();
    let hello: serde_json::Value = serde_json::from_slice(&payload).unwrap();
    assert_eq!(hello["type"], "hello", "{hello}");
    assert!(
        hello.get("cursorPort").is_none(),
        "no UDP flow before it owns the session: {hello}"
    );
    drop(probe);

    // A newcomer that never says anything while the sender streams on.
    let lurker = tokio::net::TcpStream::connect(addr).await.unwrap();

    let s = sender.await.unwrap().unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    stop.send(true).unwrap();
    let report = task.await.unwrap().unwrap();
    drop(lurker);

    assert_eq!(s.hellos, 1, "{s:?}");
    assert!(s.frames_sent >= 110, "streamed to the end: {s:?}");
    assert_eq!(report.connections, 3, "{report:?}");
    assert_eq!(report.adopted_over_live, 0, "{report:?}");
    assert_eq!(report.welcomes, 1, "{report:?}");
    assert_eq!(report.video_frames, s.frames_sent, "{report:?} vs {s:?}");
}

/// `sleeping` before a suspend (logind in the binary, a fake here) and
/// `closing` on shutdown both reach the sender, and sleeping drops it.
#[tokio::test]
async fn sleeping_and_closing_reach_the_sender() {
    use od_receiver::power::PowerEvent;

    let cfg = Config {
        listen: "127.0.0.1:0".parse().unwrap(),
        hello: hello(),
        cursor_udp: false,
        stats_every: Duration::from_millis(500),
    };
    let (power_tx, power_rx) = tokio::sync::mpsc::unbounded_channel();
    let rx = Receiver::bind(cfg, Box::new(NullOutput::default()))
        .await
        .unwrap()
        .with_power(power_rx);
    let addr = rx.local_addr().unwrap();
    let (stop, stop_rx) = tokio::sync::watch::channel(false);
    let task = tokio::spawn(rx.run(stop_rx));

    // Sleep while a sender streams: it hears `sleeping` and is dropped well
    // before its 3 s run would end.
    let sender = tokio::spawn(od_fake_sender::run(sender_opts(addr, 3.0)));
    tokio::time::sleep(Duration::from_millis(700)).await;
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    power_tx
        .send(PowerEvent::Sleeping {
            done: Some(done_tx),
        })
        .unwrap();
    let s1 = tokio::time::timeout(Duration::from_secs(2), sender)
        .await
        .expect("sender dropped promptly")
        .unwrap()
        .unwrap();
    assert!(
        done_rx.try_recv().is_ok(),
        "the watcher hears sleeping went out"
    );
    assert_eq!(s1.sleeping_received, 1, "{s1:?}");

    // A sender still connected at shutdown hears `closing`.
    let sender = tokio::spawn(od_fake_sender::run(sender_opts(addr, 3.0)));
    tokio::time::sleep(Duration::from_millis(700)).await;
    stop.send(true).unwrap();
    let report = task.await.unwrap().unwrap();
    let s2 = sender.await.unwrap().unwrap();
    assert_eq!(report.sleeps, 1, "{report:?}");
    assert_eq!(s2.closing_received, 1, "{s2:?}");
}
