//! Giải mã video H.265 (HEVC) để iOS 5 / 6 phát được hình: iPhone / iPad đời cũ chỉ giải H.264 bằng phần cứng, video quay bằng
//! máy mới (H.265) phát lên chỉ có tiếng. Đọc rãnh video trong MP4 (`mp4`), giải mã bằng FFmpeg (bộ giải HEVC, NEON trên armv7,
//! giải song song theo khung), thu nhỏ ra NV12 dải video (cạnh ngắn ≤ `max_short`) để app mã lại H.264 bằng phần cứng
//! (AVAssetWriter) — xem app/Core/GMHevcTranscoder.m.
mod mp4;

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::os::raw::{c_int, c_void};
use std::path::Path;

pub use mp4::{Sample, Track};

#[repr(C)]
struct RawFrame {
    planes: [*const u8; 3],
    stride: [c_int; 3],
    w: c_int,
    h: c_int,
    bits: c_int,
    full_range: c_int,
    pts: i64,
}

impl RawFrame {
    fn empty() -> Self {
        RawFrame { planes: [std::ptr::null(); 3], stride: [0; 3], w: 0, h: 0, bits: 0, full_range: 0, pts: 0 }
    }
}

#[cfg(not(gm_hevc_stub))]
unsafe extern "C" {
    fn gm_hevc_open(extra: *const u8, len: c_int, threads: c_int, skip_nonref: c_int) -> *mut c_void;
    fn gm_hevc_send(ctx: *mut c_void, data: *const u8, len: c_int, pts: i64, dts: i64) -> c_int;
    fn gm_hevc_receive(ctx: *mut c_void, f: *mut RawFrame) -> c_int;
    fn gm_hevc_close(ctx: *mut c_void);
}

// MSVC (dựng thử trên Windows): không có FFmpeg — mở video báo lỗi
#[cfg(gm_hevc_stub)]
unsafe fn gm_hevc_open(_: *const u8, _: c_int, _: c_int, _: c_int) -> *mut c_void {
    std::ptr::null_mut()
}
#[cfg(gm_hevc_stub)]
unsafe fn gm_hevc_send(_: *mut c_void, _: *const u8, _: c_int, _: i64, _: i64) -> c_int {
    -1
}
#[cfg(gm_hevc_stub)]
unsafe fn gm_hevc_receive(_: *mut c_void, _: *mut RawFrame) -> c_int {
    -1
}
#[cfg(gm_hevc_stub)]
unsafe fn gm_hevc_close(_: *mut c_void) {}

/// Thông tin video (kích thước trước khi xoay).
#[derive(Clone, Copy, Debug)]
pub struct Info {
    pub width: u32,
    pub height: u32,
    /// Cỡ khung ra (NV12) sau khi thu nhỏ — chẵn.
    pub out_width: u32,
    pub out_height: u32,
    pub frames: u32,
    pub timescale: u32,
    pub duration: i64,
    /// Ma trận xoay (a, b, c, d) của rãnh — app đặt lại cho tệp H.264 (video dọc).
    pub matrix: [f64; 4],
}

/// Video H.265 đang giải. Dùng ở một luồng một lúc (luồng giải song song nằm trong FFmpeg).
pub struct Video {
    file: File,
    track: Track,
    dec: *mut c_void,
    next: usize,
    flushed: bool,
    bad: u32,
    buf: Vec<u8>,
    out_w: u32,
    out_h: u32,
    first_pts: Option<i64>,
}

// Con trỏ bộ giải chỉ dùng qua &mut self
unsafe impl Send for Video {}

impl Drop for Video {
    fn drop(&mut self) {
        unsafe { gm_hevc_close(self.dec) };
    }
}

/// Cỡ ra: giữ tỉ lệ, cạnh ngắn ≤ `max_short` (không phóng to), chẵn, ≥ 16.
pub fn out_size(w: u32, h: u32, max_short: u32) -> (u32, u32) {
    let short = w.min(h).max(1);
    let k = (max_short as f64 / short as f64).min(1.0);
    let even = |x: f64| ((x / 2.0).round() as u32 * 2).max(16);
    (even(w as f64 * k), even(h as f64 * k))
}

