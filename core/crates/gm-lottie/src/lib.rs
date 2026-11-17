//! Vẽ hoạt hình Lottie / TGS (sticker động của Telegram — Lottie nén gzip) thành ảnh RGBA bằng tiny-skia.
//!
//! Phủ phần Lottie mà sticker Telegram được dùng (plugin Bodymovin-TG chặn phần còn lại — core.telegram.org/animated_stickers):
//! lớp hình / lớp rỗng / lớp lồng (precomp) / lớp màu, quan hệ cha — con, nhóm, đường cong (có biến hình), chữ nhật, elip, tô
//! màu, viền (đầu / góc / nét đứt), tô dải màu thẳng / tròn, cắt nét (trim), khung hình chính có làm mượt (bezier), giữ, đường đi
//! cong của vị trí. Không có: mask, matte, ảnh, chữ, biểu thức, lặp (repeater), gộp đường (merge — vẽ như cộng).
//!
//! Bản phát hành của app dựng với `panic = abort` → không được panic: đọc JSON bằng `get`, lọc NaN / vô cực, gặp gì lạ thì bỏ qua.

use std::collections::HashMap;
use std::io::Read;

use serde_json::Value;
use tiny_skia::{
    BlendMode, Color, FillRule, GradientStop, LineCap, LineJoin, LinearGradient, Paint, PathBuilder, PixmapMut, Point,
    RadialGradient, Shader, SpreadMode, Stroke, StrokeDash, Transform,
};

/// Giới hạn cho tệp lạ (sticker do người khác gửi): cỡ tệp, cỡ JSON sau giải nén, số điểm màu, số lượt vẽ lớp mỗi khung
const MAX_TGS_BYTES: usize = 512 << 10;
const MAX_JSON_BYTES: usize = 2 << 20;
const MAX_GRADIENT_STOPS: u64 = 64;
const MAX_LAYER_VISITS: u32 = 4000;

type P = [f32; 2];

// ───────────────────────────── Đọc JSON ─────────────────────────────

fn num(v: &Value) -> f32 {
    let x = v.as_f64().unwrap_or(0.0) as f32;
    if x.is_finite() {
        x
    } else {
        0.0
    }
}

/// Số hoặc mảng số → mảng số.
fn nums(v: &Value) -> Vec<f32> {
    match v {
        Value::Array(a) => a.iter().map(num).collect(),
        Value::Number(_) => vec![num(v)],
        _ => Vec::new(),
    }
}

fn p2(v: &[f32]) -> P {
    [v.first().copied().unwrap_or(0.0), v.get(1).copied().unwrap_or(0.0)]
}

/// Độ làm mượt của một khung hình chính: điểm điều khiển (x, y) của đường bezier thời gian — mỗi chiều một giá trị hoặc chung.
#[derive(Clone, Debug, Default)]
struct Ease {
    x: Vec<f32>,
    y: Vec<f32>,
}

impl Ease {
    fn parse(v: Option<&Value>) -> Option<Ease> {
        let v = v?;
        let x = nums(v.get("x")?);
        let y = nums(v.get("y")?);
        if x.is_empty() || y.is_empty() {
            None
        } else {
            Some(Ease { x, y })
        }
    }
    fn at(&self, dim: usize) -> (f32, f32) {
        let x = self.x.get(dim).or(self.x.last()).copied().unwrap_or(0.0);
        let y = self.y.get(dim).or(self.y.last()).copied().unwrap_or(0.0);
        (x, y)
    }
}

/// Đường bezier thời gian (0,0) → o → i → (1,1): tiến độ thời gian `p` → tiến độ giá trị.
fn ease(o: (f32, f32), i: (f32, f32), p: f32) -> f32 {
    let (x1, y1, x2, y2) = (o.0.clamp(0.0, 1.0), o.1, i.0.clamp(0.0, 1.0), i.1);
    let bez = |a: f32, b: f32, u: f32| {
        let v = 1.0 - u;
        3.0 * v * v * u * a + 3.0 * v * u * u * b + u * u * u
    };
    // Tìm u: bx(u) = p (chia đôi — đơn điệu vì x1, x2 trong [0, 1])
    let (mut lo, mut hi) = (0.0f32, 1.0f32);
    let mut u = p;
    for _ in 0..24 {
        let x = bez(x1, x2, u);
        if (x - p).abs() < 1e-4 {
            break;
        }
        if x < p {
            lo = u;
        } else {
            hi = u;
        }
        u = (lo + hi) * 0.5;
    }
    bez(y1, y2, u)
}

/// Một khung hình chính của thuộc tính dạng số / mảng số.
#[derive(Clone, Debug)]
struct Kf {
    t: f32,
    s: Option<Vec<f32>>,
    e: Option<Vec<f32>>,
    i: Option<Ease>,
    o: Option<Ease>,
    hold: bool,
    to: Option<P>,
    ti: Option<P>,
}

/// Thuộc tính số / mảng số: tĩnh hoặc có khung hình chính.
#[derive(Clone, Debug)]
enum Prop {
    Static(Vec<f32>),
    Anim(Vec<Kf>),
}

impl Prop {
    fn parse(v: Option<&Value>, default: &[f32]) -> Prop {
        let Some(v) = v else { return Prop::Static(default.to_vec()) };
        let k = v.get("k").unwrap_or(v);
        if let Value::Array(a) = k {
            if a.first().map(|x| x.is_object()).unwrap_or(false) {
                let kfs: Vec<Kf> = a
                    .iter()
                    .map(|x| Kf {
                        t: x.get("t").map(num).unwrap_or(0.0),
                        s: x.get("s").map(nums),
                        e: x.get("e").map(nums),
                        i: Ease::parse(x.get("i")),
                        o: Ease::parse(x.get("o")),
                        hold: x.get("h").and_then(Value::as_i64) == Some(1),
                        to: x.get("to").map(|v| p2(&nums(v))),
                        ti: x.get("ti").map(|v| p2(&nums(v))),
                    })
                    .collect();
                return if kfs.is_empty() { Prop::Static(default.to_vec()) } else { Prop::Anim(kfs) };
            }
        }
        let s = nums(k);
        Prop::Static(if s.is_empty() { default.to_vec() } else { s })
    }

