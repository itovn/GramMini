// Phỏng theo Ferrogram — github.com/Dasemu/Ferrogram, src/net/calls/stun.rs
// Copyright (c) 2026 Darío Sevilla Muñoz. Giấy phép MIT (crates/gm-call/LICENSE-FERROGRAM).
// GramMini sửa: đường dẫn module (CallKey ở tg/mod.rs), âm thanh qua gm-opus.

//! Minimal STUN (RFC 5389) for ICE connectivity checks: binding requests and
//! responses with short-term credentials, MESSAGE-INTEGRITY (HMAC-SHA1) and
//! FINGERPRINT (CRC-32). Parsing is bounded and never panics.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use hmac::{KeyInit, Mac};

pub const MAGIC: u32 = 0x2112_a442;
pub const BINDING_REQUEST: u16 = 0x0001;
pub const BINDING_SUCCESS: u16 = 0x0101;
pub const BINDING_ERROR: u16 = 0x0111;
pub const BINDING_INDICATION: u16 = 0x0011;

pub const ATTR_USERNAME: u16 = 0x0006;
pub const ATTR_INTEGRITY: u16 = 0x0008;
pub const ATTR_ERROR_CODE: u16 = 0x0009;
pub const ATTR_XOR_MAPPED: u16 = 0x0020;
pub const ATTR_PRIORITY: u16 = 0x0024;
pub const ATTR_USE_CANDIDATE: u16 = 0x0025;
pub const ATTR_FINGERPRINT: u16 = 0x8028;
pub const ATTR_CONTROLLED: u16 = 0x8029;
pub const ATTR_CONTROLLING: u16 = 0x802a;

const FINGERPRINT_XOR: u32 = 0x5354_554e;
const MAX_ATTRS: usize = 32;

type HmacSha1 = hmac::Hmac<sha1::Sha1>;

