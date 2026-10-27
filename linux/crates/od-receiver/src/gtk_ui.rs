//! The GTK 4 presenter: a window that fullscreens itself on the chosen
//! monitor, shows `gtk4paintablesink`'s paintable, draws the sender's cursor
//! sprite over the video (§6.2) and turns local pointer input into
//! touch/scroll (§6.1). The receiver loop runs on another thread; it reaches
//! the widgets through [`glib::MainContext::invoke`] and a thread-local, and
//! the window reaches it through a channel.

use std::cell::RefCell;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, anyhow};
use gstreamer as gst;
use gtk::prelude::*;
use gtk::{gdk, glib};
use gtk4 as gtk;
use opendisplay_proto::control::{CursorImg, TouchPhase};
use tokio::sync::mpsc::UnboundedSender;
use tracing::{info, warn};

use crate::input::{ScrollUnit, UserInput, VideoRect, scroll_to_video};
use crate::video::VideoOutput;
use crate::video::gst_out::GstOutput;

/// The reverse-DNS id: the Wayland app_id, the Flatpak id and the desktop
/// entry's name (`app.opendisplay.Receiver.desktop`) all match it.
pub const APP_ID: &str = "app.opendisplay.Receiver";

/// One monitor as GDK reports it.
#[derive(Debug, Clone, PartialEq)]
pub struct MonitorFacts {
    pub connector: String,
    pub description: String,
    /// Logical (layout) size.
    pub logical: (i32, i32),
    /// The real, possibly fractional, scale.
    pub scale: f64,
    pub refresh_mhz: i32,
}

impl MonitorFacts {
    /// Physical pixels lit by the panel.
    pub fn pixels(&self) -> (u32, u32) {
        (
            (self.logical.0 as f64 * self.scale).round() as u32,
            (self.logical.1 as f64 * self.scale).round() as u32,
        )
    }

    /// Whole Hz, or `None` when the output does not know (headless and
    /// virtual outputs report 0): announcing that as 1 Hz would cap the
    /// sender at one frame per second.
    pub fn refresh_hz(&self) -> Option<u32> {
        (self.refresh_mhz >= 1000).then(|| ((self.refresh_mhz as f64) / 1000.0).round() as u32)
    }
}

/// Initialise GTK on this (main) thread.
pub fn init() -> Result<()> {
    // GTK names the toplevel after the program unless told otherwise.
    glib::set_prgname(Some(APP_ID));
    glib::set_application_name("OpenDisplay Receiver");
    gtk::init().map_err(|e| anyhow!("initialising GTK: {e}"))
}

fn monitor_list() -> Vec<gdk::Monitor> {
    let Some(display) = gdk::Display::default() else {
        return Vec::new();
    };
    let list = display.monitors();
    (0..list.n_items())
        .filter_map(|i| list.item(i).and_downcast::<gdk::Monitor>())
        .collect()
}

pub fn monitors() -> Vec<MonitorFacts> {
    monitor_list()
        .iter()
        .map(|m| {
            let g = m.geometry();
            MonitorFacts {
                connector: m.connector().map(|s| s.to_string()).unwrap_or_default(),
                description: m.description().map(|s| s.to_string()).unwrap_or_default(),
                logical: (g.width(), g.height()),
                scale: m.scale(),
                refresh_mhz: m.refresh_rate(),
            }
        })
        .collect()
}

/// The monitor named `connector`, or the first.
pub fn pick(list: &[MonitorFacts], connector: Option<&str>) -> Result<MonitorFacts> {
    match connector {
        Some(c) => list
            .iter()
            .find(|m| m.connector == c)
            .cloned()
            .with_context(|| {
                format!(
                    "no monitor {c}; have {:?}",
                    list.iter().map(|m| &m.connector).collect::<Vec<_>>()
                )
            }),
        None => list.first().cloned().context("GTK reports no monitors"),
    }
}

/// Whether GDK can make a GL context (then frames take the GL path).
pub fn gl_available() -> bool {
    let Some(display) = gdk::Display::default() else {
        return false;
    };
    match display.create_gl_context() {
        Ok(ctx) => ctx.realize().is_ok(),
        Err(_) => false,
    }
}

/// The receiver thread's view of the window: the GStreamer pipeline plus
/// cursor updates posted to the GTK thread.
pub struct GtkVideo {
    inner: GstOutput,
    generation: u64,
}

impl GtkVideo {
    pub fn new(inner: GstOutput) -> Self {
        let generation = inner.generation();
        Self { inner, generation }
    }

    /// A decoder fallback replaced the pipeline: show the new sink's
    /// paintable (its property must be read on the GTK thread).
    fn follow_pipeline(&mut self) {
        if self.inner.generation() == self.generation {
            return;
        }
        self.generation = self.inner.generation();
        if let Some(sink) = self.inner.paintable_sink() {
            on_ui(move |ui| {
                let p = sink.property::<gdk::Paintable>("paintable");
                ui.picture.set_paintable(Some(&p));
            });
        }
    }
}

