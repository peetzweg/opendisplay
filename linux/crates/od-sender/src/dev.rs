//! `od-sender dev …`: developer self-tests, kept out of the user-facing CLI.

use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use clap::Subcommand;
use opendisplay_proto::control::{Scroll, Touch, TouchPhase};
use tracing::{info, warn};

use crate::backend::hyprland::ipc::HyprlandIpc;
use crate::backend::{
    CaptureEvent, CaptureOptions, DisplaySpec, FrameBuf, Pixels, Position, detect,
};
use crate::encoder;
use crate::wayland::{capture, input};

#[derive(Subcommand, Debug)]
pub enum Dev {
    /// List Hyprland monitors over IPC.
    Monitors,
    /// Create, size and remove a headless output through Hyprland IPC.
    HeadlessTest {
        #[arg(long, default_value = "od-test")]
        name: String,
        #[arg(long, default_value_t = 2560)]
        width: u32,
        #[arg(long, default_value_t = 1600)]
        height: u32,
        #[arg(long, default_value_t = 60)]
        hz: u32,
        #[arg(long, default_value_t = 2.0)]
        scale: f64,
        /// Keep the output alive this long before removing it.
        #[arg(long, default_value_t = 2.0)]
        hold: f64,
    },
    /// Encode synthetic frames to measure software encode cost on this machine.
    EncodeBench {
        #[arg(long, default_value_t = 1280)]
        width: u32,
        #[arg(long, default_value_t = 800)]
        height: u32,
        #[arg(long, default_value_t = 60)]
        frames: u32,
        #[arg(long, default_value_t = 0)]
        threads: u16,
        #[arg(long, default_value_t = 20.0)]
        bitrate_mbps: f32,
        /// H.264 encoder backend (#360).
        #[arg(long, value_enum, default_value_t = encoder::Backend::Auto)]
        encoder: encoder::Backend,
    },
    /// Create a headless output, move the pointer onto it via the virtual
    /// pointer protocol and verify the position through Hyprland IPC.
    /// With `--output`, use that existing output on any compositor with
    /// zwlr_virtual_pointer_v1 instead (no IPC; the caller checks the result).
    InputTest {
        #[arg(long, default_value_t = 0.25)]
        x: f64,
        #[arg(long, default_value_t = 0.75)]
        y: f64,
        /// Existing wl_output to move onto; skips Hyprland entirely.
        #[arg(long)]
        output: Option<String>,
        /// With `--output`: keep the virtual pointer alive this long.
        #[arg(long, default_value_t = 0.5)]
        hold: f64,
    },
    /// Capture an output via ext-image-copy-capture into shm and report frame timing.
    CaptureTest {
        /// wl_output name; default: first output.
        #[arg(long)]
        output: Option<String>,
        #[arg(long, default_value_t = 5.0)]
        seconds: f64,
        #[arg(long)]
        cursor: bool,
        /// Write the last frame as a PPM here.
        #[arg(long)]
        save: Option<std::path::PathBuf>,
        /// Capture protocol (wlr needs --output).
        #[arg(long, value_enum, default_value_t = crate::backend::capture::CaptureChoice::Ext)]
        capture: crate::backend::capture::CaptureChoice,
    },
    /// Follow the pointer cursor of an existing output through the
    /// ext-image-copy-capture cursor session (the cursor side channel's
    /// source) and log what would be sent: position, enter/leave, sprite.
    /// Creates nothing. On Hyprland <= 0.56.2, do not remove or disable the
    /// output while it runs: a pending cursor frame then crashes Hyprland.
    CursorTest {
        /// wl_output name, e.g. eDP-1 or an od-… output.
        #[arg(long)]
        output: String,
        #[arg(long, default_value_t = 10.0)]
        seconds: f64,
        /// Write the last sprite PNG here.
        #[arg(long)]
        save: Option<std::path::PathBuf>,
        /// Diagnostics: log every session event (constraints, ready/failed)
        /// and write each captured sprite's raw shm bytes into this directory
        /// as frame-N.raw with frame-N.txt (size, stride, byte order).
        #[arg(long, value_name = "DIR")]
        save_raw: Option<std::path::PathBuf>,
    },
    /// Capture -> encoded latency of the frame pipeline without a compositor:
    /// a synthetic 60 Hz source writing into shm buffers as the compositor
    /// would, then the session's handoff and encode loop.
    PipelineBench {
        /// Frame size, WxH.
        #[arg(long, default_value = "4096x2304")]
        size: String,
        #[arg(long, default_value_t = 8.0)]
        seconds: f64,
        #[arg(long, default_value_t = 60)]
        fps: u32,
        /// Copy each frame out of one shm buffer (the pre-lease capture).
        #[arg(long)]
        copy: bool,
        /// Let the encoder convert (no convert stage).
        #[arg(long)]
        no_stage: bool,
        #[arg(long, default_value_t = 0)]
        threads: u16,
        #[arg(long, value_enum, default_value_t = encoder::Backend::X264)]
        encoder: encoder::Backend,
    },
    /// Through the detected backend: open (or adopt) a display, capture and
    /// encode `--frames` frames while moving the pointer over it, scroll
    /// once, tear down. Exits non-zero on any failed step.
    Smoke {
        /// Display size, WxH.
        #[arg(long, default_value = "640x480")]
        size: String,
        #[arg(long, default_value_t = 30)]
        frames: u32,
        #[arg(long, default_value_t = 20.0)]
        timeout: f64,
        /// Output scale to ask for.
        #[arg(long, default_value_t = 1.0)]
        scale: f64,
        /// Where the output goes.
        #[arg(long, default_value = "auto-right")]
        position: Position,
        /// Show this workspace on the output (Hyprland, Sway), then hold the
        /// output for --hold seconds so the result can be inspected.
        #[arg(long)]
        workspace: Option<String>,
        /// Keep the output this long after capturing, in seconds.
        #[arg(long, default_value_t = 0.0)]
        hold: f64,
        #[command(flatten)]
        backend: crate::BackendArgs,
    },
}

