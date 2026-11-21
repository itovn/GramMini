// Phỏng theo Ferrogram — github.com/Dasemu/Ferrogram, src/net/calls/srtp.rs
// Copyright (c) 2026 Darío Sevilla Muñoz. Giấy phép MIT (crates/gm-call/LICENSE-FERROGRAM).
// GramMini sửa: đường dẫn module (CallKey ở tg/mod.rs), âm thanh qua gm-opus.

//! SRTP / SRTCP with `AES_CM_128_HMAC_SHA1_80` (RFC 3711), the profile
//! libwebrtc always offers. Keys come from the DTLS exporter
//! ("EXTRACTOR-dtls_srtp", RFC 5764).

use aes::cipher::{KeyIvInit, StreamCipher};
use hmac::{KeyInit, Mac};

use super::rtp;

type Aes128Ctr = ctr::Ctr128BE<aes::Aes128>;
type HmacSha1 = hmac::Hmac<sha1::Sha1>;

pub const MASTER_KEY_LEN: usize = 16;
pub const MASTER_SALT_LEN: usize = 14;
const TAG_LEN: usize = 10;
const REPLAY_WINDOW: u64 = 64;
/// Exporter output length: two keys and two salts.
pub const EXPORT_LEN: usize = 2 * (MASTER_KEY_LEN + MASTER_SALT_LEN);

fn derive(master_key: &[u8; 16], master_salt: &[u8; 14], label: u8, out: &mut [u8]) {
    let mut iv = [0u8; 16];
    iv[..14].copy_from_slice(master_salt);
    iv[7] ^= label;
    out.fill(0);
    let mut c = Aes128Ctr::new(master_key.into(), (&iv).into());
    c.apply_keystream(out);
}

#[derive(Clone)]
struct Keys {
    enc: [u8; 16],
    auth: [u8; 20],
    salt: [u8; 14],
}

impl Keys {
    fn new(key: &[u8; 16], salt: &[u8; 14], base: u8) -> Self {
        let mut k = Self {
            enc: [0; 16],
            auth: [0; 20],
            salt: [0; 14],
        };
        derive(key, salt, base, &mut k.enc);
        derive(key, salt, base + 1, &mut k.auth);
        derive(key, salt, base + 2, &mut k.salt);
        k
    }

    fn crypt(&self, ssrc: u32, index: u64, data: &mut [u8]) {
        let mut iv = [0u8; 16];
        iv[..14].copy_from_slice(&self.salt);
        for (i, b) in ssrc.to_be_bytes().iter().enumerate() {
            iv[4 + i] ^= b;
        }
        let idx = index.to_be_bytes(); // 48-bit index in the low 6 bytes
        for i in 0..6 {
            iv[8 + i] ^= idx[2 + i];
        }
        let mut c = Aes128Ctr::new((&self.enc).into(), (&iv).into());
        c.apply_keystream(data);
    }

    fn tag(&self, parts: &[&[u8]]) -> [u8; TAG_LEN] {
        let mut out = [0u8; TAG_LEN];
        if let Ok(mut m) = <HmacSha1 as KeyInit>::new_from_slice(&self.auth) {
            for p in parts {
                m.update(p);
            }
            out.copy_from_slice(&m.finalize().into_bytes()[..TAG_LEN]);
        }
        out
    }
}

/// Sliding replay window over 48-bit packet indices.
#[derive(Default, Clone)]
struct Replay {
    max: Option<u64>,
    bits: u64,
}

impl Replay {
    fn check(&self, idx: u64) -> bool {
        match self.max {
            None => true,
            Some(m) if idx > m => true,
            Some(m) => m - idx < REPLAY_WINDOW && self.bits & (1 << (m - idx)) == 0,
        }
    }

    fn accept(&mut self, idx: u64) {
        match self.max {
            None => {
                self.max = Some(idx);
                self.bits = 1;
            }
            Some(m) if idx > m => {
                let shift = idx - m;
                self.bits = if shift >= REPLAY_WINDOW {
                    0
                } else {
                    self.bits << shift
                } | 1;
                self.max = Some(idx);
            }
            Some(m) => self.bits |= 1 << (m - idx),
        }
    }
}

