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
    assert_eq!(report.welcomes, 3);
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
    stop.send(true).unwrap();
    let report = task.await.unwrap().unwrap();
    assert!(s.frames_sent >= 90, "{s:?}");
    assert_eq!(report.video_frames, s.frames_sent);
    assert_eq!(report.decoder_resets, 2, "connect + SPS change: {report:?}");
    assert_eq!(report.decode_errors, 0, "{report:?}");
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