pub fn threads_or_all(threads: u16) -> u16 {
    if threads == 0 {
        std::thread::available_parallelism()
            .map(|n| n.get() as u16)
            .unwrap_or(4)
    } else {
        threads
    }
}

pub fn run(cmd: Dev) -> Result<()> {
    match cmd {
        Dev::EncodeBench {
            width,
            height,
            frames,
            threads,
            bitrate_mbps,
            encoder: backend,
        } => encode_bench(width, height, frames, threads, bitrate_mbps, backend),
        Dev::PipelineBench {
            size,
            seconds,
            fps,
            copy,
            no_stage,
            threads,
            encoder,
        } => {
            let (w, h) = parse_size(&size)?;
            pipeline_bench(w, h, seconds, fps, copy, !no_stage, threads, encoder)
        }
        Dev::InputTest {
            x,
            y,
            output: Some(name),
            hold,
        } => {
            let injector = input::InputInjector::start(&name, 1.0)?;
            injector.move_to(x, y);
            std::thread::sleep(Duration::from_secs_f64(hold));
            info!("moved the virtual pointer to ({x},{y}) on {name}");
            Ok(())
        }
        Dev::InputTest {
            x, y, output: None, ..
        } => input_test(x, y),
        Dev::Monitors => {
            let ipc = HyprlandIpc::from_env()?;
            info!("{}", ipc.version()?);
            for m in ipc.monitors()? {
                info!(
                    "{} {}x{} @{:.0} scale {} at {},{} ({})",
                    m.name, m.width, m.height, m.refresh_rate, m.scale, m.x, m.y, m.description
                );
            }
            Ok(())
        }
        Dev::HeadlessTest {
            name,
            width,
            height,
            hz,
            scale,
            hold,
        } => {
            let ipc = HyprlandIpc::from_env()?;
            let t = Instant::now();
            ipc.create_headless(&name)?;
            let m = ipc.configure(&name, width, height, hz, scale, Position::AutoRight)?;
            info!(
                "created {} as {}x{} @{:.0} scale {} at {},{} in {:?}",
                m.name,
                m.width,
                m.height,
                m.refresh_rate,
                m.scale,
                m.x,
                m.y,
                t.elapsed()
            );
            std::thread::sleep(Duration::from_secs_f64(hold));
            ipc.remove_output(&name)?;
            info!(
                "removed {name}; monitors now: {:?}",
                ipc.monitors()?
                    .iter()
                    .map(|m| m.name.clone())
                    .collect::<Vec<_>>()
            );
            Ok(())
        }
        Dev::CaptureTest {
            output,
            seconds,
            cursor,
            save,
            capture,
        } => capture_test(output, seconds, cursor, save, capture),
        Dev::CursorTest {
            output,
            seconds,
            save,
            save_raw,
        } => cursor_test(&output, Duration::from_secs_f64(seconds), save, save_raw),
        Dev::Smoke {
            size,
            frames,
            timeout,
            scale,
            position,
            workspace,
            hold,
            backend,
        } => smoke(
            &backend.request(),
            &size,
            (scale, position),
            (workspace, Duration::from_secs_f64(hold)),
            frames,
            Duration::from_secs_f64(timeout),
        ),
    }
}

