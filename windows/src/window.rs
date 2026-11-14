//! The borderless fullscreen window and its UI thread. Part of the small FFI layer: all window
//! `unsafe` lives here.
//!
//! The window has its own thread so its message loop never waits on decode. Input, display
//! changes, session lock and quit (Alt+F4 or the tray icon) are handed to the app as [`Event`]s.
//! The decode thread presents into the window (DXGI allows presenting from any thread) and polls
//! the flags in [`Ui`].

use crate::control::{Outgoing, PencilPhase, TouchPhase};
use crate::monitor::{self, MonitorInfo};
use std::cell::{OnceCell, RefCell};
use std::ffi::c_void;
use std::io;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::Graphics::Gdi::ScreenToClient;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::RemoteDesktop::{
    NOTIFY_FOR_THIS_SESSION, WTSRegisterSessionNotification,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{ReleaseCapture, SetCapture, VK_F2};
use windows::Win32::UI::Input::Pointer::{
    GetPointerInfo, GetPointerPenInfo, GetPointerType, POINTER_INFO, POINTER_PEN_INFO,
};
use windows::Win32::UI::Shell::{
    NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFY_ICON_MESSAGE, NOTIFYICONDATAW,
    Shell_NotifyIconW,
};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{HSTRING, w};

/// Window pixels one wheel notch (120 units) scrolls: 3 lines of 16 px, like a default
/// Windows text view at 100% scale.
const NOTCH_PX: f64 = 48.0;
/// Window and tray icon (own design, see assets/make_logo.py).
const ICO: &[u8] = include_bytes!("../assets/logo.ico");
/// Tray icon notifications.
const WM_TRAY: u32 = WM_APP + 1;
const MENU_QUIT: usize = 1;

/// What the UI thread reports to the app. The handler runs on the UI thread and must not block
/// for long.
pub enum Event {
    /// The monitor's size, position, refresh rate or DPI scale changed.
    DisplayChanged,
    /// Input for the sender, `t` unset.
    Input(Outgoing),
    /// The user quit; the process exits when the handler returns.
    Quit,
    /// The Windows session was locked (true) or unlocked (false).
    Locked(bool),
}

/// State shared with the decode thread.
pub struct Ui {
    hwnd: isize,
    /// The client area changed size; the presenter resizes its swap chain.
    pub resized: AtomicBool,
    /// F2 toggles the timing overlay.
    pub overlay: AtomicBool,
    /// Where the video is drawn in client pixels, x | y << 16 | w << 32 | h << 48; 0 while no video.
    video_rect: AtomicU64,
    /// Decoded video size, w | h << 32, to convert scroll deltas to video pixels.
    video_size: AtomicU64,
}

impl Ui {
    pub fn hwnd(&self) -> HWND {
        HWND(self.hwnd as *mut c_void)
    }

    /// Records what is on screen: the video's client rect and decoded size, or None without video.
    pub fn set_video(&self, rect: (u32, u32, u32, u32), size: Option<(u32, u32)>) {
        let (r, s) = size.map_or((0, 0), |s| {
            let r = rect.0 as u64
                | (rect.1 as u64) << 16
                | (rect.2 as u64) << 32
                | (rect.3 as u64) << 48;
            (r, s.0 as u64 | (s.1 as u64) << 32)
        });
        self.video_rect.store(r, Ordering::Relaxed);
        self.video_size.store(s, Ordering::Relaxed);
    }
}

/// Client pixel -> normalized video position (clamped to 0..1), and whether it is inside the
/// video. None while no video is shown.
pub fn normalize(rect: u64, px: i32, py: i32) -> Option<(f64, f64, bool)> {
    let f = |shift: u32| (rect >> shift & 0xFFFF) as f64;
    let (rx, ry, rw, rh) = (f(0), f(16), f(32), f(48));
    if rw == 0.0 || rh == 0.0 {
        return None;
    }
    let (x, y) = ((px as f64 - rx) / rw, (py as f64 - ry) / rh);
    Some((
        x.clamp(0.0, 1.0),
        y.clamp(0.0, 1.0),
        (0.0..1.0).contains(&x) && (0.0..1.0).contains(&y),
    ))
}

/// Windows pen tilt (degrees from vertical along x and y; +y tilts toward the user) -> (azimuth,
/// altitude) in radians. Azimuth is the barrel's direction on screen as atan2(y, x) with y down;
/// altitude π/2 is perpendicular.
pub fn tilt(tx: f64, ty: f64) -> (f64, f64) {
    let (a, b) = (tx.to_radians().tan(), ty.to_radians().tan());
    let r = a.hypot(b);
    (if r == 0.0 { 0.0 } else { b.atan2(a) }, 1f64.atan2(r))
}

/// What owns the current contact; the other source's messages are ignored meanwhile.
#[derive(Clone, Copy, PartialEq)]
enum Contact {
    Mouse,
    Touch,
}

struct State {
    monitor: Option<MonitorInfo>,
    on_event: Box<dyn FnMut(Event)>,
    /// Mouse button or primary touch that began inside the video and is still down.
    touching: Option<Contact>,
    /// Last normalized contact position, for `cancelled`.
    last: (f64, f64),
    pen_down: bool,
    /// We told the sender the pen is in range.
    pen_near: bool,
}

thread_local! {
    static UI: OnceCell<Arc<Ui>> = const { OnceCell::new() };
    static STATE: RefCell<Option<State>> = const { RefCell::new(None) };
}

/// Opens the window over the configured monitor, with a tray icon, on a new UI thread.
pub fn spawn(on_event: impl FnMut(Event) + Send + 'static) -> io::Result<Arc<Ui>> {
    let (tx, rx) = mpsc::channel();
    thread::Builder::new().name("ui".into()).spawn(move || {
        let m = monitor::current().ok();
        match create(m) {
            Ok(hwnd) => {
                let ui = Arc::new(Ui {
                    hwnd: hwnd.0 as isize,
                    resized: AtomicBool::new(false),
                    overlay: AtomicBool::new(false),
                    video_rect: AtomicU64::new(0),
                    video_size: AtomicU64::new(0),
                });
                UI.with(|u| u.set(ui.clone()).ok());
                STATE.set(Some(State {
                    monitor: m,
                    on_event: Box::new(on_event),
                    touching: None,
                    last: (0.0, 0.0),
                    pen_down: false,
                    pen_near: false,
                }));
                tray(hwnd, NIM_ADD);
                // SAFETY: registering our own window for lock/unlock notifications.
                if let Err(e) =
                    unsafe { WTSRegisterSessionNotification(hwnd, NOTIFY_FOR_THIS_SESSION) }
                {
                    log::warn!("no session lock notifications: {e}");
                }
                let _ = tx.send(Ok(ui));
                message_loop();
            }
            Err(e) => {
                let _ = tx.send(Err(io::Error::other(e)));
            }
        }
    })?;
    rx.recv().map_err(io::Error::other)?
}

/// Shows a fatal error and waits until it is dismissed (there is no console to print to).
pub fn error_box(text: &str) {
    // SAFETY: both strings outlive the call; no owner window.
    unsafe {
        MessageBoxW(
            None,
            &HSTRING::from(text),
            w!("od-receiver"),
            MB_OK | MB_ICONERROR | MB_SETFOREGROUND,
        );
    }
}

/// Shows `text` in a message box on its own thread (so neither the caller nor the UI thread
/// blocks). At most one is open at a time.
pub fn alert(text: String) {
    static OPEN: AtomicBool = AtomicBool::new(false);
    if OPEN.swap(true, Ordering::AcqRel) {
        return;
    }
    let _ = thread::Builder::new().name("alert".into()).spawn(move || {
        // SAFETY: both strings outlive the call; no owner window.
        unsafe {
            MessageBoxW(
                None,
                &HSTRING::from(text),
                w!("od-receiver"),
                MB_OK | MB_ICONERROR | MB_TOPMOST | MB_SETFOREGROUND,
            );
        }
        OPEN.store(false, Ordering::Release);
    });
}

fn create(m: Option<MonitorInfo>) -> windows::core::Result<HWND> {
    let m = m.unwrap_or(MonitorInfo::FALLBACK);
    // SAFETY: class and window creation with static strings and our own wndproc; the class
    // struct is fully initialized and lives across the call.
    unsafe {
        let instance = GetModuleHandleW(None)?.into();
        let class = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(wndproc),
            hInstance: instance,
            hCursor: LoadCursorW(None, IDC_ARROW)?,
            hIcon: icon(GetSystemMetrics(SM_CXICON)),
            hIconSm: icon(GetSystemMetrics(SM_CXSMICON)),
            lpszClassName: w!("od-receiver"),
            ..Default::default()
        };
        RegisterClassExW(&class);
        // A plain popup exactly covering the monitor is what DWM promotes to independent flip.
        CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("od-receiver"),
            w!("od-receiver"),
            WS_POPUP | WS_VISIBLE,
            m.left,
            m.top,
            m.width as i32,
            m.height as i32,
            None,
            None,
            Some(instance),
            None,
        )
    }
}

