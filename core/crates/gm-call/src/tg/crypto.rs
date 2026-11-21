// Phỏng theo Ferrogram — github.com/Dasemu/Ferrogram, src/net/calls/crypto.rs
// Copyright (c) 2026 Darío Sevilla Muñoz. Giấy phép MIT (crates/gm-call/LICENSE-FERROGRAM).
// GramMini sửa: đường dẫn module (CallKey ở tg/mod.rs), âm thanh qua gm-opus.

//! Packet encryption with the call key, as used by the tgcalls signaling
//! channel: `msg_key` is bytes 8..24 of SHA-256(key[88+x .. 120+x] ||
//! plaintext), the AES-256 key and IV come from the MTProto 2.0 KDF, and the
//! cipher is AES-256-CTR. `x` is 128 for signaling plus 0 for packets the
//! caller sends and 8 for packets the callee sends.

use aes::cipher::{KeyIvInit, StreamCipher};
use sha2::{Digest, Sha256};

use super::CallKey;

type Aes256Ctr = ctr::Ctr128BE<aes::Aes256>;

/// Upper bound for anything we try to decrypt.
pub const MAX_PACKET: usize = 128 * 1024;

/// MTProto 2.0 key derivation (`PrepareAesKeyIv` in the reference code).
pub fn aes_key_iv(key: &[u8; 256], msg_key: &[u8; 16], x: usize) -> ([u8; 32], [u8; 16]) {
    let mut a = Sha256::new();
    a.update(msg_key);
    a.update(&key[x..x + 36]);
    let a = a.finalize();
    let mut b = Sha256::new();
    b.update(&key[40 + x..40 + x + 36]);
    b.update(msg_key);
    let b = b.finalize();
    let mut k = [0u8; 32];
    k[..8].copy_from_slice(&a[..8]);
    k[8..24].copy_from_slice(&b[8..24]);
    k[24..].copy_from_slice(&a[24..32]);
    let mut iv = [0u8; 16];
    iv[..4].copy_from_slice(&b[..4]);
    iv[4..12].copy_from_slice(&a[8..16]);
    iv[12..].copy_from_slice(&b[24..28]);
    (k, iv)
}

fn ctr(key: &[u8; 32], iv: &[u8; 16], data: &mut [u8]) {
    let mut c = Aes256Ctr::new(key.into(), iv.into());
    c.apply_keystream(data);
}

fn msg_key(key: &[u8; 256], x: usize, plain: &[u8]) -> [u8; 16] {
    let mut h = Sha256::new();
    h.update(&key[88 + x..120 + x]);
    h.update(plain);
    let d = h.finalize();
    let mut m = [0u8; 16];
    m.copy_from_slice(&d[8..24]);
    m
}

/// Which way a packet travels, from our point of view.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Direction {
    /// We placed the call.
    pub outgoing: bool,
}

impl Direction {
    fn send_x(self) -> usize {
        128 + if self.outgoing { 0 } else { 8 }
    }
    fn recv_x(self) -> usize {
        128 + if self.outgoing { 8 } else { 0 }
    }
}

/// Encrypt a signaling plaintext: `msg_key (16) || AES-CTR(plain)`.
pub fn encrypt(key: &CallKey, dir: Direction, plain: &[u8]) -> Vec<u8> {
    let x = dir.send_x();
    let mk = msg_key(&key.0, x, plain);
    let (k, iv) = aes_key_iv(&key.0, &mk, x);
    let mut out = Vec::with_capacity(16 + plain.len());
    out.extend_from_slice(&mk);
    out.extend_from_slice(plain);
    ctr(&k, &iv, &mut out[16..]);
    out
}

/// Decrypt and authenticate. `None` for anything malformed or forged.
pub fn decrypt(key: &CallKey, dir: Direction, packet: &[u8]) -> Option<Vec<u8>> {
    // 16 bytes msg_key + at least a 4-byte seq + 1 byte.
    if packet.len() < 21 || packet.len() > MAX_PACKET {
        return None;
    }
    let x = dir.recv_x();
    let mut mk = [0u8; 16];
    mk.copy_from_slice(&packet[..16]);
    let (k, iv) = aes_key_iv(&key.0, &mk, x);
    let mut plain = packet[16..].to_vec();
    ctr(&k, &iv, &mut plain);
    let expect = msg_key(&key.0, x, &plain);
    // Constant-time compare.
    let diff = expect
        .iter()
        .zip(mk.iter())
        .fold(0u8, |d, (a, b)| d | (a ^ b));
    (diff == 0).then_some(plain)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> CallKey {
        let mut k = [0u8; 256];
        for (i, b) in k.iter_mut().enumerate() {
            *b = (i * 7 + 3) as u8;
        }
        CallKey(k)
    }

    #[test]
    fn round_trip_between_caller_and_callee() {
        let k = key();
        let caller = Direction { outgoing: true };
        let callee = Direction { outgoing: false };
        let p = encrypt(&k, caller, b"\x00\x00\x00\x01hello world");
        assert_eq!(
            decrypt(&k, callee, &p).as_deref(),
            Some(&b"\x00\x00\x00\x01hello world"[..])
        );
        // Our own packet does not decrypt as an incoming one (x differs).
        assert_eq!(decrypt(&k, caller, &p), None);
        let q = encrypt(&k, callee, b"\x00\x00\x00\x02back again");
        assert!(decrypt(&k, caller, &q).is_some());
    }

    #[test]
    fn tampering_and_sizes_are_rejected() {
        let k = key();
        let dir = Direction { outgoing: true };
        let mut p = encrypt(&k, dir, b"\x00\x00\x00\x01payload!");
        let rx = Direction { outgoing: false };
        for i in [0, 15, 16, p.len() - 1] {
            p[i] ^= 1;
            assert_eq!(decrypt(&k, rx, &p), None, "byte {i}");
            p[i] ^= 1;
        }
        assert_eq!(decrypt(&k, rx, &p[..20]), None);
        assert_eq!(decrypt(&k, rx, &vec![0u8; MAX_PACKET + 1]), None);
        assert_eq!(decrypt(&k, rx, &[]), None);
    }

    /// The KDF layout and AES-256-CTR checked against an independent
    /// implementation (Python hashlib + `openssl enc -aes-256-ctr`).
    #[test]
    fn kdf_and_ctr_vector() {
        let k = key();
        let mk: [u8; 16] = core::array::from_fn(|i| i as u8);
        let (aes_key, iv) = aes_key_iv(&k.0, &mk, 128);
        assert_eq!(hex(&aes_key), KDF_KEY);
        assert_eq!(hex(&iv), KDF_IV);
        let mut data = *b"0123456789abcdefXYZ";
        ctr(&aes_key, &iv, &mut data);
        assert_eq!(hex(&data), CTR_OUT);
    }

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    const KDF_KEY: &str = "cf7038b2f33b42b6f9e3145c0454dd839a1d4c1986bbebc52bde77ae967b5ccd";
    const KDF_IV: &str = "ebad2e4db2937df2ce95e3ab05eda544";
    const CTR_OUT: &str = "dc863ba700391e581cf6c114eb19c17b28d07c";
}
