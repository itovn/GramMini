//! Đọc rãnh video H.265 trong MP4 / MOV (ISO BMFF): hộp `moov` → `trak` (`tkhd` ma trận xoay, `mdia/mdhd` thang thời gian,
//! `hdlr` loại rãnh, `minf/stbl` bảng mẫu: `stsd` (hvc1 / hev1 + hvcC), `stts`, `ctts`, `stsc`, `stsz`, `stco` / `co64`,
//! `stss`). Chỉ MP4 thường (không phân mảnh `moof`). Không panic: mọi chỗ đọc đều kiểm giới hạn.
use std::io::{Read, Seek, SeekFrom};

/// Giới hạn: số mẫu (khung), cỡ hộp `moov`, cỡ một mẫu.
const MAX_SAMPLES: usize = 500_000;
const MAX_MOOV: u64 = 64 << 20;
pub const MAX_SAMPLE: u32 = 32 << 20;

#[derive(Clone, Copy, Debug)]
pub struct Sample {
    pub offset: u64,
    pub size: u32,
    pub dts: i64,
    pub pts: i64,
    pub key: bool,
}

#[derive(Debug)]
pub struct Track {
    /// `hvc1` / `hev1`.
    pub codec: [u8; 4],
    /// Nội dung hộp hvcC (extradata cho FFmpeg).
    pub hvcc: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub timescale: u32,
    pub duration: i64,
    /// Ma trận xoay của `tkhd` (a, b, c, d) — video quay dọc trên điện thoại lưu nằm ngang + xoay 90°.
    pub matrix: [f64; 4],
    pub samples: Vec<Sample>,
}

fn be16(d: &[u8], i: usize) -> Option<u16> {
    Some(u16::from_be_bytes([*d.get(i)?, *d.get(i + 1)?]))
}

fn be32(d: &[u8], i: usize) -> Option<u32> {
    Some(u32::from_be_bytes(d.get(i..i + 4)?.try_into().ok()?))
}

fn be64(d: &[u8], i: usize) -> Option<u64> {
    Some(u64::from_be_bytes(d.get(i..i + 8)?.try_into().ok()?))
}

/// Các hộp con trong `d`: (loại, nội dung).
fn boxes(d: &[u8]) -> Vec<([u8; 4], &[u8])> {
    let mut out = Vec::new();
    let mut i = 0usize;
    while i + 8 <= d.len() {
        let Some(size32) = be32(d, i) else { break };
        let kind = [d[i + 4], d[i + 5], d[i + 6], d[i + 7]];
        let (size, hdr) = match size32 {
            1 => match be64(d, i + 8) {
                Some(s) => (s, 16u64),
                None => break,
            },
            0 => ((d.len() - i) as u64, 8),
            s => (s as u64, 8),
        };
        let Some(end) = (i as u64).checked_add(size).filter(|e| *e <= d.len() as u64 && size >= hdr) else { break };
        out.push((kind, &d[i + hdr as usize..end as usize]));
        i = end as usize;
    }
    out
}

fn child<'a>(d: &'a [u8], kind: &[u8; 4]) -> Option<&'a [u8]> {
    boxes(d).into_iter().find(|(k, _)| k == kind).map(|(_, p)| p)
}

/// Đọc hộp `moov` của tệp (lần theo các hộp cấp đầu, không đọc cả tệp).
fn read_moov<F: Read + Seek>(f: &mut F) -> Result<Vec<u8>, String> {
    let len = f.seek(SeekFrom::End(0)).map_err(|e| e.to_string())?;
    let mut pos = 0u64;
    while pos + 8 <= len {
        let mut h = [0u8; 16];
        f.seek(SeekFrom::Start(pos)).map_err(|e| e.to_string())?;
        f.read_exact(&mut h[..8]).map_err(|e| e.to_string())?;
        let (mut size, mut hdr) = (u32::from_be_bytes([h[0], h[1], h[2], h[3]]) as u64, 8u64);
        if size == 1 {
            f.read_exact(&mut h[8..16]).map_err(|e| e.to_string())?;
            size = u64::from_be_bytes([h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]]);
            hdr = 16;
        } else if size == 0 {
            size = len - pos;
        }
        if size < hdr {
            return Err("tệp MP4 hỏng".into());
        }
        if &h[4..8] == b"moov" {
            if size - hdr > MAX_MOOV {
                return Err("hộp moov quá lớn".into());
            }
            let mut buf = vec![0u8; (size - hdr) as usize];
            f.read_exact(&mut buf).map_err(|e| e.to_string())?;
            return Ok(buf);
        }
        pos = pos.saturating_add(size);
    }
    Err("không thấy hộp moov (MP4 phân mảnh / hỏng)".into())
}