    fn at(&self, t: f32) -> Vec<f32> {
        match self {
            Prop::Static(v) => v.clone(),
            Prop::Anim(kfs) => {
                let first = &kfs[0];
                if t <= first.t || kfs.len() == 1 {
                    return first.s.clone().or_else(|| first.e.clone()).unwrap_or_default();
                }
                // Khung chính cuối có t ≤ thời điểm
                let mut k = 0;
                while k + 1 < kfs.len() && kfs[k + 1].t <= t {
                    k += 1;
                }
                let a = &kfs[k];
                let Some(b) = kfs.get(k + 1) else {
                    // Sau khung chính cuối: giá trị của nó (dạng cũ không có «s» ở khung cuối → «e» của khung trước)
                    return a.s.clone().or_else(|| kfs.get(k.wrapping_sub(1)).and_then(|p| p.e.clone())).unwrap_or_default();
                };
                let start = a.s.clone().unwrap_or_default();
                if a.hold {
                    return start;
                }
                let end = a.e.clone().or_else(|| b.s.clone()).unwrap_or_else(|| start.clone());
                let span = b.t - a.t;
                let p = if span > 0.0 { ((t - a.t) / span).clamp(0.0, 1.0) } else { 1.0 };
                let (o, i) = (a.o.clone().unwrap_or_default(), a.i.clone().unwrap_or_default());
                let lin = a.o.is_none() || a.i.is_none();
                // Đường đi cong (vị trí): to / ti khác 0 → đi theo bezier không gian, tiến độ theo độ dài
                if let (Some(to), Some(ti)) = (a.to, a.ti) {
                    if start.len() >= 2 && end.len() >= 2 && (to != [0.0, 0.0] || ti != [0.0, 0.0]) {
                        let q = if lin { p } else { ease(o.at(0), i.at(0), p) };
                        let s0 = [start[0], start[1]];
                        let e0 = [end[0], end[1]];
                        let c1 = [s0[0] + to[0], s0[1] + to[1]];
                        let c2 = [e0[0] + ti[0], e0[1] + ti[1]];
                        let pt = cubic_at_length(s0, c1, c2, e0, q);
                        let mut out = vec![pt[0], pt[1]];
                        for d in 2..start.len().min(end.len()) {
                            out.push(start[d] + (end[d] - start[d]) * q);
                        }
                        return out;
                    }
                }
                let n = start.len().min(end.len());
                (0..n)
                    .map(|d| {
                        let q = if lin { p } else { ease(o.at(d), i.at(d), p) };
                        start[d] + (end[d] - start[d]) * q
                    })
                    .collect()
            }
        }
    }

    fn at1(&self, t: f32) -> f32 {
        self.at(t).first().copied().unwrap_or(0.0)
    }

    fn at2(&self, t: f32) -> P {
        p2(&self.at(t))
    }
}

/// Đường cong của Lottie: đỉnh + tiếp tuyến vào / ra (tương đối so với đỉnh).
#[derive(Clone, Debug, Default)]
struct Bez {
    closed: bool,
    v: Vec<P>,
    i: Vec<P>,
    o: Vec<P>,
}

impl Bez {
    fn parse(v: &Value) -> Bez {
        let pts = |k: &str| -> Vec<P> {
            v.get(k).and_then(Value::as_array).map(|a| a.iter().map(|x| p2(&nums(x))).collect()).unwrap_or_default()
        };
        Bez { closed: v.get("c").and_then(Value::as_bool).unwrap_or(false), v: pts("v"), i: pts("i"), o: pts("o") }
    }
    fn lerp(&self, b: &Bez, q: f32) -> Bez {
        if self.v.len() != b.v.len() || self.i.len() != b.i.len() || self.o.len() != b.o.len() {
            return if q < 1.0 { self.clone() } else { b.clone() };
        }
        let l = |x: &[P], y: &[P]| -> Vec<P> {
            x.iter().zip(y).map(|(a, c)| [a[0] + (c[0] - a[0]) * q, a[1] + (c[1] - a[1]) * q]).collect()
        };
        Bez { closed: self.closed, v: l(&self.v, &b.v), i: l(&self.i, &b.i), o: l(&self.o, &b.o) }
    }
}

#[derive(Clone, Debug)]
struct ShapeKf {
    t: f32,
    s: Option<Bez>,
    e: Option<Bez>,
    i: Option<Ease>,
    o: Option<Ease>,
    hold: bool,
}

/// Thuộc tính đường cong (có thể biến hình theo khung hình chính).
#[derive(Clone, Debug)]
enum ShapeProp {
    Static(Bez),
    Anim(Vec<ShapeKf>),
}

impl ShapeProp {
    fn parse(v: Option<&Value>) -> ShapeProp {
        let Some(v) = v else { return ShapeProp::Static(Bez::default()) };
        let k = v.get("k").unwrap_or(v);
        // Đường trong khung hình chính nằm trong mảng một phần tử
        let one = |x: Option<&Value>| -> Option<Bez> {
            let x = x?;
            Some(Bez::parse(match x {
                Value::Array(a) => a.first()?,
                o => o,
            }))
        };
        if let Value::Array(a) = k {
            if a.first().map(|x| x.get("t").is_some()).unwrap_or(false) {
                let kfs: Vec<ShapeKf> = a
                    .iter()
                    .map(|x| ShapeKf {
                        t: x.get("t").map(num).unwrap_or(0.0),
                        s: one(x.get("s")),
                        e: one(x.get("e")),
                        i: Ease::parse(x.get("i")),
                        o: Ease::parse(x.get("o")),
                        hold: x.get("h").and_then(Value::as_i64) == Some(1),
                    })
                    .collect();
                if !kfs.is_empty() {
                    return ShapeProp::Anim(kfs);
                }
            }
        }
        ShapeProp::Static(Bez::parse(k))
    }

    fn at(&self, t: f32) -> Bez {
        match self {
            ShapeProp::Static(b) => b.clone(),
            ShapeProp::Anim(kfs) => {
                let first = &kfs[0];
                if t <= first.t || kfs.len() == 1 {
                    return first.s.clone().or_else(|| first.e.clone()).unwrap_or_default();
                }
                let mut k = 0;
                while k + 1 < kfs.len() && kfs[k + 1].t <= t {
                    k += 1;
                }
                let a = &kfs[k];
                let Some(b) = kfs.get(k + 1) else {
                    return a.s.clone().or_else(|| kfs.get(k.wrapping_sub(1)).and_then(|p| p.e.clone())).unwrap_or_default();
                };
                let start = a.s.clone().unwrap_or_default();
                if a.hold {
                    return start;
                }
                let end = a.e.clone().or_else(|| b.s.clone()).unwrap_or_else(|| start.clone());
                let span = b.t - a.t;
                let p = if span > 0.0 { ((t - a.t) / span).clamp(0.0, 1.0) } else { 1.0 };
                let q = match (&a.o, &a.i) {
                    (Some(o), Some(i)) => ease(o.at(0), i.at(0), p),
                    _ => p,
                };
                start.lerp(&end, q)
            }
        }
    }
}