impl VideoOutput for GtkVideo {
    fn push(&mut self, annexb: &[u8], is_idr: bool) -> Result<()> {
        let r = self.inner.push(annexb, is_idr);
        self.follow_pipeline();
        r
    }
    fn reset(&mut self) -> Result<()> {
        self.inner.reset()
    }
    fn poll_error(&mut self) -> Option<String> {
        let e = self.inner.poll_error();
        self.follow_pipeline();
        e
    }
    fn describe(&mut self) -> String {
        self.inner.describe()
    }
    fn rendered(&self) -> Option<u64> {
        self.inner.rendered()
    }
    fn take_decode_ms(&mut self) -> Vec<f64> {
        self.inner.take_decode_ms()
    }
    fn cursor(&mut self, x: Option<f64>, y: Option<f64>, visible: bool) {
        on_ui(move |ui| {
            if let (Some(x), Some(y)) = (x, y) {
                ui.cursor_pos = Some((x, y));
            }
            ui.cursor_visible = visible;
        });
    }
    fn cursor_image(&mut self, img: &CursorImg) {
        let img = img.clone();
        on_ui(move |ui| ui.set_sprite(&img));
    }
}

/// Window-side state, owned by the GTK thread.
struct Ui {
    app: gtk::Application,
    picture: gtk::Picture,
    fixed: gtk::Fixed,
    cursor: gtk::Picture,
    /// `nw`, `nh`, `ax`, `ay` of the current sprite (§6.2).
    sprite: Option<(f64, f64, f64, f64)>,
    cursor_pos: Option<(f64, f64)>,
    cursor_visible: bool,
}

thread_local! {
    static UI: RefCell<Option<Ui>> = const { RefCell::new(None) };
}

/// Run `f` on the GTK thread with the window state, if the window exists.
fn on_ui(f: impl FnOnce(&mut Ui) + Send + 'static) {
    glib::MainContext::default().invoke(move || {
        UI.with(|ui| {
            if let Some(ui) = ui.borrow_mut().as_mut() {
                f(ui);
            }
        });
    });
}

/// Ask the GTK thread to quit (the receiver loop has ended).
pub fn quit() {
    on_ui(|ui| ui.app.quit());
}

fn video_rect(picture: &gtk::Picture) -> Option<(VideoRect, (f64, f64))> {
    let p = picture.paintable()?;
    let video = (p.intrinsic_width() as f64, p.intrinsic_height() as f64);
    let area = (picture.width() as f64, picture.height() as f64);
    Some((VideoRect::fit(area, video)?, video))
}

impl Ui {
    fn set_sprite(&mut self, img: &CursorImg) {
        let png = glib::base64_decode(&img.png);
        match gdk::Texture::from_bytes(&glib::Bytes::from_owned(png)) {
            Ok(tex) => {
                self.cursor.set_paintable(Some(&tex));
                self.sprite = Some((img.nw, img.nh, img.ax, img.ay));
            }
            Err(e) => warn!("cursor sprite: {e}"),
        }
    }

    /// Place the sprite over the video; runs every frame (tick callback), so
    /// it follows window resizes too.
    fn layout_cursor(&self) {
        let show = self.cursor_visible && self.cursor_pos.is_some() && self.sprite.is_some();
        self.cursor.set_visible(show);
        if !show {
            return;
        }
        let (Some((x, y)), Some((nw, nh, ax, ay))) = (self.cursor_pos, self.sprite) else {
            return;
        };
        let Some((rect, _)) = video_rect(&self.picture) else {
            return;
        };
        let (w, h) = (
            (nw * rect.width).round().max(1.0),
            (nh * rect.height).round().max(1.0),
        );
        let (px, py) = rect.point(x, y);
        self.cursor.set_size_request(w as i32, h as i32);
        self.fixed.move_(&self.cursor, px - ax * w, py - ay * h);
    }
}

fn now_ms() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0)
}