/// Rãnh video H.265 đầu tiên của tệp.
pub fn video_track<F: Read + Seek>(f: &mut F) -> Result<Track, String> {
    let moov = read_moov(f)?;
    let mut other = None;
    for (k, trak) in boxes(&moov) {
        if &k != b"trak" {
            continue;
        }
        match parse_trak(trak) {
            Ok(Some(t)) => return Ok(t),
            Ok(None) => {}
            Err(e) => other = Some(e),
        }
    }
    Err(other.unwrap_or_else(|| "không có rãnh video H.265".into()))
}

/// Ok(None): không phải rãnh video H.265.
fn parse_trak(trak: &[u8]) -> Result<Option<Track>, String> {
    let bad = || "bảng mẫu MP4 hỏng".to_string();
    let mdia = child(trak, b"mdia").ok_or_else(bad)?;
    let hdlr = child(mdia, b"hdlr").ok_or_else(bad)?;
    if hdlr.get(8..12) != Some(b"vide") {
        return Ok(None);
    }
    let stbl = child(mdia, b"minf").and_then(|m| child(m, b"stbl")).ok_or_else(bad)?;
    // stsd: mục đầu tiên phải là hvc1 / hev1
    let stsd = child(stbl, b"stsd").ok_or_else(bad)?;
    let entries = boxes(stsd.get(8..).ok_or_else(bad)?);
    let Some((codec, entry)) = entries.first().copied() else { return Ok(None) };
    if &codec != b"hvc1" && &codec != b"hev1" {
        return Ok(None);
    }
    let width = be16(entry, 24).ok_or_else(bad)? as u32;
    let height = be16(entry, 26).ok_or_else(bad)? as u32;
    let hvcc = child(entry.get(78..).ok_or_else(bad)?, b"hvcC").ok_or("thiếu hộp hvcC")?.to_vec();
    // mdhd: thang thời gian + thời lượng
    let mdhd = child(mdia, b"mdhd").ok_or_else(bad)?;
    let (timescale, duration) = if mdhd.first() == Some(&1) {
        (be32(mdhd, 20).ok_or_else(bad)?, be64(mdhd, 24).ok_or_else(bad)? as i64)
    } else {
        (be32(mdhd, 12).ok_or_else(bad)?, be32(mdhd, 16).ok_or_else(bad)? as i64)
    };
    if timescale == 0 {
        return Err(bad());
    }
    // tkhd: ma trận (9 số, a b u / c d v / x y w — a, b, c, d dạng 16.16)
    let matrix = child(trak, b"tkhd")
        .and_then(|t| {
            let m = if t.first() == Some(&1) { 52 } else { 40 };
            let fx = |i: usize| be32(t, m + i * 4).map(|v| v as i32 as f64 / 65536.0);
            Some([fx(0)?, fx(1)?, fx(3)?, fx(4)?])
        })
        .unwrap_or([1.0, 0.0, 0.0, 1.0]);
    let samples = sample_table(stbl).ok_or_else(bad)?;
    Ok(Some(Track { codec, hvcc, width, height, timescale, duration, matrix, samples }))
}

