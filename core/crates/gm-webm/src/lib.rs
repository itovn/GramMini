//! Sticker video Telegram: tệp WebM, hình VP9, kênh trong suốt là một luồng VP9 thứ hai trong BlockAdditional (AlphaMode 1)
//! — như ffmpeg / Telegram ghi. Đọc WebM (EBML) bằng Rust, giải mã VP9 bằng libvpx (C, qua csrc/gm_vpx.c), đổi YUV + alpha
//! sang RGBA đã nhân alpha ở cỡ đích (thu nhỏ song tuyến, giữ tỉ lệ, căn giữa) — cùng kiểu đầu ra với gm-lottie.
//!
//! Giải mã tuần tự: `render(i)` sau `render(i - 1)` chỉ giải một khung; lùi lại thì giải lại từ khung khoá gần nhất.
//! Không panic (bản phát hành dựng `panic = abort`): mọi chỗ đọc đều kiểm giới hạn.

use std::ffi::c_void;
use std::ops::Range;
use std::os::raw::c_int;

#[repr(C)]
struct VpxFrame {
    planes: [*const u8; 3],
    stride: [c_int; 3],
    w: c_int,
    h: c_int,
    x_chroma_shift: c_int,
    y_chroma_shift: c_int,
    full_range: c_int,
    bt709: c_int,
}

impl Default for VpxFrame {
    fn default() -> Self {
        VpxFrame {
            planes: [std::ptr::null(); 3],
            stride: [0; 3],
            w: 0,
            h: 0,
            x_chroma_shift: 0,
            y_chroma_shift: 0,
            full_range: 0,
            bt709: 0,
        }
    }
}

extern "C" {
    fn gm_vpx_open() -> *mut c_void;
    fn gm_vpx_decode(ctx: *mut c_void, data: *const u8, len: usize, out: *mut VpxFrame) -> c_int;
    fn gm_vpx_close(ctx: *mut c_void);
}

/// Tệp lớn hơn thế này không phải sticker (Telegram giới hạn 256 KB) — bỏ, khỏi tốn bộ nhớ.
const MAX_FILE: usize = 4 << 20;
const MAX_FRAMES: usize = 2000;
/// Cỡ khung tối đa (libvpx cũng dựng với giới hạn này — vendor/libvpx/gm-config/vpx_config.h).
const MAX_DIM: u64 = 1024;

struct Decoder(*mut c_void);

impl Decoder {
    fn new() -> Option<Decoder> {
        // libvpx dựng không đa luồng: lần khởi tạo đầu ghi bảng hàm dùng chung không khoá → tạo bộ giải mã lần lượt
        static OPEN: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _g = OPEN.lock().unwrap_or_else(|e| e.into_inner());
        let p = unsafe { gm_vpx_open() };
        (!p.is_null()).then_some(Decoder(p))
    }

    /// Ok(true) = có khung (out điền), Ok(false) = không có khung hiện.
    fn decode(&mut self, data: &[u8], out: &mut VpxFrame) -> Result<bool, ()> {
        match unsafe { gm_vpx_decode(self.0, data.as_ptr(), data.len(), out) } {
            0 => Ok(true),
            1 => Ok(false),
            _ => Err(()),
        }
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        unsafe { gm_vpx_close(self.0) }
    }
}

// Con trỏ libvpx chỉ dùng trên một luồng tại một thời điểm (app gọi từ một hàng đợi nối tiếp)
unsafe impl Send for Decoder {}

#[derive(Clone, Debug)]
struct Frame {
    color: Range<usize>,
    alpha: Option<Range<usize>>,
    key: bool,
}

/// Một sticker video đã mở.
pub struct Video {
    data: Vec<u8>,
    frames: Vec<Frame>,
    width: u32,
    height: u32,
    fps: f64,
    color: Option<Decoder>,
    alpha: Option<Decoder>,
    /// Khung kế tiếp sẽ giải (0 = chưa giải khung nào).
    next: usize,
}

impl Video {
    /// Đọc tệp WebM (VP9). None nếu không phải WebM / không có luồng VP9 / quá lớn.
    pub fn parse(data: Vec<u8>) -> Option<Video> {
        if data.len() > MAX_FILE {
            return None;
        }
        let p = parse_webm(&data)?;
        if p.frames.is_empty() || p.width == 0 || p.height == 0 || p.width > MAX_DIM || p.height > MAX_DIM {
            return None;
        }
        Some(Video {
            frames: p.frames,
            width: p.width as u32,
            height: p.height as u32,
            fps: p.fps,
            data,
            color: None,
            alpha: None,
            next: 0,
        })
    }