// ───────────────────────────── Hình học ─────────────────────────────

/// Một đường kín / hở gồm các đoạn bezier bậc ba (đoạn thẳng = bezier có điểm điều khiển trùng đầu mút).
#[derive(Clone, Debug)]
struct Contour {
    start: P,
    segs: Vec<[P; 3]>,
    closed: bool,
}

fn lerp2(a: P, b: P, t: f32) -> P {
    [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]
}

fn cubic_point(p0: P, p1: P, p2: P, p3: P, t: f32) -> P {
    let u = 1.0 - t;
    let a = u * u * u;
    let b = 3.0 * u * u * t;
    let c = 3.0 * u * t * t;
    let d = t * t * t;
    [a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]]
}

/// Tách bezier tại t (de Casteljau) → (nửa đầu, nửa sau), mỗi nửa [c1, c2, mút].
fn cubic_split(p0: P, p1: P, p2: P, p3: P, t: f32) -> ([P; 3], P, [P; 3]) {
    let a = lerp2(p0, p1, t);
    let b = lerp2(p1, p2, t);
    let c = lerp2(p2, p3, t);
    let d = lerp2(a, b, t);
    let e = lerp2(b, c, t);
    let m = lerp2(d, e, t);
    ([a, d, m], m, [e, c, p3])
}

const STEPS: usize = 12;

fn dist(a: P, b: P) -> f32 {
    ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2)).sqrt()
}

/// Độ dài xấp xỉ của một đoạn bezier (12 đoạn thẳng).
fn cubic_len(p0: P, p1: P, p2: P, p3: P) -> f32 {
    let mut len = 0.0;
    let mut prev = p0;
    for k in 1..=STEPS {
        let q = cubic_point(p0, p1, p2, p3, k as f32 / STEPS as f32);
        len += dist(prev, q);
        prev = q;
    }
    len
}

/// Tham số t ứng với phần độ dài `frac` (0…1) của đoạn bezier.
fn cubic_t_at(p0: P, p1: P, p2: P, p3: P, frac: f32) -> f32 {
    let total = cubic_len(p0, p1, p2, p3);
    if total <= 0.0 {
        return frac;
    }
    let want = total * frac.clamp(0.0, 1.0);
    let mut acc = 0.0;
    let mut prev = p0;
    for k in 1..=STEPS {
        let t = k as f32 / STEPS as f32;
        let q = cubic_point(p0, p1, p2, p3, t);
        let d = dist(prev, q);
        if acc + d >= want && d > 0.0 {
            return (k as f32 - 1.0 + (want - acc) / d) / STEPS as f32;
        }
        acc += d;
        prev = q;
    }
    1.0
}

fn cubic_at_length(p0: P, p1: P, p2: P, p3: P, frac: f32) -> P {
    cubic_point(p0, p1, p2, p3, cubic_t_at(p0, p1, p2, p3, frac))
}

impl Contour {
    fn from_bez(b: &Bez) -> Option<Contour> {
        let n = b.v.len();
        if n == 0 {
            return None;
        }
        let at = |a: &[P], k: usize| a.get(k).copied().unwrap_or([0.0, 0.0]);
        let mut segs = Vec::with_capacity(n);
        let last = if b.closed { n } else { n - 1 };
        for k in 0..last {
            let j = (k + 1) % n;
            let (vk, vj) = (at(&b.v, k), at(&b.v, j));
            let (ok, ij) = (at(&b.o, k), at(&b.i, j));
            segs.push([[vk[0] + ok[0], vk[1] + ok[1]], [vj[0] + ij[0], vj[1] + ij[1]], vj]);
        }
        Some(Contour { start: at(&b.v, 0), segs, closed: b.closed })
    }

    fn rect(c: P, s: P, r: f32) -> Contour {
        let (hw, hh) = (s[0].abs() / 2.0, s[1].abs() / 2.0);
        let r = r.max(0.0).min(hw).min(hh);
        let (l, t, rt, b) = (c[0] - hw, c[1] - hh, c[0] + hw, c[1] + hh);
        let line = |a: P, z: P| -> [P; 3] { [a, z, z] };
        if r <= 0.0 {
            return Contour {
                start: [rt, t],
                segs: vec![line([rt, t], [rt, b]), line([rt, b], [l, b]), line([l, b], [l, t]), line([l, t], [rt, t])],
                closed: true,
            };
        }
        let k = r * 0.5523;
        Contour {
            start: [rt, t + r],
            segs: vec![
                line([rt, t + r], [rt, b - r]),
                [[rt, b - r + k], [rt - r + k, b], [rt - r, b]],
                line([rt - r, b], [l + r, b]),
                [[l + r - k, b], [l, b - r + k], [l, b - r]],
                line([l, b - r], [l, t + r]),
                [[l, t + r - k], [l + r - k, t], [l + r, t]],
                line([l + r, t], [rt - r, t]),
                [[rt - r + k, t], [rt, t + r - k], [rt, t + r]],
            ],
            closed: true,
        }
    }

    fn ellipse(c: P, s: P) -> Contour {
        let (rx, ry) = (s[0].abs() / 2.0, s[1].abs() / 2.0);
        let (kx, ky) = (rx * 0.5523, ry * 0.5523);
        let (x, y) = (c[0], c[1]);
        Contour {
            start: [x, y - ry],
            segs: vec![
                [[x + kx, y - ry], [x + rx, y - ky], [x + rx, y]],
                [[x + rx, y + ky], [x + kx, y + ry], [x, y + ry]],
                [[x - kx, y + ry], [x - rx, y + ky], [x - rx, y]],
                [[x - rx, y - ky], [x - kx, y - ry], [x, y - ry]],
            ],
            closed: true,
        }
    }

    fn map(&self, m: &Transform) -> Contour {
        let f = |p: P| -> P { [m.sx * p[0] + m.kx * p[1] + m.tx, m.ky * p[0] + m.sy * p[1] + m.ty] };
        Contour { start: f(self.start), segs: self.segs.iter().map(|s| [f(s[0]), f(s[1]), f(s[2])]).collect(), closed: self.closed }
    }

