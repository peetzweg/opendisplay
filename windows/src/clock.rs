//! NTP-style clock offset from ping/pong (PROTOCOL.md §8.1).

use std::collections::VecDeque;
use std::time::{SystemTime, UNIX_EPOCH};

/// Milliseconds since the Unix epoch on this machine's clock.
pub fn now_ms() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
        * 1000.0
}

#[derive(Default)]
pub struct ClockSync {
    /// (rtt, offset) of the last 15 accepted samples.
    samples: VecDeque<(f64, f64)>,
}

impl ClockSync {
    /// `t1` = our ping time, `mt` = sender time in the pong, `t2` = pong arrival time.
    pub fn add(&mut self, t1: f64, mt: f64, t2: f64) {
        let rtt = t2 - t1;
        if !(0.0..2000.0).contains(&rtt) {
            return;
        }
        if self.samples.len() == 15 {
            self.samples.pop_front();
        }
        self.samples.push_back((rtt, mt - (t1 + t2) / 2.0));
    }

    /// Sender clock minus receiver clock (ms), from the minimum-RTT sample.
    pub fn offset(&self) -> Option<f64> {
        self.samples
            .iter()
            .min_by(|a, b| a.0.total_cmp(&b.0))
            .map(|s| s.1)
    }

    pub fn rtt(&self) -> Option<f64> {
        self.samples.iter().map(|s| s.0).min_by(f64::total_cmp)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn min_rtt_sample_wins_and_bad_samples_are_dropped() {
        let mut c = ClockSync::default();
        assert_eq!(c.offset(), None);
        c.add(1000.0, 1600.0, 1100.0); // rtt 100, offset 550
        c.add(2000.0, 2510.0, 2020.0); // rtt 20, offset 500
        c.add(3000.0, 9999.0, 2999.0); // rtt < 0: dropped
        c.add(4000.0, 9999.0, 6000.0); // rtt 2000: dropped
        assert_eq!(c.offset(), Some(500.0));
        assert_eq!(c.rtt(), Some(20.0));
    }

    #[test]
    fn keeps_only_last_15() {
        let mut c = ClockSync::default();
        c.add(0.0, 5.0, 1.0); // best rtt, will be evicted
        for i in 1..=15 {
            let t = i as f64 * 100.0;
            c.add(t, t + 50.0, t + 10.0);
        }
        assert_eq!(c.offset(), Some(45.0));
    }
}