    pub fn frame_count(&self) -> usize {
        self.frames.len()
    }

    pub fn frame_rate(&self) -> f64 {
        self.fps
    }

    pub fn size(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    /// Có kênh trong suốt không.
    pub fn has_alpha(&self) -> bool {
        self.frames.iter().any(|f| f.alpha.is_some())
    }

    /// Vẽ khung `frame` vào `buf` (RGBA đã nhân alpha, `w * h * 4` byte, hàng liền nhau): hình thu vừa khung, giữ tỉ lệ,
    /// căn giữa, phần thừa trong suốt. false nếu không giải mã được (giữ khung cũ trên màn).
    pub fn render(&mut self, frame: usize, buf: &mut [u8], w: usize, h: usize) -> bool {
        if frame >= self.frames.len() || w == 0 || h == 0 || buf.len() < w * h * 4 {
            return false;
        }
        // Điểm bắt đầu: khung kế tiếp nếu đang đi tới; lùi lại (hoặc có khung khoá gần hơn) thì từ khung khoá gần nhất ≤ frame
        let key = self.frames[..=frame].iter().rposition(|f| f.key).unwrap_or(0);
        let restart = self.color.is_none() || frame < self.next || key > self.next;
        let start = if restart { key } else { self.next };
        if restart {
            // Bắt đầu lại từ khung khoá: bộ giải mã mới (khỏi lệ thuộc trạng thái cũ)
            self.color = Decoder::new();
            self.alpha = if self.has_alpha() { Decoder::new() } else { None };
            if self.color.is_none() {
                return false;
            }
        }
        let mut cf = VpxFrame::default();
        let mut af = VpxFrame::default();
        let (mut got_c, mut got_a) = (false, false);
        for i in start..=frame {
            let Some(f) = self.frames.get(i).cloned() else { return false };
            let Some(cd) = self.color.as_mut() else { return false };
            let Some(cdata) = self.data.get(f.color.clone()) else { return false };
            match cd.decode(cdata, &mut cf) {
                Ok(g) => got_c = g,
                Err(()) => {
                    self.color = None;  // lỗi giữa chừng: lần sau bắt đầu lại từ khung khoá
                    return false;
                }
            }
            got_a = false;
            if let (Some(ad), Some(r)) = (self.alpha.as_mut(), f.alpha.as_ref()) {
                if let Some(adata) = self.data.get(r.clone()) {
                    got_a = matches!(ad.decode(adata, &mut af), Ok(true));
                }
            }
            self.next = i + 1;
        }
        if !got_c {
            return false;
        }
        convert(&cf, got_a.then_some(&af), buf, w, h)
    }
}

/// Mặt phẳng ảnh (đọc từ con trỏ libvpx, đã kiểm cỡ).
struct Plane<'a> {
    data: &'a [u8],
    stride: usize,
    w: usize,
    h: usize,
}

impl<'a> Plane<'a> {
    fn new(p: *const u8, stride: c_int, w: usize, h: usize) -> Option<Plane<'a>> {
        if p.is_null() || stride <= 0 || (stride as usize) < w || w == 0 || h == 0 {
            return None;
        }
        let stride = stride as usize;
        let len = stride * (h - 1) + w;
        Some(Plane { data: unsafe { std::slice::from_raw_parts(p, len) }, stride, w, h })
    }

    /// Lấy mẫu song tuyến ở toạ độ 16.16 (đã kẹp trong ảnh).
    #[inline(always)]
    fn bilerp(&self, fx: u32, fy: u32) -> u32 {
        let x0 = ((fx >> 16) as usize).min(self.w - 1);
        let y0 = ((fy >> 16) as usize).min(self.h - 1);
        let x1 = (x0 + 1).min(self.w - 1);
        let y1 = (y0 + 1).min(self.h - 1);
        let wx = (fx >> 8) & 0xff;
        let wy = (fy >> 8) & 0xff;
        let r0 = y0 * self.stride;
        let r1 = y1 * self.stride;
        let d = self.data;
        let (a, b, c, e) = (d[r0 + x0] as u32, d[r0 + x1] as u32, d[r1 + x0] as u32, d[r1 + x1] as u32);
        let top = a * (256 - wx) + b * wx;
        let bot = c * (256 - wx) + e * wx;
        (top * (256 - wy) + bot * wy + (1 << 15)) >> 16
    }

    #[inline(always)]
    fn at(&self, x: usize, y: usize) -> u32 {
        self.data[y.min(self.h - 1) * self.stride + x.min(self.w - 1)] as u32
    }
}