fn encode_bench(
    width: u32,
    height: u32,
    frames: u32,
    threads: u16,
    bitrate_mbps: f32,
    backend: encoder::Backend,
) -> Result<()> {
    let threads = threads_or_all(threads);
    let mut enc = encoder::Encoder::new(
        width,
        height,
        encoder::EncoderSettings {
            backend,
            bitrate_bps: (bitrate_mbps * 1e6) as u32,
            max_fps: 60.0,
            threads,
        },
    )?;
    let stride = width * 4;
    let mut frame = crate::backend::Frame {
        captured_at: Instant::now(),
        presentation_ns: None,
        buf: FrameBuf::Cpu {
            pixels: vec![0u8; (stride * height) as usize].into(),
            width,
            height,
            stride,
            format: crate::backend::PixelFormat::Xrgb8888,
        },
    };
    let mut times = Vec::new();
    let mut bytes = 0usize;
    for i in 0..frames {
        // Desktop-like content: text-ish noise blocks that shift each frame.
        if let FrameBuf::Cpu {
            pixels: Pixels::Owned(pixels),
            ..
        } = &mut frame.buf
        {
            for y in 0..height as usize {
                for x in 0..width as usize {
                    let v = (((x / 8 + y / 12 + i as usize) % 7) * 36) as u8;
                    let o = y * stride as usize + x * 4;
                    pixels[o] = v;
                    pixels[o + 1] = v / 2 + 60;
                    pixels[o + 2] = 255 - v;
                    pixels[o + 3] = 255;
                }
            }
        }
        let t = Instant::now();
        frame.captured_at = t;
        for e in enc.encode(&frame, i == 0)? {
            bytes += e.unit.annexb.len();
        }
        times.push(t.elapsed().as_secs_f64() * 1000.0);
    }
    times.sort_by(f64::total_cmp);
    let n = times.len();
    info!(
        "{} {width}x{height} {threads} threads: encode p50 {:.1} ms, p95 {:.1} ms, max {:.1} ms -> {:.0} fps sustainable; avg frame {:.0} KB",
        enc.label(),
        times[n / 2],
        times[(n as f64 * 0.95) as usize],
        times[n - 1],
        1000.0 / times[n / 2],
        bytes as f64 / n as f64 / 1024.0
    );
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn pipeline_bench(
    width: u32,
    height: u32,
    seconds: f64,
    fps: u32,
    copy: bool,
    use_stage: bool,
    threads: u16,
    backend: encoder::Backend,
) -> Result<()> {
    use std::os::unix::fs::FileExt;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    use crate::backend::{Frame, PixelFormat};
    use crate::latest;
    use crate::wayland::shm_pool::{Mapping, Recycler};

    let stride = width * 4;
    let len = (stride * height) as usize;
    // Eight desktop-like pictures that scroll, so every frame has motion.
    let pictures: Vec<Vec<u8>> = (0..8)
        .map(|i| {
            let mut px = vec![0u8; len];
            for y in 0..height as usize {
                for x in 0..width as usize {
                    let v = (((x / 8 + (y + i * 6) / 12) % 7) * 36) as u8;
                    let o = y * stride as usize + x * 4;
                    px[o..o + 4].copy_from_slice(&[v, v / 2 + 60, 255 - v, 255]);
                }
            }
            px
        })
        .collect();

    // The encode side, as in session.rs: latest-wins slot, rate cap, last
    // frame kept for an IDR replay.
    let settings = encoder::EncoderSettings {
        backend,
        bitrate_bps: 20_000_000,
        max_fps: fps as f32,
        threads: threads_or_all(threads),
    };
    let stage = encoder::ConvertStage::new();
    let enc_stage = stage.clone();
    let (raw_tx, raw_rx) = latest::channel::<Frame>();
    let stop = Arc::new(AtomicBool::new(false));
    let enc_stop = stop.clone();
    let encode = std::thread::spawn(move || -> Result<(Vec<f64>, Vec<f64>, &'static str)> {
        let mut enc: Option<encoder::Encoder> = None;
        let mut last: Option<Frame> = None;
        let (mut lat, mut enc_ms) = (Vec::new(), Vec::new());
        let min_interval = Duration::from_secs_f32(1.0 / settings.max_fps);
        let mut last_start = Instant::now() - min_interval;
        while !enc_stop.load(Ordering::Relaxed) {
            let Ok(frame) = raw_rx.recv_timeout(Duration::from_millis(100)) else {
                continue;
            };
            if let Some(wait) = min_interval.checked_sub(last_start.elapsed()) {
                std::thread::sleep(wait);
            }
            last_start = Instant::now();
            if enc.is_none() {
                let (w, h) = frame.dimensions();
                let e = encoder::Encoder::new(w, h, settings)?;
                enc_stage.bind(&e);
                enc = Some(e);
            }
            let e = enc.as_mut().unwrap();
            for u in e.encode(&frame, last.is_none())? {
                lat.push(u.captured_at.elapsed().as_secs_f64() * 1000.0);
                enc_ms.push(u.encode_ms);
            }
            last = Some(frame);
        }
        Ok((lat, enc_ms, enc.map_or("none", |e| e.label())))
    });
    let base: crate::backend::FrameSink = Box::new(move |ev| {
        if let CaptureEvent::Frame(f) = ev {
            raw_tx.send(f);
        }
    });
    let mut sink = if use_stage { stage.sink(base) } else { base };

    // The capture side: up to four shm buffers lent out (or one, copied out
    // per frame, as before leases), written by "the compositor" at `fps`.
    let recycler = Recycler::default();
    let mut buffers: Vec<(std::fs::File, Arc<Mapping>)> = Vec::new();
    let new_buffer = || -> Result<(std::fs::File, Arc<Mapping>)> {
        let path = format!(
            "/dev/shm/od-bench-{}-{}",
            std::process::id(),
            Instant::now().elapsed().as_nanos()
        );
        let f = std::fs::File::options()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&path)?;
        let _ = std::fs::remove_file(&path);
        f.set_len(len as u64)?;
        let m = Arc::new(Mapping::new(&f, len)?);
        Ok((f, m))
    };
    let period = Duration::from_secs_f64(1.0 / fps as f64);
    let start = Instant::now();
    let mut next = start;
    let mut i = 0usize;
    while start.elapsed().as_secs_f64() < seconds {
        let index = if copy {
            if buffers.is_empty() {
                buffers.push(new_buffer()?);
            }
            0
        } else {
            match recycler.take() {
                Some(x) => x,
                None if buffers.len() < 4 => {
                    buffers.push(new_buffer()?);
                    buffers.len() - 1
                }
                None => {
                    recycler.wait(Duration::from_millis(250));
                    continue;
                }
            }
        };
        if let Some(wait) = next.checked_duration_since(Instant::now()) {
            std::thread::sleep(wait);
        }
        next += period;
        let (file, map) = &buffers[index];
        file.write_all_at(&pictures[i % pictures.len()], 0)?;
        i += 1;
        let ready_at = Instant::now();
        let pixels = if copy {
            let mut v = vec![0u8; len];
            file.read_exact_at(&mut v, 0)?;
            Pixels::Owned(v)
        } else {
            Pixels::Leased(Box::new(recycler.lease(index, map.clone(), len)))
        };
        sink(CaptureEvent::Frame(Frame {
            captured_at: ready_at,
            presentation_ns: None,
            buf: FrameBuf::Cpu {
                pixels,
                width,
                height,
                stride,
                format: PixelFormat::Xrgb8888,
            },
        }));
    }
    drop(sink);
    std::thread::sleep(Duration::from_millis(300));
    stop.store(true, Ordering::Relaxed);
    let (mut lat, mut enc_ms, label) = encode.join().expect("encode thread")?;
    lat.sort_by(f64::total_cmp);
    enc_ms.sort_by(f64::total_cmp);
    let p = |v: &[f64], q: f64| {
        v.get(((v.len() as f64 - 1.0) * q).round() as usize)
            .copied()
            .unwrap_or(0.0)
    };
    info!(
        "{label} {width}x{height} {} {}: {} frames {:.1} fps | capture->encoded p50 {:.1} ms p95 {:.1} ms | encode call p50 {:.1} ms",
        if copy { "copy" } else { "lease" },
        if use_stage && width >= encoder::MIN_STAGE_WIDTH {
            "stage"
        } else {
            "no stage"
        },
        lat.len(),
        lat.len() as f64 / seconds,
        p(&lat, 0.5),
        p(&lat, 0.95),
        p(&enc_ms, 0.5),
    );
    Ok(())
}