/// One direction of an SRTP session (one master key/salt).
pub struct Context {
    rtp: Keys,
    rtcp: Keys,
    /// Sender: rollover counter of our own sequence numbers.
    roc: u32,
    last_seq: Option<u16>,
    srtcp_index: u32,
    /// Receiver state (single remote SSRC is all a 1:1 call needs).
    rx_roc: u32,
    rx_seq: Option<u16>,
    replay: Replay,
    /// Cửa sổ chống phát lại SRTCP theo từng SSRC người gửi (GramMini: app Telegram gửi RR từ SSRC nhận và SR từ SSRC gửi,
    /// mỗi SSRC đánh chỉ số SRTCP riêng — một cửa sổ chung làm rơi một nửa số gói).
    rtcp_replay: Vec<(u32, Replay)>,
}

impl std::fmt::Debug for Context {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("srtp::Context(..)")
    }
}

impl Context {
    pub fn new(master_key: &[u8; 16], master_salt: &[u8; 14]) -> Self {
        Self {
            rtp: Keys::new(master_key, master_salt, 0),
            rtcp: Keys::new(master_key, master_salt, 3),
            roc: 0,
            last_seq: None,
            srtcp_index: 0,
            rx_roc: 0,
            rx_seq: None,
            replay: Replay::default(),
            rtcp_replay: Vec::new(),
        }
    }

    /// Split RFC 5764 exporter output into (local, remote) contexts.
    /// Layout: client key, server key, client salt, server salt.
    pub fn pair_from_export(material: &[u8], is_client: bool) -> Option<(Self, Self)> {
        if material.len() < EXPORT_LEN {
            return None;
        }
        let ck: [u8; 16] = material[0..16].try_into().ok()?;
        let sk: [u8; 16] = material[16..32].try_into().ok()?;
        let cs: [u8; 14] = material[32..46].try_into().ok()?;
        let ss: [u8; 14] = material[46..60].try_into().ok()?;
        let client = Self::new(&ck, &cs);
        let server = Self::new(&sk, &ss);
        Some(if is_client {
            (client, server)
        } else {
            (server, client)
        })
    }

    /// Protect an RTP packet (header in the clear, payload encrypted, tag).
    pub fn protect_rtp(&mut self, packet: &[u8]) -> Option<Vec<u8>> {
        let hl = rtp::header_len(packet)?;
        let seq = u16::from_be_bytes([packet[2], packet[3]]);
        let ssrc = u32::from_be_bytes([packet[8], packet[9], packet[10], packet[11]]);
        if let Some(last) = self.last_seq
            && seq < last
            && last - seq > 0x8000
        {
            self.roc = self.roc.wrapping_add(1);
        }
        self.last_seq = Some(seq);
        let index = (u64::from(self.roc) << 16) | u64::from(seq);
        let mut out = packet.to_vec();
        self.rtp.crypt(ssrc, index, &mut out[hl..]);
        let tag = self.rtp.tag(&[&out, &self.roc.to_be_bytes()]);
        out.extend_from_slice(&tag);
        Some(out)
    }

    /// Estimate the rollover counter of an incoming sequence number
    /// (RFC 3711 appendix A).
    fn estimate_roc(&self, seq: u16) -> u32 {
        let Some(s_l) = self.rx_seq else {
            return self.rx_roc;
        };
        let roc = self.rx_roc;
        if s_l < 0x8000 {
            if seq > s_l && seq - s_l > 0x8000 {
                roc.wrapping_sub(1)
            } else {
                roc
            }
        } else if s_l - 0x8000 > seq {
            roc.wrapping_add(1)
        } else {
            roc
        }
    }