/// YUV (+ alpha từ mặt Y của luồng thứ hai) → RGBA đã nhân alpha, thu vừa w × h.
fn convert(c: &VpxFrame, a: Option<&VpxFrame>, buf: &mut [u8], w: usize, h: usize) -> bool {
    let (sw, sh) = (c.w.max(0) as usize, c.h.max(0) as usize);
    let (xs, ys) = (c.x_chroma_shift.clamp(0, 1) as usize, c.y_chroma_shift.clamp(0, 1) as usize);
    let cw = (sw + xs) >> xs;
    let ch = (sh + ys) >> ys;
    let (Some(yp), Some(up), Some(vp)) = (
        Plane::new(c.planes[0], c.stride[0], sw, sh),
        Plane::new(c.planes[1], c.stride[1], cw, ch),
        Plane::new(c.planes[2], c.stride[2], cw, ch),
    ) else {
        return false;
    };
    // Luồng alpha cùng cỡ thì dùng; lệch cỡ thì coi như đục
    let ap = a.and_then(|a| if a.w == c.w && a.h == c.h { Plane::new(a.planes[0], a.stride[0], sw, sh) } else { None });
    // Hệ số đổi màu ×256: (kY, kRV, kGU, kGV, kBU)
    let (ky, krv, kgu, kgv, kbu, yoff) = match (c.full_range != 0, c.bt709 != 0) {
        (false, false) => (298, 409, 100, 208, 516, 16),
        (false, true) => (298, 459, 55, 136, 541, 16),
        (true, false) => (256, 359, 88, 183, 454, 0),
        (true, true) => (256, 403, 48, 120, 475, 0),
    };
    let out = &mut buf[..w * h * 4];
    out.fill(0);
    // Giữ tỉ lệ: vùng vẽ dw × dh căn giữa
    let scale = (w as f64 / sw as f64).min(h as f64 / sh as f64);
    let dw = ((sw as f64 * scale).round() as usize).clamp(1, w);
    let dh = ((sh as f64 * scale).round() as usize).clamp(1, h);
    let (ox, oy) = ((w - dw) / 2, (h - dh) / 2);
    let xstep = ((sw as u64) << 16) / dw as u64;
    let ystep = ((sh as u64) << 16) / dh as u64;
    let clamp = |v: i32| v.clamp(0, 255) as u32;
    for dy in 0..dh {
        // Tâm điểm đích chiếu về ảnh nguồn (−0,5 điểm ảnh) — thu 2 lần thì đúng bằng trung bình khối 2 × 2
        let fy = ((dy as u64 * ystep + ystep / 2).saturating_sub(1 << 15)) as u32;
        let cy = ((fy >> 16) as usize) >> ys;
        let row = &mut out[((oy + dy) * w + ox) * 4..((oy + dy) * w + ox + dw) * 4];
        for dx in 0..dw {
            let fx = ((dx as u64 * xstep + xstep / 2).saturating_sub(1 << 15)) as u32;
            let al = match &ap {
                Some(p) => p.bilerp(fx, fy),
                None => 255,
            };
            if al == 0 {
                continue;
            }
            let cx = ((fx >> 16) as usize) >> xs;
            let yy = (yp.bilerp(fx, fy) as i32 - yoff) * ky;
            let u = up.at(cx, cy) as i32 - 128;
            let v = vp.at(cx, cy) as i32 - 128;
            let r = clamp((yy + krv * v + 128) >> 8);
            let g = clamp((yy - kgu * u - kgv * v + 128) >> 8);
            let b = clamp((yy + kbu * u + 128) >> 8);
            let px = &mut row[dx * 4..dx * 4 + 4];
            if al >= 255 {
                px.copy_from_slice(&[r as u8, g as u8, b as u8, 255]);
            } else {
                let m = |c: u32| {
                    let t = c * al + 128;
                    ((t + (t >> 8)) >> 8) as u8
                };
                px.copy_from_slice(&[m(r), m(g), m(b), al as u8]);
            }
        }
    }
    true
}

// ---------------------------------------------------------------------------------------------------------------------
// WebM / Matroska (EBML)

