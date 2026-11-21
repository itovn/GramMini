//! Mã hoá gói của cuộc gọi (tgcalls `EncryptedConnection`, core.telegram.org/api/end-to-end/video-calls «Encrypting Call
//! Data»): msg_key = SHA256(key[88+x .. +32] ‖ body)[8 .. 24]; aes_key / aes_iv suy từ msg_key và key; AES-256-CTR.
//! x: 0 / 8 = đường truyền (bên gọi / bên nghe gửi), 128 / 136 = báo hiệu (phone.sendSignalingData).

use aes::Aes256;
use aes::cipher::{KeyIvInit, StreamCipher};
use sha2::{Digest as _, Sha256};

type Ctr = ctr::Ctr128BE<Aes256>;

/// Loại kênh: báo hiệu (qua máy chủ Telegram) hay đường truyền (UDP / TURN).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Channel {
    Transport,
    Signaling,
}

/// x của bên gửi: bên gọi 0, bên nghe 8; báo hiệu cộng 128.
pub fn x_for(sender_is_caller: bool, ch: Channel) -> usize {
    (if sender_is_caller { 0 } else { 8 }) + if ch == Channel::Signaling { 128 } else { 0 }
}

fn kdf(key: &[u8; 256], msg_key: &[u8], x: usize) -> ([u8; 32], [u8; 16]) {
    let mut ha = Sha256::new();
    ha.update(msg_key);
    ha.update(&key[x..x + 36]);
    let a = ha.finalize();
    let mut hb = Sha256::new();
    hb.update(&key[40 + x..40 + x + 36]);
    hb.update(msg_key);
    let b = hb.finalize();
    let mut aes_key = [0u8; 32];
    aes_key[..8].copy_from_slice(&a[..8]);
    aes_key[8..24].copy_from_slice(&b[8..24]);
    aes_key[24..].copy_from_slice(&a[24..32]);
    let mut iv = [0u8; 16];
    iv[..4].copy_from_slice(&b[..4]);
    iv[4..12].copy_from_slice(&a[8..16]);
    iv[12..].copy_from_slice(&b[24..28]);
    (aes_key, iv)
}

fn msg_key(key: &[u8; 256], body: &[u8], x: usize) -> [u8; 16] {
    let mut h = Sha256::new();
    h.update(&key[88 + x..88 + x + 32]);
    h.update(body);
    let d = h.finalize();
    d[8..24].try_into().unwrap()
}

/// packet = msg_key (16) ‖ AES-CTR(body).
pub fn encrypt(key: &[u8; 256], x: usize, body: &[u8]) -> Vec<u8> {
    let mk = msg_key(key, body, x);
    let (k, iv) = kdf(key, &mk, x);
    let mut out = Vec::with_capacity(16 + body.len());
    out.extend_from_slice(&mk);
    out.extend_from_slice(body);
    Ctr::new(&k.into(), &iv.into()).apply_keystream(&mut out[16..]);
    out
}

/// Giải mã + kiểm msg_key (sai → None, phải bỏ gói).
pub fn decrypt(key: &[u8; 256], x: usize, packet: &[u8]) -> Option<Vec<u8>> {
    if packet.len() < 17 {
        return None;
    }
    let (mk, enc) = packet.split_at(16);
    let (k, iv) = kdf(key, mk, x);
    let mut body = enc.to_vec();
    Ctr::new(&k.into(), &iv.into()).apply_keystream(&mut body);
    (msg_key(key, &body, x) == mk).then_some(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let mut key = [0u8; 256];
        for (i, b) in key.iter_mut().enumerate() {
            *b = i as u8;
        }
        let x = x_for(false, Channel::Signaling);
        let p = encrypt(&key, x, b"hello tgcalls");
        assert_eq!(decrypt(&key, x, &p).as_deref(), Some(&b"hello tgcalls"[..]));
        assert!(decrypt(&key, x_for(true, Channel::Signaling), &p).is_none());
    }
}