    /// Đoạn bezier đầy đủ (kể cả đoạn đóng về điểm đầu nếu đường kín mà chưa đóng sẵn).
    fn full_segs(&self) -> Vec<(P, [P; 3])> {
        let mut out = Vec::with_capacity(self.segs.len() + 1);
        let mut prev = self.start;
        for s in &self.segs {
            out.push((prev, *s));
            prev = s[2];
        }
        if self.closed && dist(prev, self.start) > 1e-3 {
            out.push((prev, [prev, self.start, self.start]));
        }
        out
    }

    fn length(&self) -> f32 {
        self.full_segs().iter().map(|(a, s)| cubic_len(*a, s[0], s[1], s[2])).sum()
    }

    /// Phần đường từ độ dài `from` tới `to` (0 ≤ from ≤ to ≤ độ dài) → đường hở mới.
    fn sub(&self, from: f32, to: f32) -> Option<Contour> {
        if to - from <= 1e-4 {
            return None;
        }
        let mut acc = 0.0;
        let mut out: Option<Contour> = None;
        for (a, s) in self.full_segs() {
            let len = cubic_len(a, s[0], s[1], s[2]);
            let (s0, s1) = (acc, acc + len);
            acc = s1;
            if s1 <= from || s0 >= to || len <= 0.0 {
                continue;
            }
            // Phần [max(from, s0), min(to, s1)] của đoạn này
            let t0 = if from > s0 { cubic_t_at(a, s[0], s[1], s[2], (from - s0) / len) } else { 0.0 };
            let t1 = if to < s1 { cubic_t_at(a, s[0], s[1], s[2], (to - s0) / len) } else { 1.0 };
            let (mut p0, mut c) = (a, s);
            if t0 > 0.0 {
                let (_, m, second) = cubic_split(p0, c[0], c[1], c[2], t0);
                p0 = m;
                c = second;
            }
            if t1 < 1.0 {
                let local = if t0 < 1.0 { (t1 - t0) / (1.0 - t0) } else { 1.0 };
                let (first, _, _) = cubic_split(p0, c[0], c[1], c[2], local);
                c = first;
            }
            match out.as_mut() {
                Some(o) => o.segs.push(c),
                None => out = Some(Contour { start: p0, segs: vec![c], closed: false }),
            }
        }
        out
    }
}

/// Cắt nét (trim paths): giữ phần [s, e] (phần trăm) + lệch o (độ) của các đường. `individually`: coi mọi đường là một đường nối.
fn trim(contours: &mut Vec<Contour>, s: f32, e: f32, o: f32, individually: bool) {
    let (mut a, mut b) = (s / 100.0, e / 100.0);
    if a > b {
        std::mem::swap(&mut a, &mut b);
    }
    if a <= 0.0 && b >= 1.0 {
        return;
    }
    let off = (o / 360.0).rem_euclid(1.0);
    let (a, b) = (a + off, b + off);
    // Khoảng [a, b] trên vòng 0…1 → tối đa hai khoảng
    let ranges: Vec<(f32, f32)> = if b - a >= 1.0 {
        vec![(0.0, 1.0)]
    } else if b <= 1.0 {
        vec![(a, b)]
    } else if a >= 1.0 {
        vec![(a - 1.0, b - 1.0)]
    } else {
        vec![(a, 1.0), (0.0, b - 1.0)]
    };
    let src = std::mem::take(contours);
    if individually {
        let lens: Vec<f32> = src.iter().map(Contour::length).collect();
        let total: f32 = lens.iter().sum();
        let mut start = 0.0;
        for (c, len) in src.iter().zip(&lens) {
            for &(ra, rb) in &ranges {
                let (from, to) = ((ra * total - start).max(0.0), (rb * total - start).min(*len));
                if let Some(x) = c.sub(from, to) {
                    contours.push(x);
                }
            }
            start += len;
        }
    } else {
        for c in &src {
            let len = c.length();
            for &(ra, rb) in &ranges {
                if let Some(x) = c.sub(ra * len, rb * len) {
                    contours.push(x);
                }
            }
        }
    }
}

// ───────────────────────────── Mô hình ─────────────────────────────

#[derive(Clone, Debug)]
struct Tr {
    a: Prop,
    p: Prop,
    px: Option<Prop>,
    py: Option<Prop>,
    s: Prop,
    r: Prop,
    o: Prop,
    sk: Prop,
    sa: Prop,
}

impl Tr {
    fn parse(v: Option<&Value>) -> Tr {
        let g = |k: &str| v.and_then(|v| v.get(k));
        let split = g("p").map(|p| p.get("s").and_then(Value::as_bool).unwrap_or(false)).unwrap_or(false);
        Tr {
            a: Prop::parse(g("a"), &[0.0, 0.0]),
            p: Prop::parse(if split { None } else { g("p") }, &[0.0, 0.0]),
            px: if split { Some(Prop::parse(g("p").and_then(|p| p.get("x")), &[0.0])) } else { None },
            py: if split { Some(Prop::parse(g("p").and_then(|p| p.get("y")), &[0.0])) } else { None },
            s: Prop::parse(g("s"), &[100.0, 100.0]),
            r: Prop::parse(g("r").or(g("rz")), &[0.0]),
            o: Prop::parse(g("o"), &[100.0]),
            sk: Prop::parse(g("sk"), &[0.0]),
            sa: Prop::parse(g("sa"), &[0.0]),
        }
    }

    /// Ma trận (vị trí · xoay · nghiêng · tỉ lệ · −điểm neo) và độ đục 0…1 tại thời điểm t.
    fn at(&self, t: f32) -> (Transform, f32) {
        let a = self.a.at2(t);
        let p = match (&self.px, &self.py) {
            (Some(x), Some(y)) => [x.at1(t), y.at1(t)],
            _ => self.p.at2(t),
        };
        let s = self.s.at(t);
        let (sx, sy) = (s.first().copied().unwrap_or(100.0) / 100.0, s.get(1).copied().unwrap_or(100.0) / 100.0);
        let r = self.r.at1(t);
        let mut m = Transform::from_translate(p[0], p[1]).pre_concat(Transform::from_rotate(r));
        let sk = self.sk.at1(t);
        if sk != 0.0 {
            let sa = self.sa.at1(t);
            let k = (-sk.to_radians()).tan();
            m = m
                .pre_concat(Transform::from_rotate(-sa))
                .pre_concat(Transform::from_row(1.0, 0.0, k, 1.0, 0.0, 0.0))
                .pre_concat(Transform::from_rotate(sa));
        }
        m = m.pre_scale(sx, sy).pre_translate(-a[0], -a[1]);
        (m, (self.o.at1(t) / 100.0).clamp(0.0, 1.0))
    }
}