impl Video {
    /// Mở tệp MP4 / MOV có video H.265. `max_short`: cạnh ngắn tối đa của khung ra (480 cho máy cũ). `fast`: bỏ khung không làm
    /// tham chiếu (máy một nhân — ít khung / giây hơn, không nhoè).
    pub fn open(path: &Path, max_short: u32, fast: bool) -> Result<Video, String> {
        let mut file = File::open(path).map_err(|e| format!("Không mở được tệp: {e}"))?;
        let track = mp4::video_track(&mut file)?;
        if track.samples.is_empty() {
            return Err("video không có khung nào".into());
        }
        let threads = std::thread::available_parallelism().map(|n| n.get().min(4)).unwrap_or(1) as c_int;
        let dec = unsafe { gm_hevc_open(track.hvcc.as_ptr(), track.hvcc.len() as c_int, threads, fast as c_int) };
        if dec.is_null() {
            return Err("Không mở được bộ giải mã H.265".into());
        }
        let (out_w, out_h) = out_size(track.width, track.height, max_short);
        Ok(Video { file, track, dec, next: 0, flushed: false, bad: 0, buf: Vec::new(), out_w, out_h, first_pts: None })
    }

    pub fn info(&self) -> Info {
        let t = &self.track;
        Info {
            width: t.width,
            height: t.height,
            out_width: self.out_w,
            out_height: self.out_h,
            frames: t.samples.len() as u32,
            timescale: t.timescale,
            duration: t.duration,
            matrix: t.matrix,
        }
    }

    /// Giải khung kế tiếp (thứ tự trình chiếu), thu nhỏ vào NV12: mặt phẳng Y `out_width × out_height` (`y_stride` byte một
    /// dòng) và UV xen kẽ `out_width × out_height / 2` (`uv_stride`). Trả Ok(Some(pts — theo `timescale`, khung đầu = 0)),
    /// Ok(None) khi hết.
    pub fn next(&mut self, y: &mut [u8], y_stride: usize, uv: &mut [u8], uv_stride: usize) -> Result<Option<i64>, String> {
        let (ow, oh) = (self.out_w as usize, self.out_h as usize);
        if y_stride < ow || uv_stride < ow || y.len() < y_stride * (oh - 1) + ow || uv.len() < uv_stride * (oh / 2 - 1) + ow {
            return Err("vùng nhớ khung ra quá nhỏ".into());
        }
        loop {
            let mut f = RawFrame::empty();
            match unsafe { gm_hevc_receive(self.dec, &mut f) } {
                0 => {
                    convert(&f, y, y_stride, uv, uv_stride, ow, oh)?;
                    let first = *self.first_pts.get_or_insert(f.pts);
                    return Ok(Some(f.pts - first));
                }
                2 => return Ok(None),
                1 => {}
                -2 => return Err("dạng điểm ảnh chưa hỗ trợ (chỉ YUV 4:2:0)".into()),
                _ => return Err("giải mã H.265 lỗi".into()),
            }
            if let Some(&s) = self.track.samples.get(self.next) {
                self.next += 1;
                if s.size == 0 || s.size > mp4::MAX_SAMPLE {
                    continue;
                }
                self.buf.resize(s.size as usize, 0);
                self.file.seek(SeekFrom::Start(s.offset)).map_err(|e| e.to_string())?;
                self.file.read_exact(&mut self.buf).map_err(|e| format!("Đọc tệp lỗi: {e}"))?;
                // Gói hỏng: bỏ qua (tối đa 50 gói), giải tiếp như FFmpeg
                if unsafe { gm_hevc_send(self.dec, self.buf.as_ptr(), self.buf.len() as c_int, s.pts, s.dts) } < 0 {
                    self.bad += 1;
                    if self.bad > 50 {
                        return Err("video hỏng quá nhiều".into());
                    }
                }
            } else if !self.flushed {
                self.flushed = true;
                unsafe { gm_hevc_send(self.dec, std::ptr::null(), 0, 0, 0) };
            } else {
                return Ok(None);
            }
        }
    }
}

/// Mẫu thứ `x` của một dòng (8 bit, hoặc > 8 bit 2 byte little-endian → 8 bit).
#[inline]
fn px(row: &[u8], x: usize, wide: bool, shift: u32) -> u32 {
    if wide {
        let v = u16::from_le_bytes([row.get(x * 2).copied().unwrap_or(0), row.get(x * 2 + 1).copied().unwrap_or(0)]) as u32;
        ((v + ((1 << shift) >> 1)) >> shift).min(255)
    } else {
        row.get(x).copied().unwrap_or(0) as u32
    }
}

fn row(p: &[u8], stride: usize, r: usize) -> &[u8] {
    p.get(r * stride..).unwrap_or(&[])
}

/// Bảng ánh xạ cột / dòng ra → (chỉ số trái, chỉ số phải, trọng số 0–256) cho thu nhỏ song tuyến.
fn taps(src: usize, dst: usize) -> Vec<(usize, usize, u32)> {
    (0..dst)
        .map(|d| {
            let s = ((d as f64 + 0.5) * src as f64 / dst as f64 - 0.5).max(0.0);
            let i = (s as usize).min(src - 1);
            (i, (i + 1).min(src - 1), ((s - i as f64) * 256.0) as u32)
        })
        .collect()
}

