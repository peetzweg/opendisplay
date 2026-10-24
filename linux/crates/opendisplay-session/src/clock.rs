//! NTP-style clock offset over `ping`/`pong` (§8.1).

/// `offset = mt - (t1 + t2) / 2` from the minimum-RTT sample of the last 15,
/// discarding `rtt < 0` or `rtt >= 2000` ms. Positive offset means the
/// sender's clock is ahead of ours.
#[derive(Debug, Clone, Default)]
pub struct ClockSync {
    samples: Vec<Sample>,
}

#[derive(Debug, Clone, Copy)]
struct Sample {
    rtt: f64,
    offset: f64,
}

impl ClockSync {
    pub const KEEP: usize = 15;

    pub fn reset(&mut self) {
        self.samples.clear();
    }

    /// Record a `pong`: `t1` is our `ping.t`, `mt` the sender's clock in the
    /// reply, `t2` our clock when the reply arrived. Returns whether the sample
    /// was kept.
    pub fn add_sample(&mut self, t1: f64, mt: f64, t2: f64) -> bool {
        let rtt = t2 - t1;
        if !(0.0..2000.0).contains(&rtt) || !mt.is_finite() {
            return false;
        }
        let offset = mt - (t1 + t2) / 2.0;
        self.samples.push(Sample { rtt, offset });
        if self.samples.len() > Self::KEEP {
            self.samples.remove(0);
        }
        true
    }

    /// Sender clock minus receiver clock, ms. `None` until the first sample.
    pub fn offset_ms(&self) -> Option<f64> {
        self.samples
            .iter()
            .min_by(|a, b| a.rtt.total_cmp(&b.rtt))
            .map(|s| s.offset)
    }

    /// RTT of the sample the offset comes from.
    pub fn best_rtt_ms(&self) -> Option<f64> {
        self.samples.iter().map(|s| s.rtt).min_by(f64::total_cmp)
    }

    /// Map a sender-clock timestamp onto our clock.
    pub fn to_local(&self, sender_ms: f64) -> Option<f64> {
        self.offset_ms().map(|o| sender_ms - o)
    }

    /// Map our clock onto the sender's (for `touch.t`, `pencil.t`).
    pub fn to_sender(&self, local_ms: f64) -> Option<f64> {
        self.offset_ms().map(|o| local_ms + o)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn min_rtt_sample_wins_and_bad_samples_are_dropped() {
        let mut c = ClockSync::default();
        assert_eq!(c.offset_ms(), None);
        // Sender is 1000 ms ahead. Symmetric 20 ms path.
        assert!(c.add_sample(0.0, 1010.0, 20.0));
        // A queued sample: 300 ms rtt, reply generated late -> distorted offset.
        assert!(c.add_sample(100.0, 1350.0, 400.0));
        assert!(!c.add_sample(0.0, 5000.0, 2500.0), "rtt >= 2000 discarded");
        assert!(!c.add_sample(10.0, 5000.0, 5.0), "negative rtt discarded");
        assert_eq!(c.offset_ms(), Some(1000.0));
        assert_eq!(c.to_local(1500.0), Some(500.0));
        assert_eq!(c.to_sender(500.0), Some(1500.0));
    }

    #[test]
    fn keeps_only_the_last_fifteen() {
        let mut c = ClockSync::default();
        // First sample has the best rtt but must age out.
        c.add_sample(0.0, 1.0, 1.0);
        for i in 1..=15 {
            let t = i as f64 * 100.0;
            c.add_sample(t, t + 7.0 + 50.0, t + 100.0);
        }
        assert_eq!(c.best_rtt_ms(), Some(100.0));
        assert_eq!(c.offset_ms(), Some(7.0));
    }
}