fn message_loop() {
    let mut msg = MSG::default();
    // SAFETY: standard message pump on the thread that owns the window.
    unsafe {
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    let ui = || UI.with(|u| u.get().cloned());
    // Signed client coordinates from a mouse message.
    let (mx, my) = (lp.0 as i16 as i32, (lp.0 >> 16) as i16 as i32);
    match msg {
        WM_SIZE => {
            if let Some(ui) = ui() {
                ui.resized.store(true, Ordering::Release);
            }
            LRESULT(0)
        }
        WM_KEYDOWN if wp.0 == VK_F2.0 as usize => {
            if let Some(ui) = ui() {
                ui.overlay.fetch_xor(true, Ordering::AcqRel);
            }
            LRESULT(0)
        }
        WM_DISPLAYCHANGE | WM_DPICHANGED => {
            display_changed(hwnd);
            LRESULT(0)
        }
        WM_LBUTTONDOWN => {
            if touch(Contact::Mouse, TouchPhase::Began, mx, my) {
                // SAFETY: capturing the mouse for our own window.
                unsafe { SetCapture(hwnd) };
            }
            LRESULT(0)
        }
        WM_MOUSEMOVE => {
            touch(Contact::Mouse, TouchPhase::Moved, mx, my);
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            touch(Contact::Mouse, TouchPhase::Ended, mx, my);
            // SAFETY: releasing our own capture. After `ended` the resulting WM_CAPTURECHANGED
            // sends nothing; if `ended` could not be sent (video gone) it sends `cancelled`.
            let _ = unsafe { ReleaseCapture() };
            LRESULT(0)
        }
        WM_CAPTURECHANGED => {
            touch(Contact::Mouse, TouchPhase::Cancelled, 0, 0);
            LRESULT(0)
        }
        WM_MOUSEWHEEL | WM_MOUSEHWHEEL => {
            scroll(msg == WM_MOUSEHWHEEL, (wp.0 >> 16) as i16 as f64);
            LRESULT(0)
        }
        WM_POINTERDOWN
        | WM_POINTERUPDATE
        | WM_POINTERUP
        | WM_POINTERENTER
        | WM_POINTERLEAVE
        | WM_POINTERCAPTURECHANGED => {
            // Touch and pen are read here; anything else gets the default (mouse) promotion.
            if pointer(hwnd, msg, (wp.0 & 0xFFFF) as u32) {
                LRESULT(0)
            } else {
                // SAFETY: default handling with the arguments we were given.
                unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
            }
        }
        WM_TRAY if matches!(lp.0 as u32 & 0xFFFF, WM_RBUTTONUP | WM_CONTEXTMENU) => {
            if tray_menu(hwnd) {
                quit(hwnd);
            }
            LRESULT(0)
        }
        WM_WTSSESSION_CHANGE if matches!(wp.0 as u32, WTS_SESSION_LOCK | WTS_SESSION_UNLOCK) => {
            emit(Event::Locked(wp.0 as u32 == WTS_SESSION_LOCK));
            LRESULT(0)
        }
        // Alt+F4.
        WM_CLOSE => {
            quit(hwnd);
            LRESULT(0)
        }
        // The swap chain covers everything; skipping GDI's erase avoids a white flash.
        WM_ERASEBKGND => LRESULT(1),
        // SAFETY: default handling with the arguments we were given.
        _ => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
    }
}

/// Mouse / touch contact at client pixel (px, py). A contact that begins outside the video is
/// ignored until it ends. Returns true if the phase was sent.
fn touch(src: Contact, phase: TouchPhase, px: i32, py: i32) -> bool {
    let Some(rect) = UI.with(|u| u.get().map(|u| u.video_rect.load(Ordering::Relaxed))) else {
        return false;
    };
    STATE.with_borrow_mut(|s| {
        let Some(s) = s else { return false };
        let (x, y) = match (phase, normalize(rect, px, py)) {
            (TouchPhase::Began, Some((x, y, true))) if s.touching.is_none() => (x, y),
            (TouchPhase::Moved | TouchPhase::Ended, Some((x, y, _))) if s.touching == Some(src) => {
                (x, y)
            }
            (TouchPhase::Cancelled, _) if s.touching == Some(src) => s.last,
            _ => return false,
        };
        s.touching = matches!(phase, TouchPhase::Began | TouchPhase::Moved).then_some(src);
        s.last = (x, y);
        (s.on_event)(Event::Input(Outgoing::Touch {
            phase,
            x,
            y,
            t: None,
        }));
        true
    })
}

/// Wheel delta (120 per notch) -> `scroll` in video pixels with natural sign (§6.1): wheel
/// forward (positive) moves content down, so +dy; wheel right (positive) moves content left, so -dx.
fn scroll(horizontal: bool, delta: f64) {
    let Some((rect, size)) = UI.with(|u| {
        u.get().map(|u| {
            (
                u.video_rect.load(Ordering::Relaxed),
                u.video_size.load(Ordering::Relaxed),
            )
        })
    }) else {
        return;
    };
    let (rw, rh) = ((rect >> 32 & 0xFFFF) as f64, (rect >> 48) as f64);
    if rw == 0.0 || rh == 0.0 {
        return;
    }
    let px = delta / 120.0 * NOTCH_PX;
    let msg = if horizontal {
        Outgoing::Scroll {
            dx: -px * (size & 0xFFFF_FFFF) as f64 / rw,
            dy: 0.0,
        }
    } else {
        Outgoing::Scroll {
            dx: 0.0,
            dy: px * (size >> 32) as f64 / rh,
        }
    };
    emit(Event::Input(msg));
}

fn emit(e: Event) {
    STATE.with_borrow_mut(|s| {
        if let Some(s) = s {
            (s.on_event)(e);
        }
    });
}

fn quit(hwnd: HWND) {
    emit(Event::Quit);
    tray(hwnd, NIM_DELETE);
    std::process::exit(0);
}

/// Adds or removes the tray icon.
/// shortcut: not re-added if Explorer restarts (TaskbarCreated); handle it if that matters.
fn tray(hwnd: HWND, op: NOTIFY_ICON_MESSAGE) {
    let mut nid = NOTIFYICONDATAW {
        cbSize: size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: 1,
        uFlags: NIF_ICON | NIF_MESSAGE | NIF_TIP,
        uCallbackMessage: WM_TRAY,
        // SAFETY: reading a system metric.
        hIcon: icon(unsafe { GetSystemMetrics(SM_CXSMICON) }),
        ..Default::default()
    };
    for (d, c) in nid.szTip.iter_mut().zip("od-receiver".encode_utf16()) {
        *d = c;
    }
    // SAFETY: `nid` is fully initialized and outlives the call.
    if !unsafe { Shell_NotifyIconW(op, &nid) }.as_bool() && op == NIM_ADD {
        log::warn!("tray icon could not be added");
    }
}

/// The `.ico` image best suited to `size` px: the smallest at least that big, else the largest.
fn ico_entry(ico: &[u8], size: u32) -> Option<&[u8]> {
    let u32_at = |b: &[u8], i: usize| u32::from_le_bytes([b[i], b[i + 1], b[i + 2], b[i + 3]]);
    let count = u16::from_le_bytes([*ico.get(4)?, *ico.get(5)?]) as usize;
    (0..count)
        .filter_map(|i| {
            let e = ico.get(6 + 16 * i..22 + 16 * i)?;
            let side = if e[0] == 0 { 256 } else { e[0] as u32 };
            let (len, off) = (u32_at(e, 8) as usize, u32_at(e, 12) as usize);
            Some((side, ico.get(off..off.checked_add(len)?)?))
        })
        .min_by_key(|&(side, _)| (side < size, side.abs_diff(size)))
        .map(|(_, data)| data)
}

/// The app icon at `size` px; the default (no icon) if it cannot be built.
fn icon(size: i32) -> HICON {
    let Some(data) = ico_entry(ICO, size as u32) else {
        return HICON::default();
    };
    // SAFETY: `data` is one complete icon image (PNG or DIB) from our embedded .ico.
    unsafe { CreateIconFromResourceEx(data, true, 0x0003_0000, size, size, LR_DEFAULTCOLOR) }
        .unwrap_or_default()
}

/// Shows the tray menu at the cursor; true if Quit was chosen.
fn tray_menu(hwnd: HWND) -> bool {
    // SAFETY: a menu we create, show modally and destroy; our own window owns it.
    unsafe {
        let Ok(menu) = CreatePopupMenu() else {
            return false;
        };
        let _ = AppendMenuW(menu, MF_STRING, MENU_QUIT, w!("Quit od-receiver"));
        let mut p = POINT::default();
        let _ = GetCursorPos(&mut p);
        // Required so the menu closes when the user clicks elsewhere.
        let _ = SetForegroundWindow(hwnd);
        let cmd = TrackPopupMenu(
            menu,
            TPM_RETURNCMD | TPM_RIGHTBUTTON,
            p.x,
            p.y,
            None,
            hwnd,
            None,
        );
        let _ = DestroyMenu(menu);
        cmd.0 == MENU_QUIT as i32
    }
}

/// Handles a touch or pen pointer message; returns false for other pointer types.
fn pointer(hwnd: HWND, msg: u32, id: u32) -> bool {
    let mut ty = POINTER_INPUT_TYPE::default();
    // SAFETY: querying a pointer id from the current message.
    if unsafe { GetPointerType(id, &mut ty) }.is_err() {
        return false;
    }
    let client = |info: &POINTER_INFO| {
        let mut p = info.ptPixelLocation;
        // SAFETY: converting a point for our own window.
        let _ = unsafe { ScreenToClient(hwnd, &mut p) };
        p
    };
    if ty == PT_TOUCH {
        let mut info = POINTER_INFO::default();
        // SAFETY: as above, with a local out-param.
        if unsafe { GetPointerInfo(id, &mut info) }.is_err() {
            return true;
        }
        // The protocol carries one finger: only the primary contact counts.
        if msg != WM_POINTERCAPTURECHANGED
            && !info
                .pointerFlags
                .contains(windows::Win32::UI::Input::Pointer::POINTER_FLAG_PRIMARY)
        {
            return true;
        }
        let POINT { x, y } = client(&info);
        match msg {
            WM_POINTERDOWN => touch(Contact::Touch, TouchPhase::Began, x, y),
            WM_POINTERUPDATE => touch(Contact::Touch, TouchPhase::Moved, x, y),
            WM_POINTERUP => touch(Contact::Touch, TouchPhase::Ended, x, y),
            WM_POINTERCAPTURECHANGED => touch(Contact::Touch, TouchPhase::Cancelled, x, y),
            _ => false,
        };
        return true;
    }
    if ty != PT_PEN {
        return false;
    }
    let mut pen = POINTER_PEN_INFO::default();
    // SAFETY: as above, with a local out-param.
    if unsafe { GetPointerPenInfo(id, &mut pen) }.is_err() {
        return true;
    }
    let POINT { x: px, y: py } = client(&pen.pointerInfo);
    pen_event(msg, px, py, &pen);
    true
}

fn pen_event(msg: u32, px: i32, py: i32, pen: &POINTER_PEN_INFO) {
    let Some(rect) = UI.with(|u| u.get().map(|u| u.video_rect.load(Ordering::Relaxed))) else {
        return;
    };
    let Some((x, y, inside)) = normalize(rect, px, py) else {
        return;
    };
    let has = |m| pen.penMask & m != 0;
    let (azimuth, altitude) = if has(PEN_MASK_TILT_X | PEN_MASK_TILT_Y) {
        tilt(pen.tiltX as f64, pen.tiltY as f64)
    } else {
        (0.0, std::f64::consts::FRAC_PI_2)
    };
    STATE.with_borrow_mut(|s| {
        let Some(s) = s else { return };
        let mut send = |phase, pressure| {
            (s.on_event)(Event::Input(Outgoing::Pencil {
                phase,
                x,
                y,
                pressure,
                azimuth,
                altitude,
                rotation: 0.0,
                t: None,
            }))
        };
        let pressure = if has(PEN_MASK_PRESSURE) {
            pen.pressure as f64 / 1024.0
        } else {
            1.0
        };
        match msg {
            WM_POINTERDOWN if inside && !s.pen_down => {
                s.pen_down = true;
                send(PencilPhase::Down, pressure);
            }
            WM_POINTERUPDATE if s.pen_down => send(PencilPhase::Move, pressure),
            WM_POINTERUPDATE if inside => send(PencilPhase::Hover, 0.0),
            WM_POINTERUP | WM_POINTERCAPTURECHANGED if s.pen_down => {
                s.pen_down = false;
                send(PencilPhase::Up, 0.0);
            }
            _ => {}
        }
        let near = msg != WM_POINTERLEAVE && inside;
        if near != s.pen_near && !s.pen_down {
            s.pen_near = near;
            (s.on_event)(Event::Input(Outgoing::Proximity {
                entering: near,
                x,
                y,
            }));
        }
    });
}

fn display_changed(hwnd: HWND) {
    let Ok(m) = monitor::current() else { return };
    // Not borrowed across SetWindowPos, which re-enters wndproc with WM_SIZE.
    let changed =
        STATE.with_borrow_mut(|s| s.as_mut().is_some_and(|s| s.monitor.replace(m) != Some(m)));
    if !changed {
        return;
    }
    // SAFETY: repositioning our own window.
    let _ = unsafe {
        SetWindowPos(
            hwnd,
            None,
            m.left,
            m.top,
            m.width as i32,
            m.height as i32,
            SWP_NOZORDER | SWP_NOACTIVATE,
        )
    };
    emit(Event::DisplayChanged);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::{FRAC_PI_2, FRAC_PI_4};

    #[test]
    fn normalize_against_video_rect() {
        let ui = Ui {
            hwnd: 0,
            resized: false.into(),
            overlay: false.into(),
            video_rect: 0.into(),
            video_size: 0.into(),
        };
        assert_eq!(
            normalize(ui.video_rect.load(Ordering::Relaxed), 10, 10),
            None,
            "no video yet"
        );
        ui.set_video((96, 0, 1728, 1080), Some((1920, 1200))); // pillarboxed
        let r = ui.video_rect.load(Ordering::Relaxed);
        assert_eq!(normalize(r, 96, 0), Some((0.0, 0.0, true)));
        assert_eq!(
            normalize(r, 96 + 1728, 1080),
            Some((1.0, 1.0, false)),
            "one past the edge"
        );
        assert_eq!(normalize(r, 96 + 864, 540), Some((0.5, 0.5, true)));
        assert_eq!(
            normalize(r, 10, 540),
            Some((0.0, 0.5, false)),
            "black bar clamps"
        );
        ui.set_video((96, 0, 1728, 1080), None);
        assert_eq!(
            normalize(ui.video_rect.load(Ordering::Relaxed), 500, 500),
            None
        );
    }

    #[test]
    fn picks_icon_size() {
        let side = |s| ico_entry(ICO, s).map(|d| d.len());
        let sizes: Vec<_> = [16, 24, 32, 48, 64, 256].iter().map(|&s| side(s)).collect();
        assert!(
            sizes.iter().all(Option::is_some),
            "every size present: {sizes:?}"
        );
        assert_eq!(side(20), side(24), "rounds up");
        assert_eq!(side(500), side(256), "largest when nothing is big enough");
        assert_eq!(ico_entry(b"short", 16), None);
    }

    #[test]
    fn tilt_to_azimuth_altitude() {
        let close =
            |a: (f64, f64), b: (f64, f64)| (a.0 - b.0).abs() < 1e-9 && (a.1 - b.1).abs() < 1e-9;
        assert!(close(tilt(0.0, 0.0), (0.0, FRAC_PI_2)), "upright");
        assert!(close(tilt(45.0, 0.0), (0.0, FRAC_PI_4)), "leaning right");
        assert!(
            close(tilt(0.0, 45.0), (FRAC_PI_2, FRAC_PI_4)),
            "leaning toward the user (down)"
        );
        assert!(
            close(tilt(-45.0, 0.0), (std::f64::consts::PI, FRAC_PI_4)),
            "leaning left"
        );
    }
}