fn input_test(x: f64, y: f64) -> Result<()> {
    let ipc = HyprlandIpc::from_env()?;
    let name = "od-input-test";
    let before = ipc.request("cursorpos")?.trim().to_string();
    ipc.create_headless(name)?;
    let m = ipc.configure(name, 1600, 1000, 60, 2.0, Position::AutoRight)?;
    let injector = input::InputInjector::start(name, m.scale)?;
    injector.move_to(x, y);
    std::thread::sleep(Duration::from_millis(150));
    let after = ipc.request("cursorpos")?.trim().to_string();
    // Expected in Hyprland's layout coordinates: monitor origin + normalised * logical size.
    let (lw, lh) = (m.width as f64 / m.scale, m.height as f64 / m.scale);
    let expect = (m.x as f64 + x * lw, m.y as f64 + y * lh);
    info!(
        "cursorpos before: {before}; after move to ({x},{y}) on {name}: {after}; expected ~({:.0}, {:.0})",
        expect.0, expect.1
    );
    drop(injector);
    ipc.remove_output(name)?;
    info!(
        "removed {name}; cursorpos now: {}",
        ipc.request("cursorpos")?.trim()
    );
    Ok(())
}

fn capture_test(
    output: Option<String>,
    seconds: f64,
    cursor: bool,
    save: Option<std::path::PathBuf>,
    protocol: crate::backend::capture::CaptureChoice,
) -> Result<()> {
    use crate::backend::capture::CaptureChoice;
    let mut last: Option<(capture::FrameInfo, crate::wayland::shm_pool::Lease)> = None;
    let keep = |info: &capture::FrameInfo, lease| {
        if save.is_some() {
            last = Some((*info, lease));
        }
    };
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let duration = Duration::from_secs_f64(seconds);
    let n = match protocol {
        CaptureChoice::Wlr => {
            let name = output.as_deref().context("--capture wlr needs --output")?;
            crate::wayland::screencopy::capture_wlr(name, cursor, duration, stop, keep)?
        }
        _ => capture::capture_shm(output.as_deref(), cursor, duration, stop, keep)?,
    };
    info!("{n} frames captured");
    if let (Some(path), Some((info, pixels))) = (save, last) {
        let mut ppm = format!("P6\n{} {}\n255\n", info.width, info.height).into_bytes();
        for row in pixels.chunks(info.stride as usize) {
            for px in row[..(info.width * 4) as usize].chunks(4) {
                // XRGB8888 / ARGB8888 little-endian: B, G, R, X
                ppm.extend_from_slice(&[px[2], px[1], px[0]]);
            }
        }
        std::fs::write(&path, ppm)?;
        info!("wrote {}", path.display());
    }
    Ok(())
}

