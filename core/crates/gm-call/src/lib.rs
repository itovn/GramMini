//! gm-call — gọi thoại 1-1 Telegram (D38, `docs/PHUONG-AN-GOI-THOAI.md`).
//!
//! Bước G1: trao khoá Diffie–Hellman của cuộc gọi (core.telegram.org/api/end-to-end/video-calls) — kiểm cấu hình DH của máy chủ,
//! sinh g_a, tính khoá chung 256 byte, dấu khoá (key_fingerprint), 4 emoji khoá để hai bên so. Phần truyền âm thanh (tgcalls V2:
//! ICE + DTLS-SRTP + Opus) làm ở bước G2.

pub mod crypt;
mod emoji;
pub mod tg;

pub use emoji::EMOJI;

use num_bigint::BigUint;
use sha1::{Digest as _, Sha1};
use sha2::Sha256;

/// Số nguyên tố an toàn 2048 bit Telegram dùng cho chat bí mật / cuộc gọi (đường nhanh: khớp thì khỏi kiểm Miller–Rabin; không
/// khớp — máy chủ đổi số — thì kiểm đầy đủ).
const TG_PRIME_HEX: &str = "c71caeb9c6b1c9048e6c522f70f13f73980d40238e3e21c14934d037563d930f48198a0aa7c14058229493d22530f4dbfa336f6e0ac92513\
9543aed44cce7c3720fd51f69458705ac68cd4fe6b6b13abdc9746512969328454f18faf8c595f642477fe96bb2a941d5bcd1d4ac8cc49880708fa9b378e3c4f3a9060bee67c\
f9a4a4a695811051907e162753b56b0f6b410dba74d8a84b2a14b3144e0ef1284754fd17ed950d5965b4b9dd46582db1178d169c6bc465b0d6ff9ca3928fef5b9ae4e418fc15\
e83ebea0f87fa9ff5eed70050ded2849f47bf959d956850ce929851f0d8115f635b105ee2e4e15d04b2454bf6f4fadf034b10403119cd8e3b92fcc5b";

fn big(n: u32) -> BigUint {
    BigUint::from(n)
}

fn small(n: &BigUint) -> u32 {
    n.to_u32_digits().first().copied().unwrap_or(0)
}

fn random_bytes(n: usize) -> Vec<u8> {
    let mut v = vec![0u8; n];
    getrandom::fill(&mut v).expect("getrandom");
    v
}

/// Kiểm Miller–Rabin `rounds` lượt (cơ sở ngẫu nhiên).
fn probably_prime(n: &BigUint, rounds: usize) -> bool {
    let (one, two) = (big(1), big(2));
    if n < &two {
        return false;
    }
    for p in [2u32, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37] {
        if n == &big(p) {
            return true;
        }
        if small(&(n % big(p))) == 0 {
            return false;
        }
    }
    let n1 = n - &one;
    let s = n1.trailing_zeros().unwrap_or(0);
    let d = &n1 >> s;
    let span = n - big(3);
    let len = ((n.bits() + 7) / 8) as usize;
    'outer: for _ in 0..rounds {
        let a = BigUint::from_bytes_be(&random_bytes(len)) % &span + &two;
        let mut x = a.modpow(&d, n);
        if x == one || x == n1 {
            continue;
        }
        for _ in 1..s {
            x = x.modpow(&two, n);
            if x == n1 {
                continue 'outer;
            }
        }
        return false;
    }
    true
}

/// Số `x` viết big-endian đủ 256 byte (thêm 0 ở đầu).
fn to_256(x: &BigUint) -> [u8; 256] {
    let b = x.to_bytes_be();
    let mut out = [0u8; 256];
    out[256 - b.len()..].copy_from_slice(&b);
    out
}

/// Cấu hình DH đã kiểm (messages.getDhConfig).
pub struct DhConfig {
    p: BigUint,
    g: BigUint,
}

impl DhConfig {
    /// Kiểm như chat bí mật: p 2048 bit là số nguyên tố an toàn; g ∈ 2..7 sinh nhóm con cấp (p − 1) / 2 (điều kiện theo g).
    pub fn new(p_bytes: &[u8], g: i32) -> Result<Self, String> {
        let p = BigUint::from_bytes_be(p_bytes);
        if p.bits() != 2048 {
            return Err(format!("p của máy chủ dài {} bit (cần 2048)", p.bits()));
        }
        let known = BigUint::parse_bytes(TG_PRIME_HEX.as_bytes(), 16).expect("hằng số p");
        if p != known && !(probably_prime(&p, 30) && probably_prime(&((&p - big(1)) >> 1u32), 30)) {
            return Err("p của máy chủ không phải số nguyên tố an toàn".into());
        }
        let ok = match g {
            2 => small(&(&p % big(8))) == 7,
            3 => small(&(&p % big(3))) == 2,
            4 => true,
            5 => matches!(small(&(&p % big(5))), 1 | 4),
            6 => matches!(small(&(&p % big(24))), 19 | 23),
            7 => matches!(small(&(&p % big(7))), 3 | 5 | 6),
            _ => false,
        };
        if !ok {
            return Err(format!("g = {g} không hợp với p"));
        }
        Ok(Self { p, g: big(g as u32) })
    }

