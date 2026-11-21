// Phỏng theo Ferrogram — github.com/Dasemu/Ferrogram, src/net/calls/rtp.rs
// Copyright (c) 2026 Darío Sevilla Muñoz. Giấy phép MIT (crates/gm-call/LICENSE-FERROGRAM).
// GramMini sửa: đường dẫn module (CallKey ở tg/mod.rs), âm thanh qua gm-opus.

//! RTP header encoding/decoding (RFC 3550), bounded and panic-free.

/// Is this datagram RTP or RTCP (RFC 7983: first byte 128..=191)?
pub fn looks_like_rtp(b: &[u8]) -> bool {
    b.len() >= 12 && (128..=191).contains(&b[0])
}

/// RTCP packet types live in 192..=223 (RFC 5761 demultiplexing).
pub fn is_rtcp(b: &[u8]) -> bool {
    b.len() >= 8 && (192..=223).contains(&b[1])
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header {
    pub marker: bool,
    pub payload_type: u8,
    pub seq: u16,
    pub timestamp: u32,
    pub ssrc: u32,
}

impl Header {
    /// A 12-byte header (no CSRCs, no extension) followed by `payload`.
    pub fn packet(&self, payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(12 + payload.len());
        out.push(0x80);
        out.push((u8::from(self.marker) << 7) | (self.payload_type & 0x7f));
        out.extend_from_slice(&self.seq.to_be_bytes());
        out.extend_from_slice(&self.timestamp.to_be_bytes());
        out.extend_from_slice(&self.ssrc.to_be_bytes());
        out.extend_from_slice(payload);
        out
    }
}

/// Parse a (decrypted) RTP packet: the header and the payload range, with
/// CSRCs, the header extension and padding skipped.
pub fn parse(b: &[u8]) -> Option<(Header, std::ops::Range<usize>)> {
    if b.len() < 12 || b[0] >> 6 != 2 {
        return None;
    }
    let cc = usize::from(b[0] & 0x0f);
    let mut start = 12 + 4 * cc;
    if b[0] & 0x10 != 0 {
        let ext = b.get(start..start + 4)?;
        let words = usize::from(u16::from_be_bytes([ext[2], ext[3]]));
        start += 4 + 4 * words;
    }
    let mut end = b.len();
    if b[0] & 0x20 != 0 {
        let pad = usize::from(*b.last()?);
        if pad == 0 {
            return None;
        }
        end = end.checked_sub(pad)?;
    }
    if start > end {
        return None;
    }
    Some((
        Header {
            marker: b[1] & 0x80 != 0,
            payload_type: b[1] & 0x7f,
            seq: u16::from_be_bytes([b[2], b[3]]),
            timestamp: u32::from_be_bytes([b[4], b[5], b[6], b[7]]),
            ssrc: u32::from_be_bytes([b[8], b[9], b[10], b[11]]),
        },
        start..end,
    ))
}

/// The header length (12 + CSRCs + extension), for SRTP, which encrypts
/// only what follows.
pub fn header_len(b: &[u8]) -> Option<usize> {
    if b.len() < 12 {
        return None;
    }
    let cc = usize::from(b[0] & 0x0f);
    let mut n = 12 + 4 * cc;
    if b[0] & 0x10 != 0 {
        let ext = b.get(n..n + 4)?;
        n += 4 + 4 * usize::from(u16::from_be_bytes([ext[2], ext[3]]));
    }
    (n <= b.len()).then_some(n)
}

/// A minimal RTCP receiver report with no report blocks, so the peer's
/// RTCP-based liveness sees us. `ssrc` is ours.
pub fn empty_receiver_report(ssrc: u32) -> Vec<u8> {
    let mut v = vec![0x80, 201, 0, 1];
    v.extend_from_slice(&ssrc.to_be_bytes());
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let h = Header {
            marker: true,
            payload_type: 111,
            seq: 65535,
            timestamp: 0xdead_beef,
            ssrc: 42,
        };
        let p = h.packet(b"opus!");
        let (back, range) = parse(&p).unwrap();
        assert_eq!(back, h);
        assert_eq!(&p[range], b"opus!");
        assert_eq!(header_len(&p), Some(12));
        assert!(looks_like_rtp(&p));
        assert!(!is_rtcp(&p));
        assert!(is_rtcp(&empty_receiver_report(1)));
    }

    #[test]
    fn extension_csrc_and_padding() {
        // V=2 P=1 X=1 CC=1, then 1 CSRC, a 1-word extension, payload, 2 pad bytes.
        let mut p = vec![0xb1, 111, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3];
        p.extend_from_slice(&[0, 0, 0, 9]); // CSRC
        p.extend_from_slice(&[0xbe, 0xde, 0, 1, 0x10, 0xff, 0, 0]); // ext
        p.extend_from_slice(b"abc");
        p.extend_from_slice(&[0, 2]);
        let (h, r) = parse(&p).unwrap();
        assert_eq!(h.ssrc, 3);
        assert_eq!(&p[r], b"abc");
        assert_eq!(header_len(&p), Some(24));
    }

    #[test]
    fn hostile_packets() {
        assert!(parse(&[]).is_none());
        assert!(parse(&[0x80; 11]).is_none());
        assert!(parse(&[0x40; 20]).is_none()); // version 1
        // Padding longer than the packet.
        let mut p = vec![0xa0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 200];
        assert!(parse(&p).is_none());
        p[12] = 0;
        assert!(parse(&p).is_none());
        // Extension beyond the end.
        let p = [
            0x90, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xbe, 0xde, 0xff, 0xff,
        ];
        assert!(parse(&p).is_none());
        assert!(header_len(&p).is_none());
        for n in 0..64u8 {
            let p: Vec<u8> = (0..n).map(|i| i.wrapping_mul(37) ^ 0x9a).collect();
            let _ = (parse(&p), header_len(&p));
        }
    }
}
