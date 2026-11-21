//! Âm thanh cuộc gọi: Opus 48 kHz đơn kênh, khung 20 ms (gm-opus — libopus đã dựng cho iOS 5 / 6). Thu / phát do bên dùng lo
//! (gm-cli: tệp WAV; app iOS: AudioUnit VoiceProcessingIO): bên thu mã khung rồi đẩy vào kênh `frames` của engine, bên phát lấy
//! khung từ `Shared::jitter` mỗi 20 ms rồi giải mã.
//! Cấu trúc `Shared` theo Ferrogram (src/net/calls/audio.rs, MIT — LICENSE-FERROGRAM).

use std::sync::atomic::{AtomicBool, AtomicU32};
use std::sync::{Arc, Mutex};

use super::jitter::{Frame, JitterBuffer};

pub const RATE: u32 = 48_000;
pub const FRAME: usize = 960; // 20 ms
/// Khung Opus dài nhất (120 ms) — app Telegram gửi khung 60 ms (gọi thử 21/11/2026: 17 gói / giây).
pub const MAX_FRAME: usize = 5760;

/// Trạng thái dùng chung giữa engine mạng và bên thu / phát.
#[derive(Debug, Default)]
pub struct Shared {
    pub jitter: Mutex<JitterBuffer>,
    pub muted: AtomicBool,
    /// Đỉnh của khung vừa thu (0..=32767) — vạch mức micro.
    pub mic_level: AtomicU32,
}

impl Shared {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }
}

/// Độ phức tạp bộ mã cho cuộc gọi. Đo `gm-cli opusbench` (21/11/2026, libopus số nguyên trên ARM), % một nhân khi mã:
/// iPad 1 (A4) 22,6 / 13,8 / 6,5 ở mức 10 / 5 / 2; iPhone 5 (A6) 9,3 / 5,8 / 2,9. Giải luồng app Telegram: 2,2 / 1,0.
/// Engine (mạng + SRTP + vòng lặp) ~3%. Mức 5: cả cuộc gọi ~19% trên A4, ~8% trên A6.
pub const DEFAULT_COMPLEXITY: i32 = 5;
/// Băng thông âm thanh tối đa của tiếng mình gửi (Hz). Toàn dải (Hybrid, như app Telegram) chỉ tốn hơn băng rộng (8000 —
/// chỉ SILK) ~1,7 điểm trên A4.
pub const DEFAULT_BANDWIDTH: u32 = 20_000;

pub struct OpusEncoder(gm_opus::Encoder);

impl OpusEncoder {
    pub fn new() -> Option<Self> {
        Self::with_settings(DEFAULT_COMPLEXITY, DEFAULT_BANDWIDTH)
    }

    /// Độ phức tạp 0..=10 + băng thông tối đa (Hz) — gm-cli callselftest đo CPU từng tổ hợp trên máy thật. Luôn báo «tiếng
    /// nói» để Opus không tự chuyển CELT (tải CPU ổn định, đúng chế độ của app Telegram).
    pub fn with_settings(complexity: i32, max_bandwidth: u32) -> Option<Self> {
        let mut e = gm_opus::Encoder::new(RATE as i32, 32_000).ok()?;
        e.set_complexity(complexity);
        e.set_signal_voice();
        e.set_max_bandwidth(max_bandwidth);
        Some(Self(e))
    }

    pub fn encode(&mut self, pcm: &[i16]) -> Option<Vec<u8>> {
        if pcm.len() != FRAME {
            return None;
        }
        self.0.encode(pcm).ok()
    }
}

pub struct OpusDecoder {
    dec: gm_opus::Decoder,
    /// Độ dài khung gần nhất (mẫu) — bù gói mất cùng độ dài.
    last: usize,
    /// Gỡ lỗi: số gói giải lỗi / số gói giải được / số ô mất / số ô im lặng.
    pub errors: u64,
    pub packets: u64,
    pub lost: u64,
    pub silence: u64,
}

impl OpusDecoder {
    pub fn new() -> Option<Self> {
        gm_opus::Decoder::new(RATE as i32, 1)
            .ok()
            .map(|dec| Self { dec, last: FRAME, errors: 0, packets: 0, lost: 0, silence: 0 })
    }

    /// Giải một ô của bộ đệm chống rung. Độ dài thay đổi theo khung bên kia gửi (20 / 40 / 60 ms…) — bên phát tự cắt theo nhịp
    /// của mình. Mất gói → libopus bù (cùng độ dài khung trước); im lặng → một khung 20 ms toàn 0.
    pub fn decode(&mut self, frame: &Frame) -> Vec<i16> {
        let mut out = vec![0i16; MAX_FRAME];
        let n = match frame {
            Frame::Packet(p) => {
                let r = self.dec.decode(p, &mut out).ok();
                if r.is_some() { self.packets += 1 } else { self.errors += 1 }
                r
            }
            Frame::Lost { .. } => {
                self.lost += 1;
                self.dec.decode(&[], &mut out[..self.last]).ok()
            }
            Frame::Silence => {
                self.silence += 1;
                return vec![0; FRAME];
            }
        };
        match n {
            Some(n) if n > 0 => {
                if matches!(frame, Frame::Packet(_)) {
                    self.last = n.min(MAX_FRAME);
                }
                out.truncate(n);
                out
            }
            _ => vec![0; FRAME],
        }
    }
}