const ID_EBML: u32 = 0x1A45DFA3;
const ID_SEGMENT: u32 = 0x18538067;
const ID_INFO: u32 = 0x1549A966;
const ID_TIMECODE_SCALE: u32 = 0x2AD7B1;
const ID_TRACKS: u32 = 0x1654AE6B;
const ID_TRACK_ENTRY: u32 = 0xAE;
const ID_TRACK_NUMBER: u32 = 0xD7;
const ID_TRACK_TYPE: u32 = 0x83;
const ID_CODEC_ID: u32 = 0x86;
const ID_DEFAULT_DURATION: u32 = 0x23E383;
const ID_VIDEO: u32 = 0xE0;
const ID_PIXEL_WIDTH: u32 = 0xB0;
const ID_PIXEL_HEIGHT: u32 = 0xBA;
const ID_CLUSTER: u32 = 0x1F43B675;
const ID_TIMECODE: u32 = 0xE7;
const ID_SIMPLE_BLOCK: u32 = 0xA3;
const ID_BLOCK_GROUP: u32 = 0xA0;
const ID_BLOCK: u32 = 0xA1;
const ID_BLOCK_ADDITIONS: u32 = 0x75A1;
const ID_BLOCK_MORE: u32 = 0xA6;
const ID_BLOCK_ADD_ID: u32 = 0xEE;
const ID_BLOCK_ADDITIONAL: u32 = 0xA5;
/// Phần tử cấp Segment — gặp trong cụm (Cluster) không rõ cỡ nghĩa là cụm đã hết.
const SEGMENT_LEVEL: [u32; 8] = [ID_CLUSTER, 0x1C53BB6B, 0x1254C367, ID_INFO, ID_TRACKS, 0x114D9B74, 0x1941A469, 0x1043A770];
const UNKNOWN: u64 = u64::MAX;

struct Parsed {
    frames: Vec<Frame>,
    width: u64,
    height: u64,
    fps: f64,
}

/// Đọc số nguyên độ dài thay đổi của EBML. `id` giữ bit đánh dấu (mã phần tử), không thì bỏ (cỡ — toàn bit 1 = không rõ cỡ).
fn vint(d: &[u8], pos: &mut usize, id: bool) -> Option<u64> {
    let b = *d.get(*pos)?;
    if b == 0 {
        return None;
    }
    let len = b.leading_zeros() as usize + 1;
    let bytes = d.get(*pos..*pos + len)?;
    let mut v = if id { b as u64 } else { (b as u64) & (0xff >> len) };
    let mut all_ones = v == (0xff >> len) as u64;
    for &x in &bytes[1..] {
        v = (v << 8) | x as u64;
        all_ones &= x == 0xff;
    }
    *pos += len;
    Some(if !id && all_ones { UNKNOWN } else { v })
}

/// Đọc đầu phần tử: (mã, đầu dữ liệu, cuối dữ liệu). Cỡ không rõ → cuối = `limit`.
fn header(d: &[u8], pos: &mut usize, limit: usize) -> Option<(u32, usize, usize, bool)> {
    let id = vint(d, pos, true)?;
    let size = vint(d, pos, false)?;
    let start = *pos;
    // Mã / cỡ nằm vắt qua cuối phần tử cha (tệp lạ — kiểm bảo mật 17/11/2026: tệp 20 byte làm `&d[s..e]` với s > e → panic
    // → app tắt mỗi lần mở chat có sticker đó)
    if start > limit || limit > d.len() {
        return None;
    }
    if size == UNKNOWN {
        return Some((id as u32, start, limit, true));
    }
    let end = start.checked_add(usize::try_from(size).ok()?)?;
    if end > limit {
        // Tệp cụt: lấy tới hết phần có
        return Some((id as u32, start, limit, false));
    }
    Some((id as u32, start, end, false))
}

fn uint(d: &[u8]) -> u64 {
    d.iter().take(8).fold(0u64, |v, &b| (v << 8) | b as u64)
}

#[derive(Default)]
struct Track {
    number: u64,
    kind: u64,
    codec: Vec<u8>,
    default_duration: u64,
    width: u64,
    height: u64,
}