fn cursor_test(
    output: &str,
    seconds: Duration,
    save: Option<std::path::PathBuf>,
    save_raw: Option<std::path::PathBuf>,
) -> Result<()> {
    use crate::backend::CursorEvent;
    let snap = crate::wayland::registry::snapshot()?;
    let o = snap
        .output(output)
        .with_context(|| format!("no output {output}"))?;
    let (w, h) = (o.width.max(1) as u32, o.height.max(1) as u32);
    // As the backends see it: Hyprland reports logical units (see
    // HyprlandOutput::cursor_space), others the protocol's pixels.
    let space = match HyprlandIpc::from_env().and_then(|ipc| ipc.monitors()) {
        Ok(ms) => {
            let scale = ms
                .iter()
                .find(|m| m.name == output)
                .map_or(1.0, |m| m.scale);
            let highest = ms.iter().map(|m| m.scale).fold(1.0f64, f64::max);
            crate::wayland::cursor::CursorSpace {
                width: w as f64 / scale,
                height: h as f64 / scale,
                sprite_scale: highest,
                theme_size: crate::wayland::cursor::theme_size(),
            }
        }
        Err(_) => crate::wayland::cursor::CursorSpace::pixels(w, h),
    };
    info!(
        "following the cursor on {output} ({w}x{h} px, positions in {:.1}x{:.1}, sprite scale up to {}, theme size {:?}) for {seconds:?}; move the pointer over it",
        space.width, space.height, space.sprite_scale, space.theme_size
    );
    let debug_sink: Option<crate::wayland::cursor::DebugSink> = match save_raw {
        Some(dir) => {
            use crate::wayland::cursor::CursorDebug;
            std::fs::create_dir_all(&dir)?;
            let mut n = 0u32;
            Some(Box::new(move |d: CursorDebug| match d {
                CursorDebug::Raw {
                    px,
                    width,
                    height,
                    stride,
                    format,
                } => {
                    n += 1;
                    let base = dir.join(format!("frame-{n}"));
                    let meta = format!("{width}x{height} stride {stride} order {format}\n");
                    let r = std::fs::write(base.with_extension("raw"), &px)
                        .and_then(|_| std::fs::write(base.with_extension("txt"), meta));
                    match r {
                        Ok(()) => info!("raw: wrote {}.raw ({} bytes)", base.display(), px.len()),
                        Err(e) => warn!("raw: {e}"),
                    }
                }
                other => info!("session: {other:?}"),
            }))
        }
        None => None,
    };
    let (tx, rx) = std::sync::mpsc::channel::<CursorEvent>();
    let mut thread = crate::wayland::cursor::CursorThread::spawn_with_debug(
        output,
        space,
        Box::new(move |ev| {
            let _ = tx.send(ev);
        }),
        debug_sink,
    )?;
    let start = Instant::now();
    let (mut moves, mut sprites) = (0u32, 0u32);
    let mut last_png = None;
    let mut last_log = Instant::now() - Duration::from_secs(1);
    while start.elapsed() < seconds {
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(CursorEvent::Moved { x, y }) => {
                moves += 1;
                if last_log.elapsed() >= Duration::from_millis(250) {
                    info!("cursor at {x:.4},{y:.4} ({moves} updates)");
                    last_log = Instant::now();
                }
            }
            Ok(CursorEvent::Hidden) => info!("cursor hidden (left {output})"),
            Ok(CursorEvent::SpriteUnavailable(why)) => warn!("no sprite: {why}"),
            Ok(CursorEvent::Image {
                png,
                nw,
                nh,
                ax,
                ay,
            }) => {
                sprites += 1;
                info!(
                    "sprite: {} bytes PNG, {:.4}x{:.4} of the display, hotspot {ax:.3},{ay:.3}",
                    png.len(),
                    nw,
                    nh
                );
                last_png = Some(png);
            }
            Err(_) => {}
        }
    }
    thread.stop();
    let rate = moves as f64 / seconds.as_secs_f64();
    info!("{moves} position updates ({rate:.0}/s), {sprites} sprites");
    match (save, last_png) {
        (Some(path), Some(png)) => {
            std::fs::write(&path, png)?;
            info!("wrote {}", path.display());
        }
        (Some(path), None) => warn!("no sprite arrived; {} not written", path.display()),
        _ => {}
    }
    Ok(())
}