    /// Authenticate, replay-check and decrypt an incoming SRTP packet.
    pub fn unprotect_rtp(&mut self, packet: &[u8]) -> Option<Vec<u8>> {
        if packet.len() < 12 + TAG_LEN {
            return None;
        }
        let body = &packet[..packet.len() - TAG_LEN];
        let hl = rtp::header_len(body)?;
        let seq = u16::from_be_bytes([body[2], body[3]]);
        let ssrc = u32::from_be_bytes([body[8], body[9], body[10], body[11]]);
        let roc = self.estimate_roc(seq);
        let index = (u64::from(roc) << 16) | u64::from(seq);
        if !self.replay.check(index) {
            return None;
        }
        let tag = self.rtp.tag(&[body, &roc.to_be_bytes()]);
        let got = &packet[packet.len() - TAG_LEN..];
        if tag.iter().zip(got).fold(0u8, |d, (a, b)| d | (a ^ b)) != 0 {
            return None;
        }
        self.replay.accept(index);
        let newer = self.rx_seq.is_none()
            || roc > self.rx_roc
            || (roc == self.rx_roc && Some(seq) > self.rx_seq);
        if newer {
            self.rx_roc = roc;
            self.rx_seq = Some(seq);
        }
        let mut out = body.to_vec();
        self.rtp.crypt(ssrc, index, &mut out[hl..]);
        Some(out)
    }

    /// Protect an RTCP packet (first 8 bytes in the clear, E flag set).
    pub fn protect_rtcp(&mut self, packet: &[u8]) -> Option<Vec<u8>> {
        if packet.len() < 8 {
            return None;
        }
        self.srtcp_index = (self.srtcp_index + 1) & 0x7fff_ffff;
        let ssrc = u32::from_be_bytes([packet[4], packet[5], packet[6], packet[7]]);
        let mut out = packet.to_vec();
        self.rtcp
            .crypt(ssrc, u64::from(self.srtcp_index), &mut out[8..]);
        out.extend_from_slice(&(self.srtcp_index | 0x8000_0000).to_be_bytes());
        let tag = self.rtcp.tag(&[&out]);
        out.extend_from_slice(&tag);
        Some(out)
    }

