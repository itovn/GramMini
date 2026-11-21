//! Cầu âm thanh giữa máy (iOS: AudioUnit VoiceProcessingIO, 48 kHz đơn kênh 16 bit — khử vọng / tự chỉnh mức do iOS lo) và
//! engine (GramMini).
//!
//! Callback của AudioUnit chạy trên luồng thời gian thực: chỉ chép mẫu vào / ra hai bộ đệm vòng ([`VoipIo::push`] /
//! [`VoipIo::pull`], `try_lock` — bận thì bỏ một lượt chứ không chờ). Một luồng riêng mỗi 10 ms: cắt tiếng micro thành khung
//! 20 ms → mã Opus → gửi engine; lấy khung từ bộ đệm chống rung → giải → đổ vào bộ đệm loa (giữ ~40 ms phía trước).
//!
//! Chỉ có một cuộc gọi một lúc: [`install`] đặt cầu hiện hành cho lớp FFI (`gm_voip_push` / `gm_voip_pull` của gm-ffi).

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering::Relaxed};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::mpsc;

use super::audio::{FRAME, OpusDecoder, OpusEncoder, Shared};
use super::jitter::Frame;

/// Micro: giữ tối đa 200 ms chưa mã (luồng mã bị trễ thì bỏ phần cũ).
const MIC_MAX: usize = FRAME * 10;
/// Loa: luồng giải giữ trước ~40 ms; tối đa 300 ms (bên kia gửi dồn).
const SPK_TARGET: usize = FRAME * 2;
const SPK_MAX: usize = FRAME * 15;

pub struct VoipIo {
    mic: Mutex<VecDeque<i16>>,
    spk: Mutex<VecDeque<i16>>,
    stop: AtomicBool,
    muted: AtomicBool,
    /// Đỉnh khung micro vừa mã (0..=32767) — vạch mức / kiểm micro có tiếng.
    pub mic_level: AtomicU32,
    /// Gỡ lỗi: số lượt callback bỏ qua vì bộ đệm đang bận; số mẫu loa phải bù im lặng vì hết tiếng.
    pub skipped: AtomicU32,
    pub underrun: AtomicU32,
}

static CURRENT: Mutex<Option<Arc<VoipIo>>> = Mutex::new(None);

/// Đặt / bỏ cầu âm thanh hiện hành (lớp FFI đọc).
pub fn install(io: Option<Arc<VoipIo>>) {
    if let Ok(mut c) = CURRENT.lock() {
        *c = io;
    }
}

/// Cầu hiện hành (nếu đang có cuộc gọi). `try_lock`: gọi từ luồng thời gian thực.
pub fn current() -> Option<Arc<VoipIo>> {
    CURRENT.try_lock().ok().and_then(|c| c.clone())
}