/// Is this datagram a STUN message (RFC 7983 demultiplexing)?
pub fn looks_like_stun(b: &[u8]) -> bool {
    b.len() >= 20 && b[0] < 4 && u32::from_be_bytes([b[4], b[5], b[6], b[7]]) == MAGIC
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Message {
    pub kind: u16,
    pub txid: [u8; 12],
    pub attrs: Vec<(u16, Vec<u8>)>,
}

impl Message {
    pub fn new(kind: u16, txid: [u8; 12]) -> Self {
        Self {
            kind,
            txid,
            attrs: Vec::new(),
        }
    }

    pub fn attr(&self, t: u16) -> Option<&[u8]> {
        self.attrs
            .iter()
            .find(|(k, _)| *k == t)
            .map(|(_, v)| v.as_slice())
    }

    /// Gỡ lỗi (GramMini): các loại thuộc tính có trong tin.
    pub fn attr_types(&self) -> Vec<u16> {
        self.attrs.iter().map(|(t, _)| *t).collect()
    }

    pub fn has(&self, t: u16) -> bool {
        self.attr(t).is_some()
    }

    pub fn push(&mut self, t: u16, v: Vec<u8>) -> &mut Self {
        self.attrs.push((t, v));
        self
    }

    pub fn username(&self) -> Option<&str> {
        std::str::from_utf8(self.attr(ATTR_USERNAME)?).ok()
    }

    pub fn priority(&self) -> Option<u32> {
        let v = self.attr(ATTR_PRIORITY)?;
        Some(u32::from_be_bytes(v.get(..4)?.try_into().ok()?))
    }

    pub fn error_code(&self) -> Option<u16> {
        let v = self.attr(ATTR_ERROR_CODE)?;
        let class = u16::from(*v.get(2)? & 0x7);
        Some(class * 100 + u16::from(*v.get(3)?))
    }

    pub fn xor_mapped(&self) -> Option<SocketAddr> {
        decode_xor_addr(self.attr(ATTR_XOR_MAPPED)?, &self.txid)
    }

    /// Serialise, optionally adding MESSAGE-INTEGRITY (with `key`) and
    /// FINGERPRINT.
    pub fn encode(&self, key: Option<&[u8]>, fingerprint: bool) -> Vec<u8> {
        let mut out = Vec::with_capacity(128);
        out.extend_from_slice(&self.kind.to_be_bytes());
        out.extend_from_slice(&[0, 0]);
        out.extend_from_slice(&MAGIC.to_be_bytes());
        out.extend_from_slice(&self.txid);
        for (t, v) in &self.attrs {
            write_attr(&mut out, *t, v);
        }
        if let Some(key) = key {
            set_len(&mut out, 24);
            let mac = hmac_sha1(key, &out);
            write_attr(&mut out, ATTR_INTEGRITY, &mac);
        }
        if fingerprint {
            set_len(&mut out, 8);
            let crc = crc32fast::hash(&out) ^ FINGERPRINT_XOR;
            write_attr(&mut out, ATTR_FINGERPRINT, &crc.to_be_bytes());
        }
        set_len(&mut out, 0);
        out
    }

    pub fn decode(b: &[u8]) -> Option<Self> {
        if !looks_like_stun(b) {
            return None;
        }
        let len = usize::from(u16::from_be_bytes([b[2], b[3]]));
        if !len.is_multiple_of(4) || 20 + len > b.len() {
            return None;
        }
        let kind = u16::from_be_bytes([b[0], b[1]]);
        let mut txid = [0u8; 12];
        txid.copy_from_slice(&b[8..20]);
        let mut attrs = Vec::new();
        let mut at = 20;
        let end = 20 + len;
        while at + 4 <= end {
            if attrs.len() >= MAX_ATTRS {
                return None;
            }
            let t = u16::from_be_bytes([b[at], b[at + 1]]);
            let l = usize::from(u16::from_be_bytes([b[at + 2], b[at + 3]]));
            let v = b.get(at + 4..at + 4 + l)?;
            if at + 4 + l > end {
                return None;
            }
            attrs.push((t, v.to_vec()));
            at += 4 + l.div_ceil(4) * 4;
        }
        Some(Self { kind, txid, attrs })
    }
}

fn write_attr(out: &mut Vec<u8>, t: u16, v: &[u8]) {
    out.extend_from_slice(&t.to_be_bytes());
    out.extend_from_slice(&u16::try_from(v.len()).unwrap_or(0).to_be_bytes());
    out.extend_from_slice(v);
    while !out.len().is_multiple_of(4) {
        out.push(0);
    }
}

/// Set the header length to the body so far plus `extra`.
fn set_len(out: &mut [u8], extra: usize) {
    let len = u16::try_from(out.len() - 20 + extra).unwrap_or(0);
    out[2..4].copy_from_slice(&len.to_be_bytes());
}

fn hmac_sha1(key: &[u8], data: &[u8]) -> Vec<u8> {
    match <HmacSha1 as KeyInit>::new_from_slice(key) {
        Ok(mut m) => {
            m.update(data);
            m.finalize().into_bytes().to_vec()
        }
        Err(_) => vec![0; 20],
    }
}

/// Walk the raw attributes and return the offset of the attribute of type
/// `t` (start of its 4-byte header).
fn attr_offset(b: &[u8], t: u16) -> Option<usize> {
    let len = usize::from(u16::from_be_bytes([*b.get(2)?, *b.get(3)?]));
    let end = (20 + len).min(b.len());
    let mut at = 20;
    while at + 4 <= end {
        let ty = u16::from_be_bytes([b[at], b[at + 1]]);
        if ty == t {
            return Some(at);
        }
        let l = usize::from(u16::from_be_bytes([b[at + 2], b[at + 3]]));
        at += 4 + l.div_ceil(4) * 4;
    }
    None
}

/// Check MESSAGE-INTEGRITY of a raw message with `key`.
pub fn verify_integrity(b: &[u8], key: &[u8]) -> bool {
    let Some(at) = attr_offset(b, ATTR_INTEGRITY) else {
        return false;
    };
    let Some(mac) = b.get(at + 4..at + 24) else {
        return false;
    };
    let mut head = b[..at].to_vec();
    set_len(&mut head, 24);
    let expect = hmac_sha1(key, &head);
    expect.iter().zip(mac).fold(0u8, |d, (a, b)| d | (a ^ b)) == 0
}

/// Check FINGERPRINT if present (absent = fine).
pub fn verify_fingerprint(b: &[u8]) -> bool {
    let Some(at) = attr_offset(b, ATTR_FINGERPRINT) else {
        return true;
    };
    let Some(v) = b.get(at + 4..at + 8) else {
        return false;
    };
    let mut head = b[..at].to_vec();
    set_len(&mut head, 8);
    let crc = crc32fast::hash(&head) ^ FINGERPRINT_XOR;
    crc.to_be_bytes() == v
}

pub fn encode_xor_addr(addr: SocketAddr, txid: &[u8; 12]) -> Vec<u8> {
    let port = addr.port() ^ (MAGIC >> 16) as u16;
    let mut v = vec![0u8];
    match addr.ip() {
        IpAddr::V4(ip) => {
            v.push(1);
            v.extend_from_slice(&port.to_be_bytes());
            let x = u32::from(ip) ^ MAGIC;
            v.extend_from_slice(&x.to_be_bytes());
        }
        IpAddr::V6(ip) => {
            v.push(2);
            v.extend_from_slice(&port.to_be_bytes());
            let mut mask = [0u8; 16];
            mask[..4].copy_from_slice(&MAGIC.to_be_bytes());
            mask[4..].copy_from_slice(txid);
            let o = ip.octets();
            v.extend((0..16).map(|i| o[i] ^ mask[i]));
        }
    }
    v
}

pub fn decode_xor_addr(v: &[u8], txid: &[u8; 12]) -> Option<SocketAddr> {
    let family = *v.get(1)?;
    let port = u16::from_be_bytes([*v.get(2)?, *v.get(3)?]) ^ (MAGIC >> 16) as u16;
    match family {
        1 => {
            let x = u32::from_be_bytes(v.get(4..8)?.try_into().ok()?) ^ MAGIC;
            Some(SocketAddr::new(IpAddr::V4(Ipv4Addr::from(x)), port))
        }
        2 => {
            let raw = v.get(4..20)?;
            let mut mask = [0u8; 16];
            mask[..4].copy_from_slice(&MAGIC.to_be_bytes());
            mask[4..].copy_from_slice(txid);
            let o: [u8; 16] = core::array::from_fn(|i| raw[i] ^ mask[i]);
            Some(SocketAddr::new(IpAddr::V6(Ipv6Addr::from(o)), port))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(s: &str) -> Vec<u8> {
        let s: String = s.split_whitespace().collect();
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    /// A binding request built with the RFC 5769 §2.1 attributes and
    /// password, MAC and CRC computed independently (Python hmac + zlib).
    const REQUEST: &str = "000100442112a442b7e7a701bc34d686fa87dfae000600096576746a3a68367659000000002400046e0001ff80290008932ff9b151263b36000800147a4fd381024dda8ce796b852d31b217ef9bea49180280004e4d47651";
    const PASSWORD: &[u8] = b"VOkJxbRl1RmTxUk/WvJxBt";

    #[test]
    fn request_vector() {
        let raw = hex(REQUEST);
        let m = Message::decode(&raw).unwrap();
        assert_eq!(m.kind, BINDING_REQUEST);
        assert_eq!(m.username(), Some("evtj:h6vY"));
        assert_eq!(m.priority(), Some(0x6e0001ff));
        assert!(m.has(ATTR_CONTROLLED));
        assert!(verify_integrity(&raw, PASSWORD));
        assert!(!verify_integrity(&raw, b"wrong"));
        assert!(verify_fingerprint(&raw));
        let mut bad = raw.clone();
        bad[30] ^= 1;
        assert!(!verify_fingerprint(&bad));
        assert!(!verify_integrity(&bad, PASSWORD));
    }

    #[test]
    fn encode_matches_vector() {
        let raw = hex(REQUEST);
        let mut m = Message::new(BINDING_REQUEST, raw[8..20].try_into().unwrap());
        m.push(ATTR_USERNAME, b"evtj:h6vY".to_vec())
            .push(ATTR_PRIORITY, 0x6e0001ffu32.to_be_bytes().to_vec())
            .push(ATTR_CONTROLLED, hex("932ff9b151263b36"));
        assert_eq!(m.encode(Some(PASSWORD), true), raw);
    }

    #[test]
    fn xor_address_round_trip() {
        let tx = [9u8; 12];
        for a in [
            "192.0.2.1:32853",
            "[2001:db8:1234:5678:11:2233:4455:6677]:32853",
        ] {
            let addr: SocketAddr = a.parse().unwrap();
            assert_eq!(
                decode_xor_addr(&encode_xor_addr(addr, &tx), &tx),
                Some(addr)
            );
        }
        // RFC 5769 §2.2 response: XOR-MAPPED-ADDRESS 192.0.2.1:32853.
        let v = hex("0001a147e112a643");
        assert_eq!(
            decode_xor_addr(&v, &tx),
            Some("192.0.2.1:32853".parse().unwrap())
        );
        assert_eq!(decode_xor_addr(&[0, 9, 0, 0], &tx), None);
        assert_eq!(decode_xor_addr(&[0, 1], &tx), None);
    }

    #[test]
    fn hostile_messages() {
        assert!(Message::decode(&[]).is_none());
        assert!(Message::decode(&[0u8; 19]).is_none());
        let mut raw = hex(REQUEST);
        raw[3] = 0xff; // length beyond buffer
        assert!(Message::decode(&raw).is_none());
        let mut seed = 7u32;
        let base = hex(REQUEST);
        for _ in 0..20_000 {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12345);
            let mut p = base.clone();
            let i = (seed >> 8) as usize % p.len();
            p[i] = (seed >> 16) as u8;
            if seed.is_multiple_of(7) {
                p.truncate((seed >> 4) as usize % p.len());
            }
            if let Some(m) = Message::decode(&p) {
                let _ = (m.username(), m.priority(), m.xor_mapped(), m.error_code());
            }
            let _ = verify_integrity(&p, b"k");
            let _ = verify_fingerprint(&p);
        }
    }
}