#[derive(Clone, Debug)]
struct StrokeStyle {
    w: Prop,
    cap: LineCap,
    join: LineJoin,
    miter: f32,
    dash: Vec<(char, Prop)>,
}

#[derive(Clone, Debug)]
struct Gradient {
    linear: bool,
    s: Prop,
    e: Prop,
    g: Prop,
    count: usize,
}

#[derive(Clone, Debug)]
enum Item {
    Group { items: Vec<Item>, tr: Option<Tr> },
    Path(ShapeProp),
    Rect { p: Prop, s: Prop, r: Prop },
    Ellipse { p: Prop, s: Prop },
    Fill { c: Prop, o: Prop, evenodd: bool },
    Stroke { c: Prop, o: Prop, st: StrokeStyle },
    GFill { g: Gradient, o: Prop, evenodd: bool },
    GStroke { g: Gradient, o: Prop, st: StrokeStyle },
    Trim { s: Prop, e: Prop, o: Prop, individually: bool },
}

fn parse_stroke(v: &Value) -> StrokeStyle {
    let cap = match v.get("lc").and_then(Value::as_i64) {
        Some(2) => LineCap::Round,
        Some(3) => LineCap::Square,
        _ => LineCap::Butt,
    };
    let join = match v.get("lj").and_then(Value::as_i64) {
        Some(2) => LineJoin::Round,
        Some(3) => LineJoin::Bevel,
        _ => LineJoin::Miter,
    };
    let dash = v
        .get("d")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|d| {
                    let n = d.get("n").and_then(Value::as_str)?.chars().next()?;
                    Some((n, Prop::parse(d.get("v"), &[0.0])))
                })
                .collect()
        })
        .unwrap_or_default();
    StrokeStyle { w: Prop::parse(v.get("w"), &[1.0]), cap, join, miter: v.get("ml").map(num).unwrap_or(4.0).max(1.0), dash }
}

fn parse_gradient(v: &Value) -> Gradient {
    let gv = v.get("g");
    Gradient {
        linear: v.get("t").and_then(Value::as_i64).unwrap_or(1) != 2,
        s: Prop::parse(v.get("s"), &[0.0, 0.0]),
        e: Prop::parse(v.get("e"), &[0.0, 0.0]),
        g: Prop::parse(gv.and_then(|g| g.get("k")), &[]),
        // Số điểm màu do tệp khai (kiểm bảo mật 17/11/2026: tệp lạ khai 4 tỉ → cấp phát hỏng → app tắt) — thực tế vài điểm
        count: gv.and_then(|g| g.get("p")).and_then(Value::as_u64).unwrap_or(0).min(MAX_GRADIENT_STOPS) as usize,
    }
}

fn parse_items(a: Option<&Value>) -> Vec<Item> {
    let Some(Value::Array(a)) = a else { return Vec::new() };
    let mut out = Vec::new();
    for v in a {
        if v.get("hd").and_then(Value::as_bool).unwrap_or(false) {
            continue;
        }
        let evenodd = v.get("r").and_then(Value::as_i64) == Some(2);
        let item = match v.get("ty").and_then(Value::as_str).unwrap_or("") {
            "gr" => {
                let it = v.get("it");
                let tr = it.and_then(Value::as_array).and_then(|a| a.iter().find(|x| x.get("ty").and_then(Value::as_str) == Some("tr")));
                Item::Group { items: parse_items(it), tr: tr.map(|t| Tr::parse(Some(t))) }
            }
            "sh" => Item::Path(ShapeProp::parse(v.get("ks"))),
            "rc" => Item::Rect { p: Prop::parse(v.get("p"), &[0.0, 0.0]), s: Prop::parse(v.get("s"), &[0.0, 0.0]), r: Prop::parse(v.get("r"), &[0.0]) },
            "el" => Item::Ellipse { p: Prop::parse(v.get("p"), &[0.0, 0.0]), s: Prop::parse(v.get("s"), &[0.0, 0.0]) },
            "fl" => Item::Fill { c: Prop::parse(v.get("c"), &[0.0, 0.0, 0.0, 1.0]), o: Prop::parse(v.get("o"), &[100.0]), evenodd },
            "st" => Item::Stroke { c: Prop::parse(v.get("c"), &[0.0, 0.0, 0.0, 1.0]), o: Prop::parse(v.get("o"), &[100.0]), st: parse_stroke(v) },
            "gf" => Item::GFill { g: parse_gradient(v), o: Prop::parse(v.get("o"), &[100.0]), evenodd },
            "gs" => Item::GStroke { g: parse_gradient(v), o: Prop::parse(v.get("o"), &[100.0]), st: parse_stroke(v) },
            "tm" => Item::Trim {
                s: Prop::parse(v.get("s"), &[0.0]),
                e: Prop::parse(v.get("e"), &[100.0]),
                o: Prop::parse(v.get("o"), &[0.0]),
                individually: v.get("m").and_then(Value::as_i64) == Some(2),
            },
            _ => continue,  // tr (đã lấy riêng), mm, rp, rd, sr…
        };
        out.push(item);
    }
    out
}

#[derive(Clone, Debug)]
struct Layer {
    ty: i64,
    ind: Option<i64>,
    parent: Option<i64>,
    ip: f32,
    op: f32,
    st: f32,
    sr: f32,
    ks: Tr,
    items: Vec<Item>,
    ref_id: Option<String>,
    solid: Option<([f32; 3], f32, f32)>,
    skip: bool,
}

