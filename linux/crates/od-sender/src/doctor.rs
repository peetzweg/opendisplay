//! `od-sender doctor`: what the sender would use on this desktop and why.
//! Read-only: it creates no output and takes no lock.

use std::path::{Path, PathBuf};

use crate::backend::detect::{self, Decision, Environment, Request};
use crate::backend::hyprland::{self, instance, ipc::HyprlandIpc};
use crate::backend::lock;
use crate::config::{self, Config, Layer};
use crate::encoder;
use crate::wayland::registry::{self, INTERESTING};

/// Outputs earlier senders made on Sway, from their records.
fn wlroots_report() {
    for (lock_name, rec) in crate::backend::wlroots::record::all() {
        // Read-only: the pid the last holder wrote, not a lock attempt.
        let state = match lock::holder_pid(&lock_name) {
            Some(pid) if std::path::Path::new(&format!("/proc/{pid}")).exists() => {
                format!("held by pid {pid}")
            }
            _ => "left behind; `od-sender clean` removes it".into(),
        };
        println!("  {lock_name} -> {} ({state})", rec.output);
    }
}

/// Prints the report; returns `false` on an unsupported desktop.
pub fn doctor(req: &Request, config_path: Option<&Path>) -> bool {
    println!("od-sender {}", env!("OD_SENDER_VERSION"));
    let config_ok = config_report(config_path);
    let env = Environment::from_process();

    let snapshot = env.wayland_display.as_ref().map(|_| registry::snapshot());
    let walk = detect::decide(&env, req, &mut || match &snapshot {
        Some(Ok(s)) => Ok(s.clone()),
        Some(Err(e)) => Err(anyhow::anyhow!("{e:#}")),
        None => Err(anyhow::anyhow!("WAYLAND_DISPLAY not set")),
    });

    println!("\ndetection:");
    for s in &walk.steps {
        println!("  {s}");
    }
    let mut supported = match &walk.decision {
        Decision::Hyprland { socket } => {
            println!("  => hyprland ({})", socket.display());
            hyprland_report(socket.clone())
        }
        Decision::Wlroots { swaysock } => {
            println!("  => wlroots ({})", swaysock.display());
            wlroots_report();
            true
        }
        Decision::Kde => {
            println!("  => kde");
            true
        }
        Decision::Gnome => {
            // `instantiate` below probes Mutter's D-Bus APIs and prints their versions.
            println!("  => gnome (Mutter ScreenCast/RemoteDesktop over D-Bus)");
            true
        }
        Decision::Adopt { output } => {
            println!("  => adopt output {output}");
            true
        }
        Decision::Unsupported(m) => {
            println!("  => unsupported: {m}");
            false
        }
    };
    if supported {
        match detect::instantiate(walk.decision.clone()) {
            Ok(b) => {
                println!("  {}: {}\n  {}", b.id(), b.describe(), b.caps());
                let snap = snapshot.as_ref().and_then(|s| s.as_ref().ok());
                match detect::choose_capture(b.as_ref(), req.capture, snap) {
                    Ok(Some(sel)) => println!("  capture: {} ({})", sel.path, sel.reason),
                    Ok(None) => println!("  capture: n/a (PipeWire)"),
                    Err(e) => {
                        println!("  capture: none ({e:#})");
                        supported = false;
                    }
                }
            }
            Err(e) => {
                println!("  cannot start the backend: {e:#}");
                supported = false;
            }
        }
    }

    println!(
        "\nwayland ({}):",
        env.wayland_display.as_deref().unwrap_or("unset")
    );
    match &snapshot {
        Some(Ok(s)) => {
            for g in INTERESTING {
                match s.globals.iter().find(|(i, _)| i == g) {
                    Some((_, v)) => println!("  {g} v{v}"),
                    None => println!("  {g}: absent"),
                }
            }
            for o in &s.outputs {
                println!(
                    "  output {} {}x{} @{:.2} scale {} at {},{}",
                    o.name,
                    o.width,
                    o.height,
                    o.refresh_mhz as f64 / 1000.0,
                    o.fractional_scale(),
                    o.x,
                    o.y
                );
            }
        }
        Some(Err(e)) => println!("  cannot connect: {e:#}"),
        None => println!("  not connected"),
    }

    if let Some(rt) = &env.runtime_dir {
        if let Ok(all) = instance::list(rt) {
            if !all.is_empty() {
                println!("\nhyprland instances (--instance <index|signature>):");
                for (i, x) in all.iter().enumerate() {
                    let current = env.hyprland_signature.as_deref() == Some(&x.signature);
                    println!(
                        "  {i}: {} pid {} {}{}",
                        x.signature,
                        x.pid,
                        x.wl_socket,
                        if current { " (selected)" } else { "" }
                    );
                }
            }
        }
    }

    println!("\nencoders:");
    for b in [
        encoder::Backend::V4l2m2m,
        encoder::Backend::X264,
        encoder::Backend::Openh264,
    ] {
        if b == encoder::Backend::V4l2m2m && !encoder::v4l2m2m_present() {
            // Only some ARM SoCs have one; its absence is not a fault (#409).
            println!("  {b:?}: not present (no V4L2 H.264 encoder device)");
            continue;
        }
        let s = encoder::EncoderSettings {
            backend: b,
            bitrate_bps: 2_000_000,
            max_fps: 60.0,
            threads: 1,
        };
        match encoder::Encoder::new(320, 240, s) {
            Ok(e) => println!("  {}: ok", e.label()),
            Err(e) => println!("  {b:?}: unavailable ({e:#})"),
        }
    }
    println!("  (x264 and OpenH264 encode on the CPU; VA-API is not supported yet)");

    println!("\nusb transport (usbmuxd):");
    if std::path::Path::new(crate::usbmux::USBMUXD_SOCKET).exists() {
        println!("  {}: present", crate::usbmux::USBMUXD_SOCKET);
    } else {
        println!(
            "  {}: absent (start usbmuxd to connect over USB cable)",
            crate::usbmux::USBMUXD_SOCKET
        );
    }

    let dir: PathBuf = lock::dir();
    println!("\nlocks: {}", dir.display());
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for e in entries.flatten() {
            println!("  {}", e.file_name().to_string_lossy());
        }
    }
    supported && config_ok
}