    /// 1 < x < p − 1 và 2^(2048−64) ≤ x ≤ p − 2^(2048−64) (chặn khoá yếu).
    fn check(&self, x: &BigUint) -> Result<(), String> {
        let lim = big(1) << (2048u32 - 64);
        if x <= &big(1) || x >= &(&self.p - big(1)) || x < &lim || x > &(&self.p - &lim) {
            return Err("giá trị DH của bên kia nằm ngoài khoảng an toàn".into());
        }
        Ok(())
    }
}

/// Một nửa cặp khoá của mình (a, g_a).
pub struct KeyPair {
    a: BigUint,
    /// g^a mod p, 256 byte big-endian.
    pub g_a: [u8; 256],
}

impl KeyPair {
    /// `server_random`: `random` của getDhConfig — trộn (XOR) với ngẫu nhiên của máy như hướng dẫn của Telegram.
    pub fn new(cfg: &DhConfig, server_random: &[u8]) -> Result<Self, String> {
        loop {
            let mut r = random_bytes(256);
            for (x, y) in r.iter_mut().zip(server_random) {
                *x ^= *y;
            }
            let a = BigUint::from_bytes_be(&r);
            let g_a = cfg.g.modpow(&a, &cfg.p);
            if cfg.check(&g_a).is_ok() {
                return Ok(Self { a, g_a: to_256(&g_a) });
            }
        }
    }

    /// SHA256(g_a) — gửi trong phone.requestCall (bên gọi chưa lộ g_a cho tới khi bên kia gửi g_b).
    pub fn g_a_hash(&self) -> [u8; 32] {
        Sha256::digest(self.g_a).into()
    }

    /// Khoá chung = g_b^a mod p (256 byte), sau khi kiểm g_b.
    pub fn shared_key(&self, cfg: &DhConfig, g_b: &[u8]) -> Result<[u8; 256], String> {
        let gb = BigUint::from_bytes_be(g_b);
        cfg.check(&gb)?;
        Ok(to_256(&gb.modpow(&self.a, &cfg.p)))
    }
}

/// Bên nghe kiểm g_a bên gọi gửi trong phoneCall khớp g_a_hash đã nhận trong phoneCallRequested (bên gọi không được đổi g_a
/// sau khi thấy g_b).
pub fn g_a_matches_hash(g_a: &[u8], g_a_hash: &[u8]) -> bool {
    let h: [u8; 32] = Sha256::digest(g_a).into();
    g_a_hash.len() == 32 && h.iter().zip(g_a_hash).fold(0u8, |d, (a, b)| d | (a ^ b)) == 0
}

/// key_fingerprint: 64 bit thấp của SHA1(key) (8 byte cuối, little-endian) — như auth_key_id / chat bí mật.
pub fn key_fingerprint(key: &[u8; 256]) -> i64 {
    let h = Sha1::digest(key);
    i64::from_le_bytes(h[12..20].try_into().unwrap())
}

/// 4 emoji khoá: SHA256(key ‖ g_a của bên gọi) cắt 4 số 64 bit big-endian (bỏ bit cao), mỗi số mod 333 → bảng EMOJI
/// (như ComputeEmojiFingerprint của Telegram Desktop).
pub fn emoji_fingerprint(key: &[u8; 256], g_a: &[u8]) -> [&'static str; 4] {
    let mut h = Sha256::new();
    h.update(key);
    h.update(g_a);
    let d = h.finalize();
    let mut out = [""; 4];
    for (i, e) in out.iter_mut().enumerate() {
        let v = u64::from_be_bytes(d[i * 8..i * 8 + 8].try_into().unwrap()) & 0x7fff_ffff_ffff_ffff;
        *e = EMOJI[(v % EMOJI.len() as u64) as usize];
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prime_constant_is_safe_prime() {
        let p = BigUint::parse_bytes(TG_PRIME_HEX.as_bytes(), 16).unwrap();
        assert_eq!(p.bits(), 2048);
        assert!(probably_prime(&p, 8));
        assert!(probably_prime(&((&p - big(1)) >> 1u32), 8));
    }

    #[test]
    fn both_sides_agree() {
        let p = BigUint::parse_bytes(TG_PRIME_HEX.as_bytes(), 16).unwrap().to_bytes_be();
        let cfg = DhConfig::new(&p, 3).unwrap();
        let a = KeyPair::new(&cfg, &[]).unwrap();
        let b = KeyPair::new(&cfg, &[]).unwrap();
        let ka = a.shared_key(&cfg, &b.g_a).unwrap();
        let kb = b.shared_key(&cfg, &a.g_a).unwrap();
        assert_eq!(ka, kb);
        assert_eq!(key_fingerprint(&ka), key_fingerprint(&kb));
        assert_eq!(emoji_fingerprint(&ka, &a.g_a), emoji_fingerprint(&kb, &a.g_a));
        assert_eq!(EMOJI.len(), 333);
    }
}
