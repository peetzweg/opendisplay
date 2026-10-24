//! Local pointer input mapped to the sender's units (PROTOCOL §6.1, §7):
//! `touch.x/y` normalised to the video (top-left origin), `scroll.dx/dy` in
//! video pixels with natural-scrolling sign. Independent of the toolkit, so
//! the arithmetic is tested here and the window only reports raw events.

use opendisplay_proto::control::TouchPhase;

/// What the window saw, already in protocol terms; the receiver loop adds
/// `touch.t` (sender clock) and sends it.
#[derive(Debug, Clone, PartialEq)]
pub enum UserInput {
    Touch {
        phase: TouchPhase,
        x: f64,
        y: f64,
        /// Local wall clock, ms since the Unix epoch.
        local_ms: f64,
    },
    Scroll {
        dx: f64,
        dy: f64,
    },
}

/// Where the video sits in the window (letterboxed, aspect kept), in the
/// window's logical pixels.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VideoRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl VideoRect {
    /// `video` (w, h) fitted into `area` (w, h), centred: GtkPicture's
    /// `ContentFit::Contain`.
    pub fn fit(area: (f64, f64), video: (f64, f64)) -> Option<Self> {
        let (aw, ah) = area;
        let (vw, vh) = video;
        if aw <= 0.0 || ah <= 0.0 || vw <= 0.0 || vh <= 0.0 {
            return None;
        }
        let s = (aw / vw).min(ah / vh);
        let (w, h) = (vw * s, vh * s);
        Some(Self {
            x: (aw - w) / 2.0,
            y: (ah - h) / 2.0,
            width: w,
            height: h,
        })
    }

    /// A window point as a normalised video position, clamped onto the video
    /// (a press in the letterbox lands on the nearest edge).
    pub fn normalise(&self, px: f64, py: f64) -> (f64, f64) {
        (
            ((px - self.x) / self.width).clamp(0.0, 1.0),
            ((py - self.y) / self.height).clamp(0.0, 1.0),
        )
    }

    /// A normalised video position as a window point.
    pub fn point(&self, x: f64, y: f64) -> (f64, f64) {
        (self.x + x * self.width, self.y + y * self.height)
    }
}

/// How the toolkit measured a scroll.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScrollUnit {
    /// Mouse wheel detents (1.0 per notch).
    Wheel,
    /// Touchpad / smooth scrolling, window logical pixels.
    Surface,
}

/// Video pixels per wheel notch: about three lines of text at a 2x desktop.
pub const WHEEL_STEP: f64 = 120.0;

/// A toolkit scroll delta (positive = "scroll down": content moves up, the
/// wl_pointer/GTK sign) as a `scroll` in video pixels with natural sign
/// (positive `dy` = content moves down, §6.1). `video_height` is the decoded
/// height, so a surface delta scales by the on-screen magnification.
pub fn scroll_to_video(
    dx: f64,
    dy: f64,
    unit: ScrollUnit,
    rect: &VideoRect,
    video_height: f64,
) -> (f64, f64) {
    let k = match unit {
        ScrollUnit::Wheel => WHEEL_STEP,
        ScrollUnit::Surface => {
            if rect.height > 0.0 {
                video_height / rect.height
            } else {
                1.0
            }
        }
    };
    (-dx * k, -dy * k)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn letterbox_and_normalise() {
        // 16:9 video in a 4:3 window: bars top and bottom.
        let r = VideoRect::fit((1024.0, 768.0), (1920.0, 1080.0)).unwrap();
        assert_eq!(r.width, 1024.0);
        assert_eq!(r.height, 576.0);
        assert_eq!(r.y, 96.0);
        assert_eq!(r.normalise(512.0, 384.0), (0.5, 0.5));
        assert_eq!(r.normalise(0.0, 96.0), (0.0, 0.0));
        // In the bar: clamped to the edge.
        assert_eq!(r.normalise(1024.0, 10.0), (1.0, 0.0));
        assert_eq!(r.point(0.5, 0.5), (512.0, 384.0));
        assert!(VideoRect::fit((0.0, 768.0), (1920.0, 1080.0)).is_none());
    }

    #[test]
    fn scroll_units_and_sign() {
        let r = VideoRect::fit((960.0, 540.0), (1920.0, 1080.0)).unwrap();
        // Touchpad: fingers move down = GTK dy negative = content down = +dy,
        // 10 window px = 20 video px at this 2x magnification.
        assert_eq!(
            scroll_to_video(0.0, -10.0, ScrollUnit::Surface, &r, 1080.0),
            (0.0, 20.0)
        );
        // One wheel notch down: content moves up.
        assert_eq!(
            scroll_to_video(0.0, 1.0, ScrollUnit::Wheel, &r, 1080.0),
            (0.0, -WHEEL_STEP)
        );
        // Horizontal follows the same rule.
        assert_eq!(
            scroll_to_video(1.0, 0.0, ScrollUnit::Wheel, &r, 1080.0),
            (-WHEEL_STEP, 0.0)
        );
    }
}