fn layer_line(l: &Layer) -> String {
    let mut parts = Vec::new();
    if let Some(p) = l.position {
        parts.push(format!("position {p:?}"));
    }
    if let Some(s) = l.scale {
        parts.push(format!("scale {s:?}"));
    }
    if let Some(b) = l.bitrate_mbps {
        parts.push(format!("bitrate-mbps {b}"));
    }
    if let Some(w) = &l.workspace {
        parts.push(format!("workspace {w}"));
    }
    if parts.is_empty() {
        "(nothing)".into()
    } else {
        parts.join(", ")
    }
}

/// Prints where the config comes from and what it sets; `false` when it
/// does not parse (`run` would refuse it).
fn config_report(explicit: Option<&Path>) -> bool {
    let (path, required) = match explicit {
        Some(p) => (Some(p.to_path_buf()), true),
        None => (config::default_path(), false),
    };
    println!("\nconfig:");
    let Some(path) = path else {
        println!("  no path (neither XDG_CONFIG_HOME nor HOME set)");
        return true;
    };
    let exists = path.exists();
    println!(
        "  {} ({})",
        path.display(),
        if exists {
            "found"
        } else {
            "absent: built-in defaults"
        }
    );
    match Config::load(&path, required) {
        Ok(c) => {
            if exists {
                let opt = |v: Option<String>| v.unwrap_or_else(|| "-".into());
                println!("  to {}", opt(c.to.clone()));
                println!("  {}", layer_line(&c.defaults));
                println!(
                    "  max-fps {}, encoder {}, cursor {}, capture {}",
                    opt(c.max_fps.map(|f| f.to_string())),
                    opt(c.encoder.map(|e| format!("{e:?}"))),
                    opt(c.cursor.map(|m| format!("{m:?}").to_lowercase())),
                    opt(c.capture.map(|m| format!("{m:?}").to_lowercase()))
                );
                for (k, l) in &c.receivers {
                    println!("  [receiver.\"{k}\"] {}", layer_line(l));
                }
            }
            true
        }
        Err(e) => {
            println!("  error: {e:#}");
            false
        }
    }
}

fn hyprland_report(socket: PathBuf) -> bool {
    let ipc = HyprlandIpc::new(socket.clone());
    match ipc.version_info() {
        Ok(v) => {
            let ok = v
                .triple()
                .is_some_and(|(maj, min, _)| (maj, min) >= hyprland::MIN_VERSION);
            println!(
                "  version {} ({})",
                v.version,
                match v.triple() {
                    Some((a, b, _)) if (a, b) < hyprland::MIN_VERSION => "too old: needs 0.55+",
                    Some((a, b, _)) if (a, b) > hyprland::TESTED_UP_TO => "newer than tested",
                    Some(_) => "tested",
                    None => "unparseable",
                }
            );
            match ipc.option("ecosystem:enforce_permissions") {
                Ok(o) if o.get("bool").and_then(|b| b.as_bool()) == Some(true) => println!(
                    "  ecosystem:enforce_permissions = true: allow screencopy for od-sender with an hl.permission rule, or it streams black frames"
                ),
                Ok(_) => println!("  ecosystem:enforce_permissions = false"),
                Err(e) => println!("  ecosystem:enforce_permissions: {e:#}"),
            }
            if let Ok(ms) = ipc.monitors() {
                for m in ms {
                    println!(
                        "  monitor {} {}x{} @{:.2} scale {} at {},{}",
                        m.name, m.width, m.height, m.refresh_rate, m.scale, m.x, m.y
                    );
                }
            }
            ok
        }
        Err(e) => {
            println!("  IPC error: {e:#}");
            false
        }
    }
}
