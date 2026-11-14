// Release builds run without a console (tray app); debug builds keep it for development.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use od_receiver::config::Config;
use od_receiver::control::{Hello, Panel};
use od_receiver::monitor::{self, MonitorInfo};
use od_receiver::{net, video, window};
use std::error::Error;
use std::fs::{self, File};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU16, Ordering};
use std::{env, io, thread};

fn main() {
    init_log();
    if let Err(e) = run() {
        log::error!("{e}");
        window::error_box(&format!("od-receiver could not start:\n\n{e}"));
        std::process::exit(1);
    }
}

/// `%LOCALAPPDATA%\od-receiver`, created if missing.
fn data_dir() -> io::Result<PathBuf> {
    let dir = PathBuf::from(env::var_os("LOCALAPPDATA").unwrap_or_else(|| ".".into()))
        .join("od-receiver");
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

/// Release builds log to `%LOCALAPPDATA%\od-receiver\od-receiver.log`, replaced on each start.
fn init_log() {
    let mut b = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"));
    if !cfg!(debug_assertions)
        && let Ok(f) = data_dir().and_then(|d| File::create(d.join("od-receiver.log")))
    {
        b.target(env_logger::Target::Pipe(Box::new(f)));
    }
    b.init();
}

fn run() -> Result<(), Box<dyn Error>> {
    monitor::enable_dpi_awareness();
    let path = Config::path();
    let cfg = Config::load(&path)?;
    log::info!("config {}: {cfg:?}", path.display());
    for (i, m) in monitor::all()?.iter().enumerate() {
        log::info!(
            "monitor {i}: {} {}x{} at ({}, {}) {} Hz{}",
            m.name(),
            m.width,
            m.height,
            m.left,
            m.top,
            m.refresh_hz,
            if m.primary { " primary" } else { "" }
        );
    }
    monitor::select(cfg.monitor.clone());
    let id = load_or_create_id()?;
    let name = cfg
        .name
        .clone()
        .unwrap_or_else(|| env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows PC".into()));
    let listener = net::listen(cfg.port)?;
    let _mdns = net::advertise(&name, &id, cfg.port)?;
    let udp = cfg.port.checked_add(1).and_then(|p| {
        net::bind_udp(p)
            .inspect_err(|e| log::warn!("UDP {p} unavailable ({e}): cursor over TCP only"))
            .ok()
    });
    // The cursorPort in hello; 0 while the UDP listener is not bound (§6.1).
    let cursor_port = Arc::new(AtomicU16::new(if udp.is_some() { cfg.port + 1 } else { 0 }));
    log::info!(
        "listening on TCP {} (cursor UDP {}) as {name:?}, id {id}, display {:?}",
        cfg.port,
        cursor_port.load(Ordering::Relaxed),
        monitor::current().map(|m| m.name())
    );
    let port = cursor_port.clone();
    let max = (cfg.max_encode_wide, cfg.max_encode_high);
    let mk = move || hello(&id, port.load(Ordering::Relaxed), max);
    let video = video::spawn(name.clone(), mk.clone())?;
    if let Some(sock) = udp {
        let v = video.clone();
        thread::Builder::new()
            .name("cursor-rx".into())
            .spawn(move || {
                let e = v.serve_cursor(&sock);
                drop(sock);
                log::error!("UDP cursor listener failed ({e}); withdrawing cursorPort");
                cursor_port.store(0, Ordering::Relaxed);
                v.rehello("cursor listener stopped");
            })?;
    }
    net::serve(listener, mk, video)?;
    Ok(())
}

fn hello(id: &str, cursor_port: u16, max_encode: (u32, u32)) -> Hello {
    let m = monitor::current().unwrap_or_else(|e| {
        log::warn!("monitor query failed ({e}); announcing 1920x1080@60");
        MonitorInfo::FALLBACK
    });
    // Limits are in the current orientation (§6.5).
    let max = if m.height > m.width {
        (max_encode.1, max_encode.0)
    } else {
        max_encode
    };
    Hello {
        pixels_wide: m.width,
        pixels_high: m.height,
        scale: m.scale,
        panel: Panel {
            pixels_wide: m.width,
            pixels_high: m.height,
            scale: m.scale,
        },
        device: "Windows".into(),
        id: id.into(),
        pv: od_receiver::PV,
        display_max_frame_rate: m.refresh_hz,
        max_encode_wide: max.0,
        max_encode_high: max.1,
        cursor_port: (cursor_port != 0).then_some(cursor_port),
    }
}

/// Stable per-install UUID, shared by the TXT record and hello (§2.1).
fn load_or_create_id() -> io::Result<String> {
    let path = data_dir()?.join("id");
    if let Ok(s) = fs::read_to_string(&path)
        && uuid::Uuid::parse_str(s.trim()).is_ok()
    {
        return Ok(s.trim().into());
    }
    let id = uuid::Uuid::new_v4().to_string();
    fs::write(&path, &id)?;
    Ok(id)
}