    /// Authenticate and decrypt an incoming SRTCP packet.
    pub fn unprotect_rtcp(&mut self, packet: &[u8]) -> Option<Vec<u8>> {
        if packet.len() < 8 + 4 + TAG_LEN {
            return None;
        }
        let tagged = &packet[..packet.len() - TAG_LEN];
        let tag = self.rtcp.tag(&[tagged]);
        let got = &packet[packet.len() - TAG_LEN..];
        if tag.iter().zip(got).fold(0u8, |d, (a, b)| d | (a ^ b)) != 0 {
            return None;
        }
        let e_idx = u32::from_be_bytes(tagged[tagged.len() - 4..].try_into().ok()?);
        let index = u64::from(e_idx & 0x7fff_ffff);
        let sender = u32::from_be_bytes(tagged[4..8].try_into().ok()?);
        let pos = match self.rtcp_replay.iter().position(|(s, _)| *s == sender) {
            Some(i) => i,
            None => {
                if self.rtcp_replay.len() >= 8 {
                    self.rtcp_replay.remove(0);
                }
                self.rtcp_replay.push((sender, Replay::default()));
                self.rtcp_replay.len() - 1
            }
        };
        let replay = &mut self.rtcp_replay[pos].1;
        if !replay.check(index) {
            return None;
        }
        replay.accept(index);
        let mut out = tagged[..tagged.len() - 4].to_vec();
        if e_idx & 0x8000_0000 != 0 {
            let ssrc = u32::from_be_bytes([out[4], out[5], out[6], out[7]]);
            self.rtcp.crypt(ssrc, index, &mut out[8..]);
        }
        Some(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    const MK: &str = "e1f97a0d3e018be0d64fa32c06de4139";
    const MS: &str = "0ec675ad498afeebb6960b3aabe6";

    fn ctx() -> Context {
        Context::new(&hex(MK).try_into().unwrap(), &hex(MS).try_into().unwrap())
    }

    /// RFC 3711 appendix B.3 (key derivation).
    #[test]
    fn rfc3711_key_derivation() {
        let k = Keys::new(
            &hex(MK).try_into().unwrap(),
            &hex(MS).try_into().unwrap(),
            0,
        );
        assert_eq!(k.enc.to_vec(), hex("c61e7a93744f39ee10734afe3ff7a087"));
        assert_eq!(k.salt.to_vec(), hex("30cbbc08863d8c85d49db34a9ae1"));
        assert_eq!(
            k.auth.to_vec(),
            hex("cebe321f6ff7716b6fd4ab49af256a156d38baa4")
        );
    }

    /// A full SRTP packet computed independently (openssl aes-128-ctr for the
    /// keystream, Python hmac for the tag).
    #[test]
    fn srtp_packet_vector() {
        let rtp = rtp::Header {
            marker: false,
            payload_type: 111,
            seq: 0x1234,
            timestamp: 0xcafebabe,
            ssrc: 0xdeadbeef,
        }
        .packet(b"hello, srtp world");
        let p = ctx().protect_rtp(&rtp).unwrap();
        assert_eq!(p, hex(SRTP_VECTOR));
        assert_eq!(ctx().unprotect_rtp(&p).unwrap(), rtp);
    }

    const SRTP_VECTOR: &str =
        "806f1234cafebabedeadbeef767243821922664e5059641bfc6b9620ac213b96df8e6a6e601621";

    #[test]
    fn round_trips_and_replay() {
        let mut tx = ctx();
        let mut rx = ctx();
        for seq in [65530u16, 65531, 65535, 0, 1, 2] {
            let rtp = rtp::Header {
                marker: false,
                payload_type: 111,
                seq,
                timestamp: 1,
                ssrc: 7,
            }
            .packet(&[seq as u8; 40]);
            let p = tx.protect_rtp(&rtp).unwrap();
            assert_eq!(rx.unprotect_rtp(&p).as_deref(), Some(&rtp[..]), "seq {seq}");
            assert!(rx.unprotect_rtp(&p).is_none(), "replay {seq}");
        }
        let rr = rtp::empty_receiver_report(9);
        let p = tx.protect_rtcp(&rr).unwrap();
        assert_eq!(rx.unprotect_rtcp(&p), Some(rr));
        assert!(rx.unprotect_rtcp(&p).is_none());
    }

    /// Hai SSRC người gửi (RR của luồng nhận + SR của luồng gửi, như app Telegram) đánh chỉ số SRTCP riêng: cùng chỉ số
    /// vẫn phải nhận cả hai.
    #[test]
    fn rtcp_replay_per_sender() {
        let (mut tx_a, mut tx_b, mut rx) = (ctx(), ctx(), ctx());
        let (ra, rb) = (rtp::empty_receiver_report(1), rtp::empty_receiver_report(2));
        for _ in 0..3 {
            let (pa, pb) = (tx_a.protect_rtcp(&ra).unwrap(), tx_b.protect_rtcp(&rb).unwrap());
            assert_eq!(rx.unprotect_rtcp(&pa), Some(ra.clone()));
            assert_eq!(rx.unprotect_rtcp(&pb), Some(rb.clone()));
            assert!(rx.unprotect_rtcp(&pb).is_none());
        }
    }

    #[test]
    fn export_split_pairs_up() {
        let m: Vec<u8> = (0..60).collect();
        let (mut client_tx, _) = Context::pair_from_export(&m, true).unwrap();
        let (_, mut server_rx) = Context::pair_from_export(&m, false).unwrap();
        let rtp = rtp::Header {
            marker: true,
            payload_type: 111,
            seq: 1,
            timestamp: 2,
            ssrc: 3,
        }
        .packet(b"x");
        let p = client_tx.protect_rtp(&rtp).unwrap();
        assert_eq!(server_rx.unprotect_rtp(&p), Some(rtp));
        assert!(Context::pair_from_export(&m[..59], true).is_none());
    }

    #[test]
    fn forged_and_short_packets() {
        let mut rx = ctx();
        assert!(rx.unprotect_rtp(&[]).is_none());
        assert!(rx.unprotect_rtp(&[0x80; 21]).is_none());
        let mut p = ctx()
            .protect_rtp(
                &rtp::Header {
                    marker: false,
                    payload_type: 0,
                    seq: 5,
                    timestamp: 0,
                    ssrc: 0,
                }
                .packet(b"abc"),
            )
            .unwrap();
        let n = p.len();
        p[n - 1] ^= 1;
        assert!(rx.unprotect_rtp(&p).is_none());
        assert!(rx.unprotect_rtcp(&[0x80; 21]).is_none());
        for len in 0..80u8 {
            let junk: Vec<u8> = (0..len).map(|i| i.wrapping_mul(91) | 0x80).collect();
            let _ = (rx.unprotect_rtp(&junk), rx.unprotect_rtcp(&junk));
        }
    }
}
