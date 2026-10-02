//! Rolling receiver telemetry for `stats` (§6.1) and the log.

use std::time::Instant;

#[derive(Debug)]
pub struct Window {
    start: Instant,
    frames: u64,
    bytes: u64,
    idrs: u64,
    /// Capture -> arrival, ms, when the sender stamped telemetry and the
    /// clock offset is known.
    e2e_ms: Vec<f64>,
    /// Sender send -> arrival, ms (network + queueing).
    net_ms: Vec<f64>,
    /// Decoder push failures.
    decode_errors: u64,
}

impl Default for Window {
    fn default() -> Self {
        Self {
            start: Instant::now(),
            frames: 0,
            bytes: 0,
            idrs: 0,
            e2e_ms: Vec::new(),
            net_ms: Vec::new(),
            decode_errors: 0,
        }
    }
}

fn percentile(v: &mut [f64], p: f64) -> Option<f64> {
    if v.is_empty() {
        return None;
    }
    v.sort_by(f64::total_cmp);
    let idx = ((v.len() as f64 - 1.0) * p).round() as usize;
    Some(v[idx.min(v.len() - 1)])
}

impl Window {
    pub fn frame(&mut self, bytes: usize, is_idr: bool, e2e_ms: Option<f64>, net_ms: Option<f64>) {
        self.frames += 1;
        self.bytes += bytes as u64;
        if is_idr {
            self.idrs += 1;
        }
        if let Some(e) = e2e_ms {
            self.e2e_ms.push(e);
        }
        if let Some(n) = net_ms {
            self.net_ms.push(n);
        }
    }

    pub fn decode_error(&mut self) {
        self.decode_errors += 1;
    }

    /// Produce the `stats` object for this window and start a new one.
    pub fn flush(
        &mut self,
        extra: serde_json::Map<String, serde_json::Value>,
    ) -> serde_json::Value {
        let el = self.start.elapsed().as_secs_f64().max(1e-3);
        let mut m = extra;
        m.insert("fps".into(), round1(self.frames as f64 / el).into());
        m.insert(
            "mbps".into(),
            round1(self.bytes as f64 * 8.0 / el / 1e6).into(),
        );
        m.insert("idr".into(), self.idrs.into());
        m.insert("decErr".into(), self.decode_errors.into());
        if let Some(p) = percentile(&mut self.e2e_ms, 0.5) {
            m.insert("e2e50".into(), round1(p).into());
        }
        if let Some(p) = percentile(&mut self.e2e_ms, 0.95) {
            m.insert("e2e95".into(), round1(p).into());
        }
        if let Some(p) = percentile(&mut self.net_ms, 0.5) {
            m.insert("net50".into(), round1(p).into());
        }
        *self = Window::default();
        serde_json::Value::Object(m)
    }
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}