fn parse_layers(a: Option<&Value>) -> Vec<Layer> {
    let Some(Value::Array(a)) = a else { return Vec::new() };
    a.iter()
        .map(|v| {
            let ty = v.get("ty").and_then(Value::as_i64).unwrap_or(-1);
            let solid = if ty == 1 {
                let hex = v.get("sc").and_then(Value::as_str).unwrap_or("#000000").trim_start_matches('#');
                let c = |i: usize| u8::from_str_radix(hex.get(i..i + 2).unwrap_or("00"), 16).unwrap_or(0) as f32 / 255.0;
                Some(([c(0), c(2), c(4)], v.get("sw").map(num).unwrap_or(0.0), v.get("sh").map(num).unwrap_or(0.0)))
            } else {
                None
            };
            Layer {
                ty,
                ind: v.get("ind").and_then(Value::as_i64),
                parent: v.get("parent").and_then(Value::as_i64),
                ip: v.get("ip").map(num).unwrap_or(0.0),
                op: v.get("op").map(num).unwrap_or(f32::MAX),
                st: v.get("st").map(num).unwrap_or(0.0),
                sr: v.get("sr").map(num).filter(|x| *x > 0.0).unwrap_or(1.0),
                ks: Tr::parse(v.get("ks")),
                items: parse_items(v.get("shapes")),
                ref_id: v.get("refId").and_then(Value::as_str).map(String::from),
                solid,
                // Ẩn, lớp làm matte cho lớp khác (td — matte không hỗ trợ: đừng vẽ chính nó ra), ảnh / chữ
                skip: v.get("hd").and_then(Value::as_bool).unwrap_or(false)
                    || v.get("td").and_then(Value::as_i64).unwrap_or(0) != 0
                    || ty == 2
                    || ty == 5,
            }
        })
        .collect()
}

/// Hoạt hình đã đọc (bất biến — vẽ từ luồng nào cũng được).
pub struct Animation {
    w: f32,
    h: f32,
    fr: f32,
    ip: f32,
    op: f32,
    layers: Vec<Layer>,
    assets: HashMap<String, Vec<Layer>>,
}

impl Animation {
    /// Đọc TGS (gzip) hoặc JSON Lottie.
    pub fn parse(data: &[u8]) -> Result<Animation, String> {
        // Giới hạn cỡ (kiểm bảo mật 17/11/2026): Telegram cho TGS tối đa 64 KB nén; «bom gzip» 16 KB nở ra 16 MB JSON → cây
        // serde_json vài trăm MB → máy 256 MB tắt app ngay khi mở chat (sticker tự chạy)
        if data.len() > MAX_TGS_BYTES {
            return Err("tệp quá lớn".into());
        }
        let json: Vec<u8>;
        let raw = if data.starts_with(&[0x1f, 0x8b]) {
            let mut d = flate2::read::GzDecoder::new(data).take(MAX_JSON_BYTES as u64 + 1);
            let mut out = Vec::new();
            d.read_to_end(&mut out).map_err(|e| format!("gzip: {e}"))?;
            if out.len() > MAX_JSON_BYTES {
                return Err("tệp giải nén quá lớn".into());
            }
            json = out;
            &json[..]
        } else if data.len() > MAX_JSON_BYTES {
            return Err("tệp quá lớn".into());
        } else {
            data
        };
        let v: Value = serde_json::from_slice(raw).map_err(|e| format!("json: {e}"))?;
        let w = v.get("w").map(num).unwrap_or(512.0);
        let h = v.get("h").map(num).unwrap_or(512.0);
        let fr = v.get("fr").map(num).filter(|x| *x > 0.0).unwrap_or(30.0);
        let ip = v.get("ip").map(num).unwrap_or(0.0);
        let op = v.get("op").map(num).unwrap_or(ip + 1.0);
        if w <= 0.0 || h <= 0.0 || op <= ip {
            return Err("kích thước / thời lượng sai".into());
        }
        let mut assets = HashMap::new();
        if let Some(Value::Array(a)) = v.get("assets") {
            for x in a {
                if let (Some(id), Some(_)) = (x.get("id").and_then(Value::as_str), x.get("layers")) {
                    assets.insert(id.to_string(), parse_layers(x.get("layers")));
                }
            }
        }
        Ok(Animation { w, h, fr, ip, op, layers: parse_layers(v.get("layers")), assets })
    }

    pub fn frame_rate(&self) -> f32 {
        self.fr
    }
    /// Số khung hình (op − ip).
    pub fn frames(&self) -> u32 {
        (self.op - self.ip).ceil().max(1.0) as u32
    }
    pub fn size(&self) -> (f32, f32) {
        (self.w, self.h)
    }

    /// Vẽ khung hình thứ `index` (0 … frames − 1) vào bộ đệm RGBA đã nhân alpha (`width × height × 4` byte, xoá trước khi vẽ),
    /// co vừa khung giữ tỉ lệ, đặt giữa. Trả false nếu bộ đệm sai cỡ.
    pub fn render(&self, index: f32, buf: &mut [u8], width: u32, height: u32) -> bool {
        let Some(mut pm) = PixmapMut::from_bytes(buf, width, height) else { return false };
        pm.fill(Color::TRANSPARENT);
        let k = (width as f32 / self.w).min(height as f32 / self.h);
        let base = Transform::from_translate((width as f32 - self.w * k) / 2.0, (height as f32 - self.h * k) / 2.0).pre_scale(k, k);
        let t = (self.ip + index).min(self.op - 0.001);
        let mut budget = MAX_LAYER_VISITS;
        self.draw_layers(&self.layers, t, base, 1.0, &mut pm, 0, &mut budget);
        true
    }

    /// Ma trận của lớp (nhân dồn các lớp cha, mỗi lớp ở thời gian riêng của nó). Độ đục chỉ của chính lớp.
    fn layer_matrix(&self, layers: &[Layer], l: &Layer, t: f32) -> (Transform, f32) {
        let local = (t - l.st) / l.sr;
        let (mut m, op) = l.ks.at(local);
        let mut parent = l.parent;
        let mut depth = 0;
        while let (Some(pi), true) = (parent, depth < 32) {
            let Some(p) = layers.iter().find(|x| x.ind == Some(pi)) else { break };
            let (pm, _) = p.ks.at((t - p.st) / p.sr);
            m = pm.pre_concat(m);
            parent = p.parent;
            depth += 1;
        }
        (m, op)
    }

