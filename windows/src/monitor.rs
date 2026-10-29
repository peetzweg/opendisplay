//! Display facts for `hello`, from Win32. This is part of the small FFI layer: all `unsafe` lives here.

use crate::config::MonitorSel;
use std::sync::OnceLock;
use windows::Win32::Foundation::{LPARAM, RECT};
use windows::Win32::Graphics::Gdi::{
    DEVMODEW, ENUM_CURRENT_SETTINGS, EnumDisplayMonitors, EnumDisplaySettingsW, GetMonitorInfoW,
    HDC, HMONITOR, MONITORINFO, MONITORINFOEXW,
};
use windows::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, GetDpiForMonitor, MDT_EFFECTIVE_DPI,
    SetProcessDpiAwarenessContext,
};
use windows::Win32::UI::WindowsAndMessaging::MONITORINFOF_PRIMARY;
use windows::core::{BOOL, PCWSTR};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MonitorInfo {
    /// Top-left corner on the virtual desktop, physical pixels.
    pub left: i32,
    pub top: i32,
    /// Physical pixels in the current orientation.
    pub width: u32,
    pub height: u32,
    /// DPI scale, e.g. 1.0 / 1.5 / 2.0.
    pub scale: f64,
    pub refresh_hz: u32,
    pub primary: bool,
    /// GDI device name (`\\.\DISPLAY1`), NUL-padded; matches `DXGI_OUTPUT_DESC::DeviceName`.
    pub device: [u16; 32],
}

impl MonitorInfo {
    /// Used when no monitor can be queried.
    pub const FALLBACK: Self = Self {
        left: 0,
        top: 0,
        width: 1920,
        height: 1080,
        scale: 1.0,
        refresh_hz: 60,
        primary: true,
        device: [0; 32],
    };

    pub fn name(&self) -> String {
        String::from_utf16_lossy(
            &self.device[..self.device.iter().position(|&c| c == 0).unwrap_or(32)],
        )
    }
}

static SELECTION: OnceLock<Option<MonitorSel>> = OnceLock::new();

/// Must run before any window or DPI query so we see physical pixels and the real DPI.
pub fn enable_dpi_awareness() {
    // SAFETY: process-wide flag with no pointers; failure (already set) is harmless.
    let _ = unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
}

/// Sets which monitor [`current`] returns (None: primary). First call wins.
pub fn select(sel: Option<MonitorSel>) {
    let _ = SELECTION.set(sel);
}

/// The configured monitor, or the primary one if none is configured or it is not connected.
pub fn current() -> windows::core::Result<MonitorInfo> {
    let all = all()?;
    let found = match SELECTION.get().and_then(Option::as_ref) {
        Some(MonitorSel::Index(i)) => all.get(*i),
        Some(MonitorSel::Name(n)) => all.iter().find(|m| m.name().eq_ignore_ascii_case(n)),
        None => None,
    };
    if found.is_none() && SELECTION.get().is_some_and(Option::is_some) {
        log::warn!(
            "configured monitor {:?} not found; using the primary",
            SELECTION.get().unwrap()
        );
    }
    found
        .or_else(|| all.iter().find(|m| m.primary))
        .or(all.first())
        .copied()
        .ok_or_else(|| {
            windows::core::Error::new(windows::Win32::Foundation::E_FAIL, "no monitor connected")
        })
}

/// Every monitor, in Windows' enumeration order (the order config indexes refer to).
pub fn all() -> windows::core::Result<Vec<MonitorInfo>> {
    unsafe extern "system" fn push(hmon: HMONITOR, _: HDC, _: *mut RECT, out: LPARAM) -> BOOL {
        // SAFETY: `out` is the &mut Vec passed below, alive for the whole enumeration.
        unsafe { (*(out.0 as *mut Vec<HMONITOR>)).push(hmon) };
        true.into()
    }
    let mut handles: Vec<HMONITOR> = Vec::new();
    // SAFETY: the callback only pushes into `handles`, which outlives the synchronous call.
    unsafe {
        EnumDisplayMonitors(
            None,
            None,
            Some(push),
            LPARAM(&mut handles as *mut _ as isize),
        )
    }
    .ok()?;
    handles.into_iter().map(info).collect()
}

fn info(hmon: HMONITOR) -> windows::core::Result<MonitorInfo> {
    // SAFETY: Win32 queries writing into stack-owned structs whose size fields are set as the APIs require;
    // MONITORINFOEXW starts with MONITORINFO, so the pointer cast is the documented usage.
    unsafe {
        let mut mi = MONITORINFOEXW::default();
        mi.monitorInfo.cbSize = size_of::<MONITORINFOEXW>() as u32;
        GetMonitorInfoW(hmon, &mut mi as *mut _ as *mut MONITORINFO).ok()?;

        let mut dm = DEVMODEW {
            dmSize: size_of::<DEVMODEW>() as u16,
            ..Default::default()
        };
        EnumDisplaySettingsW(PCWSTR(mi.szDevice.as_ptr()), ENUM_CURRENT_SETTINGS, &mut dm).ok()?;

        let (mut dpi_x, mut dpi_y) = (96, 96);
        GetDpiForMonitor(hmon, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y)?;

        Ok(MonitorInfo {
            left: mi.monitorInfo.rcMonitor.left,
            top: mi.monitorInfo.rcMonitor.top,
            width: dm.dmPelsWidth,
            height: dm.dmPelsHeight,
            scale: dpi_x as f64 / 96.0,
            // 0 and 1 mean "hardware default" per DEVMODE docs.
            refresh_hz: if dm.dmDisplayFrequency > 1 {
                dm.dmDisplayFrequency
            } else {
                60
            },
            primary: mi.monitorInfo.dwFlags & MONITORINFOF_PRIMARY != 0,
            device: mi.szDevice,
        })
    }
}