fn parse_size(s: &str) -> Result<(u32, u32)> {
    let (w, h) = s
        .split_once('x')
        .with_context(|| format!("size {s:?}: expected WxH"))?;
    Ok((w.parse()?, h.parse()?))
}

/// TODO(§4.3): `--connect <addr>` to stream to `od-receiver --sink none`
/// instead of encoding locally.
fn smoke(
    req: &detect::Request,
    size: &str,
    (scale, position): (f64, Position),
    (workspace, hold): (Option<String>, Duration),
    frames: u32,
    timeout: Duration,
) -> Result<()> {
    let (width, height) = parse_size(size)?;
    let mut backend = detect::detect(req)?;
    info!("smoke: backend {}", backend.describe());
    let spec = DisplaySpec {
        name: "od-smoke".into(),
        width,
        height,
        hz: 60,
        scale,
        position,
    };
    let mut vd = backend.open(&spec)?;
    // With --workspace the smoke checks the placement leaves the user's focus
    // and pointer alone, so it injects no pointer motion (which would move
    // focus onto the output by itself) and needs just the first frame.
    let frames = if let Some(ws) = &workspace {
        let output = vd.info().name.clone();
        if backend.supports_workspaces() {
            backend.show_workspace(&output, ws)?;
            info!("smoke: workspace {ws} shown on {output}");
        } else {
            info!("smoke: workspaces are not supported on {}", backend.id());
        }
        1
    } else {
        frames
    };
    let move_pointer = workspace.is_none();
    info!("smoke: display {}", vd.info());

    let (tx, rx) = std::sync::mpsc::sync_channel::<CaptureEvent>(2);
    vd.start_capture(
        CaptureOptions { cursor: true },
        Box::new(move |ev| {
            let _ = tx.try_send(ev);
        }),
    )?;
    let mut input = vd.input()?;
    let mut enc: Option<encoder::Encoder> = None;
    let (mut captured, mut encoded) = (0u32, 0u32);
    let start = Instant::now();
    let mut step = 0u32;
    let result: Result<()> = (|| {
        while captured < frames {
            if start.elapsed() > timeout {
                bail!("only {captured}/{frames} frames within {timeout:?}");
            }
            // The cursor is painted into the frames, so motion is damage.
            if move_pointer {
                step += 1;
                let t = step as f64 * 0.05;
                input.touch(&Touch {
                    phase: TouchPhase::Moved,
                    x: 0.5 + 0.3 * t.cos(),
                    y: 0.5 + 0.3 * t.sin(),
                    t: None,
                });
            }
            match rx.recv_timeout(Duration::from_millis(30)) {
                Ok(CaptureEvent::Frame(f)) => {
                    captured += 1;
                    let (w, h) = f.dimensions();
                    let e = match &mut enc {
                        Some(e) => e,
                        None => enc.insert(encoder::Encoder::new(
                            w,
                            h,
                            encoder::EncoderSettings {
                                backend: encoder::Backend::Auto,
                                bitrate_bps: 8_000_000,
                                max_fps: 60.0,
                                threads: threads_or_all(0),
                            },
                        )?),
                    };
                    encoded += e.encode(&f, captured == 1)?.len() as u32;
                }
                Ok(CaptureEvent::Ended(why)) => bail!("capture ended: {why}"),
                Err(_) => {}
            }
        }
        if move_pointer {
            input.scroll(&Scroll { dx: 0.0, dy: 40.0 });
        }
        Ok(())
    })();
    drop(input);
    if !hold.is_zero() {
        info!("smoke: holding {} for {hold:?}", vd.info().name);
        std::thread::sleep(hold);
    }
    let closed = vd.close(false);
    result?;
    closed?;
    info!(
        "smoke ok: {captured} frames captured, {encoded} encoded ({}) in {:.1}s",
        enc.as_ref().map_or("-", |e| e.label()),
        start.elapsed().as_secs_f64()
    );
    Ok(())
}