impl VoipIo {
    /// Mở cầu cho một cuộc gọi: luồng mã / giải chạy tới khi [`VoipIo::stop`] (hoặc engine đóng kênh `frames`).
    pub fn start(shared: Arc<Shared>, frames: mpsc::Sender<Vec<u8>>) -> Option<Arc<Self>> {
        let mut enc = OpusEncoder::new()?;
        let mut dec = OpusDecoder::new()?;
        let io = Arc::new(Self {
            mic: Mutex::new(VecDeque::with_capacity(MIC_MAX)),
            spk: Mutex::new(VecDeque::with_capacity(SPK_MAX)),
            stop: AtomicBool::new(false),
            muted: AtomicBool::new(false),
            mic_level: AtomicU32::new(0),
            skipped: AtomicU32::new(0),
            underrun: AtomicU32::new(0),
        });
        let w = Arc::clone(&io);
        std::thread::Builder::new()
            .name("gm-voip".into())
            .spawn(move || {
                let mut frame = vec![0i16; FRAME];
                while !w.stop.load(Relaxed) {
                    // Micro → Opus → engine
                    loop {
                        let got = match w.mic.lock() {
                            Ok(mut m) if m.len() >= FRAME => {
                                for (d, s) in frame.iter_mut().zip(m.drain(..FRAME)) {
                                    *d = s;
                                }
                                true
                            }
                            _ => false,
                        };
                        if !got {
                            break;
                        }
                        let peak = frame.iter().map(|s| u32::from(s.unsigned_abs())).max().unwrap_or(0);
                        w.mic_level.store(peak, Relaxed);
                        if w.muted.load(Relaxed) {
                            continue;
                        }
                        if let Some(p) = enc.encode(&frame) {
                            if let Err(mpsc::error::TrySendError::Closed(_)) = frames.try_send(p) {
                                return;
                            }
                        }
                    }
                    // Bộ đệm chống rung → giải → loa (khung bên kia dài 20 / 40 / 60 ms)
                    loop {
                        let have = w.spk.lock().map(|s| s.len()).unwrap_or(SPK_MAX);
                        if have >= SPK_TARGET {
                            break;
                        }
                        let Some(f) = shared.jitter.lock().ok().map(|mut j| j.pop()) else { break };
                        let silent = matches!(f, Frame::Silence);
                        let pcm = dec.decode(&f);
                        if let Ok(mut s) = w.spk.lock() {
                            s.extend(pcm);
                            let over = s.len().saturating_sub(SPK_MAX);
                            s.drain(..over);
                        }
                        if silent {
                            break;
                        }
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
            })
            .ok()?;
        Some(io)
    }

    /// Callback micro (luồng thời gian thực): thêm mẫu 48 kHz.
    pub fn push(&self, pcm: &[i16]) {
        match self.mic.try_lock() {
            Ok(mut m) => {
                m.extend(pcm.iter().copied());
                let over = m.len().saturating_sub(MIC_MAX);
                m.drain(..over);
            }
            Err(_) => {
                self.skipped.fetch_add(1, Relaxed);
            }
        }
    }

    /// Callback loa (luồng thời gian thực): lấy đủ `out.len()` mẫu; thiếu thì bù im lặng. Trả số mẫu có tiếng thật.
    pub fn pull(&self, out: &mut [i16]) -> usize {
        let n = match self.spk.try_lock() {
            Ok(mut s) => {
                let n = s.len().min(out.len());
                for (d, v) in out.iter_mut().zip(s.drain(..n)) {
                    *d = v;
                }
                n
            }
            Err(_) => {
                self.skipped.fetch_add(1, Relaxed);
                0
            }
        };
        if n < out.len() {
            out[n..].fill(0);
            self.underrun.fetch_add((out.len() - n) as u32, Relaxed);
        }
        n
    }

    pub fn set_muted(&self, on: bool) {
        self.muted.store(on, Relaxed);
    }

    pub fn is_muted(&self) -> bool {
        self.muted.load(Relaxed)
    }

    pub fn stop(&self) {
        self.stop.store(true, Relaxed);
    }
}

impl Drop for VoipIo {
    fn drop(&mut self) {
        self.stop.store(true, Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Tiếng micro đẩy vào thành gói Opus gửi engine; gói đưa vào bộ đệm chống rung ra loa.
    #[test]
    fn pumps_mic_to_engine_and_jitter_to_speaker() {
        let shared = Shared::new();
        let (tx, mut rx) = mpsc::channel(64);
        let io = VoipIo::start(shared.clone(), tx).unwrap();
        let tone: Vec<i16> = (0..FRAME * 5).map(|i| ((i as f32 * 0.07).sin() * 8000.0) as i16).collect();
        io.push(&tone);
        let mut pkts = Vec::new();
        for _ in 0..100 {
            while let Ok(p) = rx.try_recv() {
                pkts.push(p);
            }
            if pkts.len() >= 5 {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(pkts.len(), 5);
        for (i, p) in pkts.iter().enumerate() {
            shared.jitter.lock().unwrap().push(100 + i as u16, p.clone());
        }
        let mut out = vec![0i16; FRAME];
        let mut loud = 0;
        for _ in 0..100 {
            std::thread::sleep(Duration::from_millis(10));
            if io.pull(&mut out) > 0 && out.iter().any(|s| s.unsigned_abs() > 1000) {
                loud += 1;
            }
            if loud >= 2 {
                break;
            }
        }
        assert!(loud >= 2, "loa không có tiếng");
        assert!(io.mic_level.load(Relaxed) > 1000);
        io.stop();
    }
}
