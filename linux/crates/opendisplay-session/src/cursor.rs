//! Cursor sequence semantics shared by TCP frames and UDP datagrams (§6.3).

/// Keeps the highest `s` seen; drops anything not newer. A `cursor` without
/// `s` (an older sender) applies unconditionally.
#[derive(Debug, Default, Clone)]
pub struct CursorSeqTracker {
    highest: Option<u64>,
}

impl CursorSeqTracker {
    /// New TCP connection or new UDP flow.
    pub fn reset(&mut self) {
        self.highest = None;
    }

    /// Whether a message with this sequence number should be applied.
    pub fn accept(&mut self, s: Option<u64>) -> bool {
        match s {
            None => true,
            Some(s) => {
                if self.highest.is_some_and(|h| s <= h) {
                    return false;
                }
                self.highest = Some(s);
                true
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drops_stale_and_duplicate_but_not_unsequenced() {
        let mut t = CursorSeqTracker::default();
        assert!(t.accept(Some(1)));
        assert!(t.accept(Some(3)));
        assert!(!t.accept(Some(2)));
        assert!(!t.accept(Some(3)));
        assert!(t.accept(None));
        assert!(t.accept(Some(4)));
        t.reset();
        assert!(t.accept(Some(1)));
    }
}