/// Bảng mẫu: vị trí, cỡ, dts / pts, khung khoá.
fn sample_table(stbl: &[u8]) -> Option<Vec<Sample>> {
    // stsz: cỡ từng mẫu
    let stsz = child(stbl, b"stsz")?;
    let fixed = be32(stsz, 4)?;
    let n = be32(stsz, 8)? as usize;
    if n == 0 || n > MAX_SAMPLES {
        return None;
    }
    let sizes: Vec<u32> = if fixed != 0 { vec![fixed; n] } else { (0..n).map(|i| be32(stsz, 12 + i * 4)).collect::<Option<_>>()? };
    // stco / co64: vị trí từng khúc
    let chunks: Vec<u64> = if let Some(c) = child(stbl, b"stco") {
        let k = be32(c, 4)? as usize;
        (0..k.min(MAX_SAMPLES)).map(|i| be32(c, 8 + i * 4).map(u64::from)).collect::<Option<_>>()?
    } else {
        let c = child(stbl, b"co64")?;
        let k = be32(c, 4)? as usize;
        (0..k.min(MAX_SAMPLES)).map(|i| be64(c, 8 + i * 8)).collect::<Option<_>>()?
    };
    // stsc: số mẫu mỗi khúc (theo đoạn)
    let stsc = child(stbl, b"stsc")?;
    let runs: Vec<(u32, u32)> =
        (0..(be32(stsc, 4)? as usize).min(MAX_SAMPLES)).map(|i| Some((be32(stsc, 8 + i * 12)?, be32(stsc, 12 + i * 12)?))).collect::<Option<_>>()?;
    let mut out = Vec::with_capacity(n);
    let mut s = 0usize;
    // Các đoạn stsc xếp theo khúc đầu tăng dần → đi một lượt (bản trước dò lại cả danh sách cho từng khúc: tệp lạ 500k khúc ×
    // 500k đoạn treo luồng chuyển mã hàng phút — kiểm bảo mật 17/11/2026)
    let (mut ri, mut per) = (0usize, 0u32);
    for (ci, &base) in chunks.iter().enumerate() {
        if s >= n {
            break;
        }
        let chunk_no = ci as u32 + 1;
        while ri < runs.len() && runs[ri].0 <= chunk_no {
            per = runs[ri].1;
            ri += 1;
        }
        let mut off = base;
        for _ in 0..per {
            if s >= n {
                break;
            }
            out.push(Sample { offset: off, size: sizes[s], dts: 0, pts: 0, key: true });
            off = off.checked_add(u64::from(sizes[s]))?;
            s += 1;
        }
    }
    if out.len() != n {
        return None;
    }
    // stts: thời lượng từng mẫu → dts
    let stts = child(stbl, b"stts")?;
    let mut t = 0i64;
    let mut s = 0usize;
    for i in 0..be32(stts, 4)? as usize {
        let (count, delta) = (be32(stts, 8 + i * 8)?, be32(stts, 12 + i * 8)?);
        for _ in 0..count {
            if s >= n {
                break;
            }
            out[s].dts = t;
            out[s].pts = t;
            t = t.checked_add(delta as i64)?;
            s += 1;
        }
    }
    // ctts: lệch thời điểm trình chiếu (khung B)
    if let Some(ctts) = child(stbl, b"ctts") {
        let mut s = 0usize;
        for i in 0..(be32(ctts, 4)? as usize).min(MAX_SAMPLES) {
            let (count, off) = (be32(ctts, 8 + i * 8)?, be32(ctts, 12 + i * 8)? as i32 as i64);
            for _ in 0..count {
                if s >= n {
                    break;
                }
                out[s].pts = out[s].dts + off;
                s += 1;
            }
        }
    }
    // stss: khung khoá (không có = mọi khung là khung khoá)
    if let Some(stss) = child(stbl, b"stss") {
        out.iter_mut().for_each(|x| x.key = false);
        for i in 0..(be32(stss, 4)? as usize).min(MAX_SAMPLES) {
            let k = be32(stss, 8 + i * 4)? as usize;
            if let Some(x) = k.checked_sub(1).and_then(|k| out.get_mut(k)) {
                x.key = true;
            }
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bx(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut v = ((payload.len() + 8) as u32).to_be_bytes().to_vec();
        v.extend_from_slice(kind);
        v.extend_from_slice(payload);
        v
    }

    fn full(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut p = vec![0u8; 4];
        p.extend_from_slice(body);
        bx(kind, &p)
    }

    fn words(v: &[u32]) -> Vec<u8> {
        v.iter().flat_map(|x| x.to_be_bytes()).collect()
    }

    #[test]
    fn reads_sample_table() {
        // 4 mẫu, 2 khúc (2 + 2), stts 100 mỗi mẫu, ctts lệch 200 cho mẫu 2, khung khoá: mẫu 1
        let stbl = [
            full(b"stsz", &words(&[0, 4, 10, 20, 30, 40])),
            full(b"stco", &words(&[2, 1000, 5000])),
            full(b"stsc", &words(&[1, 1, 2, 1])),
            full(b"stts", &words(&[1, 4, 100])),
            full(b"ctts", &words(&[2, 1, 0, 1, 200])),
            full(b"stss", &words(&[1, 1])),
        ]
        .concat();
        let s = sample_table(&stbl).unwrap();
        assert_eq!(s.len(), 4);
        assert_eq!((s[0].offset, s[1].offset, s[2].offset, s[3].offset), (1000, 1010, 5000, 5030));
        assert_eq!((s[1].dts, s[1].pts, s[2].pts), (100, 300, 200));
        assert!(s[0].key && !s[1].key);
    }

    #[test]
    fn rejects_garbage() {
        let mut c = std::io::Cursor::new(vec![0u8, 0, 0, 3, b'a', b'b', b'c', b'd']);
        assert!(video_track(&mut c).is_err());
        assert!(sample_table(&[1, 2, 3]).is_none());
    }
}