fn parse_track(d: &[u8], mut pos: usize, end: usize) -> Track {
    let mut t = Track::default();
    while pos < end {
        let Some((id, s, e, _)) = header(d, &mut pos, end) else { break };
        let body = &d[s..e];
        match id {
            ID_TRACK_NUMBER => t.number = uint(body),
            ID_TRACK_TYPE => t.kind = uint(body),
            ID_CODEC_ID => t.codec = body.to_vec(),
            ID_DEFAULT_DURATION => t.default_duration = uint(body),
            ID_VIDEO => {
                let mut p = s;
                while p < e {
                    let Some((vid, vs, ve, _)) = header(d, &mut p, e) else { break };
                    match vid {
                        ID_PIXEL_WIDTH => t.width = uint(&d[vs..ve]),
                        ID_PIXEL_HEIGHT => t.height = uint(&d[vs..ve]),
                        _ => {}
                    }
                    p = ve;
                }
            }
            _ => {}
        }
        pos = e;
    }
    t
}

/// Khung VP9 có phải khung khoá không (đọc đầu khung chưa nén).
fn vp9_key(f: &[u8]) -> bool {
    let Some(&b) = f.first() else { return false };
    if b >> 6 != 2 {
        return false;
    }
    let profile = ((b >> 5) & 1) | (((b >> 4) & 1) << 1);
    // Hồ sơ 3 có thêm một bit dự phòng trước show_existing_frame
    let (show_existing, frame_type) = if profile == 3 { ((b >> 2) & 1, (b >> 1) & 1) } else { ((b >> 3) & 1, (b >> 2) & 1) };
    show_existing == 0 && frame_type == 0
}

/// Một khối (Block / SimpleBlock): số track, dữ liệu khung (không hỗ trợ lacing — video không dùng).
fn block(d: &[u8], s: usize, e: usize) -> Option<(u64, Range<usize>)> {
    let mut p = s;
    let track = vint(d, &mut p, false)?;
    let flags = *d.get(p + 2)?;
    p += 3;
    if (flags >> 1) & 3 != 0 || p > e {
        return None;
    }
    Some((track, p..e))
}

