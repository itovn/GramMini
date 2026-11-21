// Phỏng theo Ferrogram — github.com/Dasemu/Ferrogram, src/net/calls/jitter.rs
// Copyright (c) 2026 Darío Sevilla Muñoz. Giấy phép MIT (crates/gm-call/LICENSE-FERROGRAM).
// GramMini sửa: đường dẫn module (CallKey ở tg/mod.rs), âm thanh qua gm-opus.

//! A small adaptive jitter buffer for 20 ms Opus packets.
//!
//! The network side pushes `(seq, payload)`; the playback side pops one frame
//! every 20 ms and gets either the packet, a "lost" marker (with the next
//! packet so Opus in-band FEC can rebuild the gap), or nothing while it
//! (re)buffers. Bounded: at most [`MAX_PACKETS`] are held.

use std::collections::BTreeMap;

pub const MAX_PACKETS: usize = 50;
const MIN_TARGET: usize = 2;
const MAX_TARGET: usize = 10;
/// Frames of smooth playback after which the target shrinks by one.
const SHRINK_AFTER: u32 = 500;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Frame {
    Packet(Vec<u8>),
    /// The packet for this slot is missing; `next` is the following packet
    /// if it already arrived (decode it with FEC to recover this one).
    Lost {
        next: Option<Vec<u8>>,
    },
    /// Buffering: play silence (or comfort noise).
    Silence,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Stats {
    pub received: u64,
    pub lost: u64,
    pub late: u64,
    pub underruns: u64,
}

#[derive(Debug)]
pub struct JitterBuffer {
    packets: BTreeMap<u64, Vec<u8>>,
    /// Extended sequence number of the next frame to play.
    next: Option<u64>,
    highest: Option<u64>,
    playing: bool,
    target: usize,
    smooth: u32,
    pub stats: Stats,
}

impl Default for JitterBuffer {
    fn default() -> Self {
        Self::new()
    }
}

impl JitterBuffer {
    pub fn new() -> Self {
        Self {
            packets: BTreeMap::new(),
            next: None,
            highest: None,
            playing: false,
            target: 3,
            smooth: 0,
            stats: Stats::default(),
        }
    }

    pub fn target(&self) -> usize {
        self.target
    }

    pub fn len(&self) -> usize {
        self.packets.len()
    }

    pub fn is_empty(&self) -> bool {
        self.packets.is_empty()
    }

    /// Extend a 16-bit sequence number around the highest one seen.
    fn extend(&self, seq: u16) -> u64 {
        let Some(h) = self.highest else {
            return (1 << 16) | u64::from(seq);
        };
        let cycle = h & !0xffff;
        let cand = cycle | u64::from(seq);
        let candidates = [cand.wrapping_sub(1 << 16), cand, cand + (1 << 16)];
        candidates
            .into_iter()
            .filter(|c| *c >= (1 << 16))
            .min_by_key(|c| c.abs_diff(h))
            .unwrap_or(cand)
    }

    pub fn push(&mut self, seq: u16, payload: Vec<u8>) {
        if payload.is_empty() || payload.len() > 1500 {
            return;
        }
        let ext = self.extend(seq);
        if self.next.is_some_and(|n| ext < n) {
            self.stats.late += 1;
            return;
        }
        if self.highest.is_none_or(|h| ext > h) {
            self.highest = Some(ext);
        }
        if self.packets.insert(ext, payload).is_none() {
            self.stats.received += 1;
        }
        while self.packets.len() > MAX_PACKETS {
            // Far behind: drop the oldest and skip ahead.
            if let Some((&k, _)) = self.packets.iter().next() {
                self.packets.remove(&k);
                self.next = self.packets.keys().next().copied();
            }
        }
    }

    /// The frame for the next 20 ms slot.
    pub fn pop(&mut self) -> Frame {
        if !self.playing {
            if self.packets.len() < self.target {
                return Frame::Silence;
            }
            self.playing = true;
            let first = self.packets.keys().next().copied();
            self.next = match (self.next, first) {
                (Some(n), Some(f)) => Some(n.max(f)),
                (_, f) => f,
            };
        }
        let Some(n) = self.next else {
            return Frame::Silence;
        };
        if let Some(p) = self.packets.remove(&n) {
            self.next = Some(n + 1);
            self.smooth += 1;
            if self.smooth >= SHRINK_AFTER && self.target > MIN_TARGET {
                self.target -= 1;
                self.smooth = 0;
            }
            return Frame::Packet(p);
        }
        if self.packets.is_empty() {
            // Underrun: rebuffer with a larger target.
            self.playing = false;
            self.stats.underruns += 1;
            self.target = (self.target + 1).min(MAX_TARGET);
            self.smooth = 0;
            return Frame::Silence;
        }
        self.stats.lost += 1;
        self.next = Some(n + 1);
        Frame::Lost {
            next: self.packets.get(&(n + 1)).cloned(),
        }
    }

    /// Loss ratio over everything seen so far (0.0 ..= 1.0).
    pub fn loss_ratio(&self) -> f32 {
        let total = self.stats.received + self.stats.lost;
        if total == 0 {
            0.0
        } else {
            self.stats.lost as f32 / total as f32
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(n: u8) -> Vec<u8> {
        vec![n]
    }

    #[test]
    fn buffers_then_plays_in_order() {
        let mut j = JitterBuffer::new();
        j.push(3, p(3));
        j.push(1, p(1));
        assert_eq!(j.pop(), Frame::Silence);
        j.push(2, p(2));
        assert_eq!(j.pop(), Frame::Packet(p(1)));
        assert_eq!(j.pop(), Frame::Packet(p(2)));
        assert_eq!(j.pop(), Frame::Packet(p(3)));
        assert_eq!(j.pop(), Frame::Silence);
        assert_eq!(j.stats.underruns, 1);
        assert_eq!(j.target(), 4);
    }

    #[test]
    fn loss_offers_fec_and_late_packets_are_dropped() {
        let mut j = JitterBuffer::new();
        for s in [10u16, 12, 13] {
            j.push(s, p(s as u8));
        }
        assert_eq!(j.pop(), Frame::Packet(p(10)));
        assert_eq!(j.pop(), Frame::Lost { next: Some(p(12)) });
        j.push(11, p(11)); // too late now
        assert_eq!(j.stats.late, 1);
        assert_eq!(j.pop(), Frame::Packet(p(12)));
        assert!(j.loss_ratio() > 0.0);
    }

    #[test]
    fn sequence_wraparound() {
        let mut j = JitterBuffer::new();
        for s in [65534u16, 65535, 0, 1] {
            j.push(s, p(s as u8));
        }
        let got: Vec<Frame> = (0..4).map(|_| j.pop()).collect();
        assert_eq!(
            got,
            vec![
                Frame::Packet(p(254)),
                Frame::Packet(p(255)),
                Frame::Packet(p(0)),
                Frame::Packet(p(1))
            ]
        );
    }

    #[test]
    fn bounded_under_floods_and_junk() {
        let mut j = JitterBuffer::new();
        for s in 0..10_000u32 {
            j.push((s * 7919) as u16, vec![1; 10]);
            assert!(j.len() <= MAX_PACKETS);
        }
        j.push(5, Vec::new());
        j.push(6, vec![0; 5000]);
        for _ in 0..200 {
            let _ = j.pop();
        }
    }

    #[test]
    fn target_shrinks_when_smooth() {
        let mut j = JitterBuffer::new();
        let mut seq = 0u16;
        for _ in 0..3 {
            j.push(seq, p(0));
            seq = seq.wrapping_add(1);
        }
        for _ in 0..(SHRINK_AFTER + 5) {
            j.push(seq, p(0));
            seq = seq.wrapping_add(1);
            assert!(matches!(j.pop(), Frame::Packet(_)));
        }
        assert_eq!(j.target(), 2);
    }
}