/// Khung YUV 4:2:0 của FFmpeg → NV12 dải video, thu nhỏ song tuyến.
fn convert(f: &RawFrame, y: &mut [u8], ys: usize, uv: &mut [u8], uvs: usize, ow: usize, oh: usize) -> Result<(), String> {
    let (w, h) = (f.w.max(0) as usize, f.h.max(0) as usize);
    if w < 2 || h < 2 || f.planes.iter().any(|p| p.is_null()) || f.stride.iter().any(|s| *s <= 0) {
        return Err("khung giải ra không hợp lệ".into());
    }
    let wide = f.bits > 8;
    let shift = (f.bits.clamp(8, 16) - 8) as u32;
    let bpp = if wide { 2 } else { 1 };
    let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
    // Dải đầy → dải video (16–235 / 16–240)
    let luma = |v: u32| if f.full_range != 0 { (16 + v * 219 / 255) as u8 } else { v as u8 };
    let chroma = |v: u32| if f.full_range != 0 { (128 + (v as i32 - 128) * 224 / 255) as u8 } else { v as u8 };
    // Mặt phẳng của FFmpeg: dòng cuối không cần đủ `stride` byte
    let plane = |i: usize, rows: usize, cols: usize| unsafe {
        std::slice::from_raw_parts(f.planes[i], f.stride[i] as usize * (rows - 1) + cols * bpp)
    };
    let (py, pu, pv) = (plane(0, h, w), plane(1, ch, cw), plane(2, ch, cw));
    let (sy, sc) = (f.stride[0] as usize, f.stride[1] as usize);
    let sv = f.stride[2] as usize;
    let (tx, ty) = (taps(w, ow), taps(h, oh));
    for (oy, &(y0, y1, fy)) in ty.iter().enumerate() {
        let (r0, r1) = (row(py, sy, y0), row(py, sy, y1));
        let Some(out) = y.get_mut(oy * ys..oy * ys + ow) else { return Err("vùng nhớ khung ra quá nhỏ".into()) };
        for (o, &(x0, x1, fx)) in out.iter_mut().zip(tx.iter()) {
            let a = px(r0, x0, wide, shift) * (256 - fx) + px(r0, x1, wide, shift) * fx;
            let b = px(r1, x0, wide, shift) * (256 - fx) + px(r1, x1, wide, shift) * fx;
            *o = luma((a * (256 - fy) + b * fy + 32768) >> 16);
        }
    }
    let (cow, coh) = (ow / 2, oh / 2);
    let (cx, cy) = (taps(cw, cow), taps(ch, coh));
    for (oy, &(y0, y1, fy)) in cy.iter().enumerate() {
        let (u0, u1, v0, v1) = (row(pu, sc, y0), row(pu, sc, y1), row(pv, sv, y0), row(pv, sv, y1));
        let Some(out) = uv.get_mut(oy * uvs..oy * uvs + cow * 2) else { return Err("vùng nhớ khung ra quá nhỏ".into()) };
        for (o, &(x0, x1, fx)) in out.chunks_exact_mut(2).zip(cx.iter()) {
            let mix = |r0: &[u8], r1: &[u8]| {
                let a = px(r0, x0, wide, shift) * (256 - fx) + px(r0, x1, wide, shift) * fx;
                let b = px(r1, x0, wide, shift) * (256 - fx) + px(r1, x1, wide, shift) * fx;
                (a * (256 - fy) + b * fy + 32768) >> 16
            };
            o[0] = chroma(mix(u0, u1));
            o[1] = chroma(mix(v0, v1));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sizes() {
        assert_eq!(out_size(1920, 1080, 480), (854, 480));
        assert_eq!(out_size(1080, 1920, 480), (480, 854));
        assert_eq!(out_size(640, 360, 480), (640, 360));
    }

    #[test]
    fn converts_gray() {
        // khung 8 × 4 xám 100, dải đầy → video
        let yp = vec![100u8; 8 * 4];
        let cp = vec![128u8; 4 * 2];
        let f = RawFrame { planes: [yp.as_ptr(), cp.as_ptr(), cp.as_ptr()], stride: [8, 4, 4], w: 8, h: 4, bits: 8, full_range: 1, pts: 0 };
        let (mut y, mut uv) = (vec![0u8; 4 * 2], vec![0u8; 4]);
        convert(&f, &mut y, 4, &mut uv, 4, 4, 2).unwrap();
        assert!(y.iter().all(|&v| v == (16 + 100 * 219 / 255) as u8));
        assert!(uv.iter().all(|&v| v == 128));
    }
}