fn parse_webm(d: &[u8]) -> Option<Parsed> {
    let mut pos = 0;
    let n = d.len();
    // Đầu EBML bắt buộc ở đầu tệp
    let (id, _, e, _) = header(d, &mut pos, n)?;
    if id != ID_EBML {
        return None;
    }
    pos = e;
    let (id, mut sp, seg_end, _) = loop {
        let h = header(d, &mut pos, n)?;
        if h.0 == ID_SEGMENT {
            break h;
        }
        pos = h.2;
    };
    let _ = id;
    let mut tracks: Vec<Track> = Vec::new();
    let mut video: Option<u64> = None;
    let mut timescale: u64 = 1_000_000;
    let mut frames: Vec<Frame> = Vec::new();
    let mut times: Vec<i64> = Vec::new();
    while sp < seg_end && frames.len() < MAX_FRAMES {
        let Some((id, s, e, unknown)) = header(d, &mut sp, seg_end) else { break };
        match id {
            ID_INFO => {
                let mut p = s;
                while p < e {
                    let Some((iid, is, ie, _)) = header(d, &mut p, e) else { break };
                    if iid == ID_TIMECODE_SCALE {
                        timescale = uint(&d[is..ie]).clamp(1, 1_000_000_000);
                    }
                    p = ie;
                }
                sp = e;
            }
            ID_TRACKS => {
                let mut p = s;
                while p < e {
                    let Some((tid, ts, te, _)) = header(d, &mut p, e) else { break };
                    if tid == ID_TRACK_ENTRY {
                        tracks.push(parse_track(d, ts, te));
                    }
                    p = te;
                }
                video = tracks.iter().find(|t| t.kind == 1 && t.codec == b"V_VP9").map(|t| t.number);
                if video.is_none() {
                    return None;  // không có luồng VP9
                }
                sp = e;
            }
            ID_CLUSTER => {
                let mut p = s;
                let mut cluster_tc: i64 = 0;
                while p < e && frames.len() < MAX_FRAMES {
                    let save = p;
                    let Some((cid, cs, ce, _)) = header(d, &mut p, e) else { break };
                    if unknown && SEGMENT_LEVEL.contains(&cid) {
                        p = save;  // cụm không rõ cỡ đã hết
                        break;
                    }
                    match cid {
                        ID_TIMECODE => cluster_tc = uint(&d[cs..ce]) as i64,
                        ID_SIMPLE_BLOCK => {
                            if let Some((tn, r)) = block(d, cs, ce) {
                                if Some(tn) == video {
                                    let rel = i16::from_be_bytes([d[r.start - 3], d[r.start - 2]]) as i64;
                                    times.push(cluster_tc + rel);
                                    frames.push(Frame { key: vp9_key(&d[r.clone()]), color: r, alpha: None });
                                }
                            }
                        }
                        ID_BLOCK_GROUP => {
                            let mut bp = cs;
                            let mut main: Option<(u64, Range<usize>)> = None;
                            let mut alpha: Option<Range<usize>> = None;
                            while bp < ce {
                                let Some((bid, bs, be, _)) = header(d, &mut bp, ce) else { break };
                                match bid {
                                    ID_BLOCK => main = block(d, bs, be),
                                    ID_BLOCK_ADDITIONS => {
                                        let mut ap = bs;
                                        while ap < be {
                                            let Some((mid, ms, me, _)) = header(d, &mut ap, be) else { break };
                                            if mid == ID_BLOCK_MORE {
                                                let (mut add_id, mut data) = (1u64, None);
                                                let mut q = ms;
                                                while q < me {
                                                    let Some((qid, qs, qe, _)) = header(d, &mut q, me) else { break };
                                                    match qid {
                                                        ID_BLOCK_ADD_ID => add_id = uint(&d[qs..qe]),
                                                        ID_BLOCK_ADDITIONAL => data = Some(qs..qe),
                                                        _ => {}
                                                    }
                                                    q = qe;
                                                }
                                                if add_id == 1 && data.as_ref().is_some_and(|r| !r.is_empty()) {
                                                    alpha = data;
                                                }
                                            }
                                            ap = me;
                                        }
                                    }
                                    _ => {}
                                }
                                bp = be;
                            }
                            if let Some((tn, r)) = main {
                                if Some(tn) == video {
                                    let rel = i16::from_be_bytes([d[r.start - 3], d[r.start - 2]]) as i64;
                                    times.push(cluster_tc + rel);
                                    frames.push(Frame { key: vp9_key(&d[r.clone()]), color: r, alpha });
                                }
                            }
                        }
                        _ => {}
                    }
                    p = ce;
                }
                sp = if unknown { p } else { e };
            }
            _ => {
                if unknown {
                    break;  // phần tử khác không rõ cỡ: không đọc tiếp được
                }
                sp = e;
            }
        }
    }
    let t = tracks.iter().find(|t| Some(t.number) == video)?;
    // Khung đầu phải là khung khoá (không thì không giải được từ đầu)
    if let Some(f) = frames.first_mut() {
        f.key = true;
    }
    // Khung / giây: DefaultDuration (ns), không có thì từ dấu thời gian
    let mut fps = if t.default_duration > 0 { 1e9 / t.default_duration as f64 } else { 0.0 };
    if !(fps > 0.0) && times.len() > 1 {
        let span = (times[times.len() - 1] - times[0]) as f64 * timescale as f64 / 1e9;
        if span > 0.0 {
            fps = (times.len() - 1) as f64 / span;
        }
    }
    if !(fps.is_finite() && fps >= 1.0) {
        fps = 30.0;
    }
    Some(Parsed { frames, width: t.width, height: t.height, fps: fps.min(60.0) })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Tệp lạ: phần tử con vắt qua cuối phần tử cha (kiểm bảo mật 17/11/2026) — trả None, không panic
    #[test]
    fn hostile_header_no_panic() {
        let d = [0x1a, 0x45, 0xdf, 0xa3, 0x80, 0x18, 0x53, 0x80, 0x67, 0x8a, 0x16, 0x54, 0xae, 0x6b, 0x85, 0xae, 0x81, 0x83, 0x81, 0x01];
        assert!(Video::parse(d.to_vec()).is_none());
        for n in 0..d.len() {
            let _ = Video::parse(d[..n].to_vec());
        }
    }

    #[test]
    fn vint_reads_sizes() {
        let d = [0x81, 0x40, 0x02, 0xff];
        let mut p = 0;
        assert_eq!(vint(&d, &mut p, false), Some(1));
        assert_eq!(vint(&d, &mut p, false), Some(2));
        assert_eq!(vint(&d, &mut p, false), Some(UNKNOWN));
        let mut p = 0;
        assert_eq!(vint(&[0x1A, 0x45, 0xDF, 0xA3], &mut p, true), Some(ID_EBML as u64));
    }

    #[test]
    fn rejects_non_webm() {
        assert!(Video::parse(b"\x1f\x8bnot webm".to_vec()).is_none());
        assert!(Video::parse(Vec::new()).is_none());
    }
}