    /// `budget`: số lượt vẽ lớp còn lại trong khung này — lớp lồng (precomp) trỏ lại chính nó N lần thì độ sâu 8 vẫn ra N^9
    /// lượt (kiểm bảo mật 17/11/2026: tệp 400 byte treo hàng vẽ sticker mãi) → hết lượt thì thôi vẽ.
    #[allow(clippy::too_many_arguments)]
    fn draw_layers(&self, layers: &[Layer], t: f32, base: Transform, opacity: f32, pm: &mut PixmapMut, depth: u32, budget: &mut u32) {
        if depth > 8 {
            return;
        }
        // Lớp đầu danh sách nằm trên cùng → vẽ từ cuối lên
        for l in layers.iter().rev() {
            if *budget == 0 {
                return;
            }
            *budget -= 1;
            if l.skip || t < l.ip || t >= l.op {
                continue;
            }
            let (m, op) = self.layer_matrix(layers, l, t);
            let m = base.pre_concat(m);
            let op = op * opacity;
            if op <= 0.001 {
                continue;
            }
            let local = (t - l.st) / l.sr;
            match l.ty {
                4 => draw_items(&l.items, local, m, op, pm),
                0 => {
                    if let Some(inner) = l.ref_id.as_ref().and_then(|id| self.assets.get(id)) {
                        self.draw_layers(inner, local, m, op, pm, depth + 1, budget);
                    }
                }
                1 => {
                    if let Some((c, w, h)) = l.solid {
                        let contour = Contour::rect([w / 2.0, h / 2.0], [w, h], 0.0);
                        let mut paint = Paint::default();
                        paint.anti_alias = true;
                        paint.set_color(color(c[0], c[1], c[2], op));
                        if let Some(path) = build_path(&[contour]) {
                            pm.fill_path(&path, &paint, FillRule::Winding, m, None);
                        }
                    }
                }
                _ => {}
            }
        }
    }
}

fn color(r: f32, g: f32, b: f32, a: f32) -> Color {
    // Một số tệp cũ ghi màu 0…255
    let (r, g, b) = if r > 1.0 || g > 1.0 || b > 1.0 { (r / 255.0, g / 255.0, b / 255.0) } else { (r, g, b) };
    Color::from_rgba(r.clamp(0.0, 1.0), g.clamp(0.0, 1.0), b.clamp(0.0, 1.0), a.clamp(0.0, 1.0)).unwrap_or(Color::TRANSPARENT)
}

fn build_path(contours: &[Contour]) -> Option<tiny_skia::Path> {
    let mut pb = PathBuilder::new();
    let ok = |p: P| p[0].is_finite() && p[1].is_finite();
    for c in contours {
        if !ok(c.start) || c.segs.iter().any(|s| !ok(s[0]) || !ok(s[1]) || !ok(s[2])) {
            continue;
        }
        pb.move_to(c.start[0], c.start[1]);
        for s in &c.segs {
            pb.cubic_to(s[0][0], s[0][1], s[1][0], s[1][1], s[2][0], s[2][1]);
        }
        if c.closed {
            pb.close();
        }
    }
    pb.finish()
}

/// Gom hình học của `items` (hệ toạ độ của kiểu tô đang xét, `rel` = biến đổi của nhóm con so với nó), áp cắt nét theo thứ tự.
fn collect(items: &[Item], t: f32, rel: Transform, out: &mut Vec<Contour>) {
    let start = out.len();
    for it in items {
        match it {
            Item::Path(sp) => {
                if let Some(c) = Contour::from_bez(&sp.at(t)) {
                    out.push(c.map(&rel));
                }
            }
            Item::Rect { p, s, r } => out.push(Contour::rect(p.at2(t), s.at2(t), r.at1(t)).map(&rel)),
            Item::Ellipse { p, s } => out.push(Contour::ellipse(p.at2(t), s.at2(t)).map(&rel)),
            Item::Group { items, tr } => {
                let gm = tr.as_ref().map(|tr| tr.at(t).0).unwrap_or_default();
                collect(items, t, rel.pre_concat(gm), out);
            }
            Item::Trim { s, e, o, individually } => {
                let mut tail = out.split_off(start);
                trim(&mut tail, s.at1(t), e.at1(t), o.at1(t), *individually);
                out.extend(tail);
            }
            _ => {}
        }
    }
}

fn stroke_of(st: &StrokeStyle, t: f32) -> Option<Stroke> {
    let width = st.w.at1(t);
    if width <= 0.0 {
        return None;
    }
    let mut s = Stroke { width, line_cap: st.cap, line_join: st.join, miter_limit: st.miter, dash: None };
    if !st.dash.is_empty() {
        let mut intervals = Vec::new();
        let mut offset = 0.0;
        for (n, v) in &st.dash {
            match n {
                'o' => offset = v.at1(t),
                _ => intervals.push(v.at1(t).max(0.0)),
            }
        }
        if intervals.len() % 2 == 1 {
            let copy = intervals.clone();
            intervals.extend(copy);
        }
        if intervals.iter().any(|x| *x > 0.0) {
            s.dash = StrokeDash::new(intervals, offset);
        }
    }
    Some(s)
}

fn gradient_shader(g: &Gradient, t: f32, opacity: f32) -> Option<Shader<'static>> {
    let v = g.g.at(t);
    let n = g.count.max(1);
    let mut stops = Vec::with_capacity(n);
    for k in 0..n {
        let Some(c) = v.get(k * 4..k * 4 + 4) else { break };
        // Độ trong (nếu có) nằm sau phần màu: cặp [vị trí, alpha]; lấy alpha ở vị trí gần nhất
        let alpha = if v.len() >= n * 4 + 2 {
            let al = &v[n * 4..];
            let mut best = (f32::MAX, 1.0);
            for pair in al.chunks(2) {
                if let [pos, a] = pair {
                    let d = (pos - c[0]).abs();
                    if d < best.0 {
                        best = (d, *a);
                    }
                }
            }
            best.1
        } else {
            1.0
        };
        stops.push(GradientStop::new(c[0].clamp(0.0, 1.0), color(c[1], c[2], c[3], alpha * opacity)));
    }
    if stops.len() < 2 {
        return None;
    }
    let s = g.s.at2(t);
    let e = g.e.at2(t);
    if g.linear {
        LinearGradient::new(Point::from_xy(s[0], s[1]), Point::from_xy(e[0], e[1]), stops, SpreadMode::Pad, Transform::identity())
    } else {
        let r = dist(s, e).max(0.01);
        RadialGradient::new(Point::from_xy(s[0], s[1]), Point::from_xy(s[0], s[1]), r, stops, SpreadMode::Pad, Transform::identity())
    }
}