/// Pointer → touch (§6.1): motion is `moved` (the sender moves its pointer,
/// pressed or not), the primary button is `began`/`ended`.
fn attach_input(picture: &gtk::Picture, tx: UnboundedSender<UserInput>) {
    let touch = {
        let picture = picture.clone();
        let tx = tx.clone();
        move |phase: TouchPhase, px: f64, py: f64| {
            if let Some((rect, _)) = video_rect(&picture) {
                let (x, y) = rect.normalise(px, py);
                let _ = tx.send(UserInput::Touch {
                    phase,
                    x,
                    y,
                    local_ms: now_ms(),
                });
            }
        }
    };

    let motion = gtk::EventControllerMotion::new();
    let t = touch.clone();
    motion.connect_motion(move |_, x, y| t(TouchPhase::Moved, x, y));
    // Entering the window is a position too (and the only one GTK reports
    // when the pointer appears over it, e.g. a seat gaining a pointer).
    let t = touch.clone();
    motion.connect_enter(move |_, x, y| t(TouchPhase::Moved, x, y));
    picture.add_controller(motion);

    let click = gtk::GestureClick::new();
    click.set_button(gdk::BUTTON_PRIMARY);
    let t = touch.clone();
    click.connect_pressed(move |_, _, x, y| t(TouchPhase::Began, x, y));
    let t = touch.clone();
    click.connect_released(move |_, _, x, y| t(TouchPhase::Ended, x, y));
    let t = touch;
    click.connect_cancel(move |g, _| {
        if let Some((x, y)) = g.point(None) {
            t(TouchPhase::Cancelled, x, y);
        }
    });
    picture.add_controller(click);

    let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::BOTH_AXES);
    let p = picture.clone();
    scroll.connect_scroll(move |c, dx, dy| {
        let unit = match c.unit() {
            gdk::ScrollUnit::Wheel => ScrollUnit::Wheel,
            _ => ScrollUnit::Surface,
        };
        if let Some((rect, video)) = video_rect(&p) {
            let (dx, dy) = scroll_to_video(dx, dy, unit, &rect, video.1);
            let _ = tx.send(UserInput::Scroll { dx, dy });
        }
        glib::Propagation::Stop
    });
    picture.add_controller(scroll);
}

/// How the window comes up.
#[derive(Debug, Clone)]
pub struct WindowOptions {
    /// Monitor connector to fullscreen on.
    pub monitor: Option<String>,
    pub windowed: bool,
}

/// Build the window around `sink`'s paintable and run GTK until [`quit`].
/// `on_close` is called once when the user closes the window; the receiver
/// then says `closing` and calls [`quit`].
pub fn run(
    opts: WindowOptions,
    sink: gst::Element,
    input: UnboundedSender<UserInput>,
    on_close: impl Fn() + 'static,
) -> Result<()> {
    let paintable = sink.property::<gdk::Paintable>("paintable");
    let app = gtk::Application::builder()
        .application_id(APP_ID)
        .flags(gtk::gio::ApplicationFlags::NON_UNIQUE)
        .build();
    let on_close = std::rc::Rc::new(on_close);
    app.connect_activate(move |app| {
        let picture = gtk::Picture::for_paintable(&paintable);
        picture.set_content_fit(gtk::ContentFit::Contain);
        picture.set_hexpand(true);
        picture.set_vexpand(true);
        // The sender's cursor is drawn below; the local one would sit on top.
        picture.set_cursor_from_name(Some("none"));
        attach_input(&picture, input.clone());

        let fixed = gtk::Fixed::new();
        fixed.set_can_target(false);
        let cursor = gtk::Picture::new();
        cursor.set_can_shrink(true);
        cursor.set_content_fit(gtk::ContentFit::Fill);
        cursor.set_can_target(false);
        cursor.add_css_class("od-cursor");
        cursor.set_visible(false);
        fixed.put(&cursor, 0.0, 0.0);

        let overlay = gtk::Overlay::new();
        overlay.set_child(Some(&picture));
        overlay.add_overlay(&fixed);

        let window = gtk::ApplicationWindow::builder()
            .application(app)
            .title("OpenDisplay")
            .child(&overlay)
            .default_width(1280)
            .default_height(800)
            .build();
        let css = gtk::CssProvider::new();
        css.load_from_string(
            "window, picture { background: black; } picture.od-cursor { background: none; }",
        );
        gtk::style_context_add_provider_for_display(
            &gtk::prelude::WidgetExt::display(&window),
            &css,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
        if !opts.windowed {
            let monitor = monitor_list().into_iter().find(|m| {
                opts.monitor.is_none() || m.connector().as_deref() == opts.monitor.as_deref()
            });
            match monitor {
                Some(m) => window.fullscreen_on_monitor(&m),
                None => window.fullscreen(),
            }
        }
        let on_close = on_close.clone();
        window.connect_close_request(move |w| {
            info!("window closed");
            on_close();
            w.set_visible(false);
            glib::Propagation::Stop
        });
        // Keep the screen on while the window shows a stream.
        let _cookie = app.inhibit(
            Some(&window),
            gtk::ApplicationInhibitFlags::IDLE,
            Some("Showing an OpenDisplay stream"),
        );
        picture.add_tick_callback(|_, _| {
            UI.with(|ui| {
                if let Some(ui) = ui.borrow().as_ref() {
                    ui.layout_cursor();
                }
            });
            glib::ControlFlow::Continue
        });
        UI.with(|ui| {
            *ui.borrow_mut() = Some(Ui {
                app: app.clone(),
                picture: picture.clone(),
                fixed: fixed.clone(),
                cursor: cursor.clone(),
                sprite: None,
                cursor_pos: None,
                cursor_visible: false,
            })
        });
        window.present();
    });
    // clap owns the command line; GTK gets none.
    let code = app.run_with_args::<&str>(&[]);
    UI.with(|ui| *ui.borrow_mut() = None);
    if code != glib::ExitCode::SUCCESS {
        return Err(anyhow!("GTK exited with {code:?}"));
    }
    Ok(())
}