/// Vẽ danh sách mục của một nhóm: đi từ cuối lên (mục dưới nằm sau); kiểu tô / viền áp cho mọi hình phía trên nó trong nhóm
/// (kể cả trong nhóm con); nhóm con tự vẽ kiểu tô của nó.
fn draw_items(items: &[Item], t: f32, m: Transform, opacity: f32, pm: &mut PixmapMut) {
    for j in (0..items.len()).rev() {
        let it = &items[j];
        match it {
            Item::Group { items: sub, tr } => {
                let (gm, gop) = tr.as_ref().map(|tr| tr.at(t)).unwrap_or((Transform::identity(), 1.0));
                if gop * opacity > 0.001 {
                    draw_items(sub, t, m.pre_concat(gm), opacity * gop, pm);
                }
            }
            Item::Fill { .. } | Item::Stroke { .. } | Item::GFill { .. } | Item::GStroke { .. } => {
                let mut geo = Vec::new();
                collect(&items[..j], t, Transform::identity(), &mut geo);
                if geo.is_empty() {
                    continue;
                }
                let Some(path) = build_path(&geo) else { continue };
                let mut paint = Paint::default();
                paint.anti_alias = true;
                paint.blend_mode = BlendMode::SourceOver;
                match it {
                    Item::Fill { c, o, evenodd } => {
                        let c = c.at(t);
                        let a = c.get(3).copied().unwrap_or(1.0).min(1.0) * o.at1(t) / 100.0 * opacity;
                        if a <= 0.001 {
                            continue;
                        }
                        paint.set_color(color(c.first().copied().unwrap_or(0.0), c.get(1).copied().unwrap_or(0.0), c.get(2).copied().unwrap_or(0.0), a));
                        pm.fill_path(&path, &paint, if *evenodd { FillRule::EvenOdd } else { FillRule::Winding }, m, None);
                    }
                    Item::Stroke { c, o, st } => {
                        let c = c.at(t);
                        let a = c.get(3).copied().unwrap_or(1.0).min(1.0) * o.at1(t) / 100.0 * opacity;
                        let Some(stroke) = stroke_of(st, t) else { continue };
                        if a <= 0.001 {
                            continue;
                        }
                        paint.set_color(color(c.first().copied().unwrap_or(0.0), c.get(1).copied().unwrap_or(0.0), c.get(2).copied().unwrap_or(0.0), a));
                        pm.stroke_path(&path, &paint, &stroke, m, None);
                    }
                    Item::GFill { g, o, evenodd } => {
                        let Some(shader) = gradient_shader(g, t, o.at1(t) / 100.0 * opacity) else { continue };
                        paint.shader = shader;
                        pm.fill_path(&path, &paint, if *evenodd { FillRule::EvenOdd } else { FillRule::Winding }, m, None);
                    }
                    Item::GStroke { g, o, st } => {
                        let Some(stroke) = stroke_of(st, t) else { continue };
                        let Some(shader) = gradient_shader(g, t, o.at1(t) / 100.0 * opacity) else { continue };
                        paint.shader = shader;
                        pm.stroke_path(&path, &paint, &stroke, m, None);
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gz(json: &[u8]) -> Vec<u8> {
        use std::io::Write;
        let mut e = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::best());
        e.write_all(json).unwrap();
        e.finish().unwrap()
    }

    /// Tệp lạ (kiểm bảo mật 17/11/2026): bom gzip bị từ chối; gradient khai 4 tỉ điểm và lớp lồng tự trỏ vẽ được nhanh, không tắt app
    #[test]
    fn hostile_files() {
        let mut bomb = b"[".to_vec();
        bomb.extend(std::iter::repeat_n(b"0,"[..].iter().copied(), 3 << 20).flatten());
        bomb.extend_from_slice(b"0]");
        assert!(Animation::parse(&gz(&bomb)).is_err());

        let grad = br#"{"w":64,"h":64,"fr":30,"ip":0,"op":2,"layers":[{"ty":4,"ip":0,"op":2,"st":0,"ks":{},"shapes":[
            {"ty":"rc","p":{"k":[32,32]},"s":{"k":[40,40]},"r":{"k":0}},
            {"ty":"gf","o":{"k":100},"t":1,"s":{"k":[0,0]},"e":{"k":[64,64]},"g":{"p":4000000000,"k":{"k":[0,1,0,0,1,0,0,1]}}}]}]}"#;
        let a = Animation::parse(grad).unwrap();
        let mut buf = vec![0u8; 64 * 64 * 4];
        a.render(0.0, &mut buf, 64, 64);

        let rf = r#"{"ty":0,"refId":"a","ip":0,"op":2,"st":0,"ks":{}}"#;
        let many = vec![rf; 10].join(",");
        let json = format!(r#"{{"w":64,"h":64,"fr":30,"ip":0,"op":2,"assets":[{{"id":"a","layers":[{many}]}}],"layers":[{rf}]}}"#);
        let a = Animation::parse(json.as_bytes()).unwrap();
        let t = std::time::Instant::now();
        a.render(0.0, &mut buf, 64, 64);
        assert!(t.elapsed().as_secs() < 2);
    }

    #[test]
    fn ease_endpoints() {
        assert!((ease((0.33, 0.0), (0.67, 1.0), 0.0)).abs() < 1e-3);
        assert!((ease((0.33, 0.0), (0.67, 1.0), 1.0) - 1.0).abs() < 1e-3);
        assert!((ease((0.0, 0.0), (1.0, 1.0), 0.5) - 0.5).abs() < 1e-2);
    }

    #[test]
    fn simple_animation_renders() {
        let json = br#"{"v":"5.5.2","fr":60,"ip":0,"op":60,"w":100,"h":100,"layers":[{"ty":4,"ind":1,"ip":0,"op":60,"st":0,
          "ks":{"p":{"a":1,"k":[{"t":0,"s":[20,50],"e":[80,50],"i":{"x":[0.5],"y":[1]},"o":{"x":[0.5],"y":[0]}},{"t":60}]},"a":{"k":[0,0]},"s":{"k":[100,100]},"r":{"k":0},"o":{"k":100}},
          "shapes":[{"ty":"gr","it":[{"ty":"el","p":{"k":[0,0]},"s":{"k":[30,30]}},{"ty":"fl","c":{"k":[1,0,0,1]},"o":{"k":100}},{"ty":"tr","p":{"k":[0,0]},"a":{"k":[0,0]},"s":{"k":[100,100]},"r":{"k":0},"o":{"k":100}}]}]}]}"#;
        let a = Animation::parse(json).unwrap();
        assert_eq!(a.frames(), 60);
        let mut buf = vec![0u8; 100 * 100 * 4];
        assert!(a.render(0.0, &mut buf, 100, 100));
        // Khung 0: chấm đỏ ở (20, 50)
        let px = |x: usize, y: usize, buf: &[u8]| buf[(y * 100 + x) * 4];
        assert!(px(20, 50, &buf) > 200);
        assert!(px(80, 50, &buf) == 0);
        a.render(59.0, &mut buf, 100, 100);
        assert!(px(80, 50, &buf) > 200);
    }
}
