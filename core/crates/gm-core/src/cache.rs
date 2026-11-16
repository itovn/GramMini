//! Bộ nhớ đệm media (`media/`, `avatars/`, `tmp/` trong thư mục dữ liệu): thống kê theo loại / theo chat, xoá, tự dọn.
//!
//! Tự dọn kiểu Telegram:
//! - tệp không dùng lại quá hạn giữ (`keep`) thì xoá;
//! - tổng vượt giới hạn (`limit`) thì xoá tệp lâu không dùng nhất trước, tới 90 % giới hạn — tệp mới «ghi đè» chỗ tệp cũ;
//! - máy sắp đầy (còn < 300 MB) thì xoá tiếp (cũ trước) tới khi máy còn ≥ 500 MB hoặc hết đệm;
//! - tệp tạm (tải dở, ghi âm, ảnh chờ gửi) quá 1 giờ thì xoá.
//!
//! «Lần dùng cuối» = thời điểm sửa của tệp: lõi / app gọi [`touch`] mỗi lần dùng lại tệp đã có. Phiên, cài đặt, nhật ký nằm
//! ngoài các thư mục trên → không bao giờ bị xoá.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime};

const DIRS: [&str; 3] = ["media", "avatars", "tmp"];
/// Tệp vừa dùng / đang ghi trong khoảng này không tự xoá (đang xem, đang tải, đang ghi âm).
const PROTECT: Duration = Duration::from_secs(10 * 60);
/// Tệp tạm quá chừng này thì xoá.
const TEMP_AGE: Duration = Duration::from_secs(3600);
/// Máy còn ít hơn chừng này thì dọn đệm…
const LOW_FREE: u64 = 300 << 20;
/// …tới khi còn chừng này.
const FREE_TARGET: u64 = 500 << 20;
/// Hai lượt tự dọn cách nhau ít nhất chừng này (mỗi lượt quét thư mục).
const TRIM_GAP: Duration = Duration::from_secs(60);

/// Các loại tệp đệm (thứ tự hiện trên màn «Dữ liệu và bộ nhớ»).
pub const KINDS: [&str; 8] = ["photo", "video", "file", "music", "voice", "sticker", "avatar", "other"];

/// Chính sách tự dọn.
#[derive(Clone, Copy, Debug)]
pub struct Policy {
    /// Giới hạn tổng dung lượng, MB (0 = không giới hạn).
    pub limit_mb: u64,
    /// Hạn giữ tệp không dùng lại, ngày (0 = mãi mãi).
    pub keep_days: u64,
}

impl Default for Policy {
    fn default() -> Self {
        Policy { limit_mb: 1024, keep_days: 30 }
    }
}

/// Một tệp trong bộ nhớ đệm.
pub struct Entry {
    pub path: PathBuf,
    pub size: u64,
    /// Lần dùng cuối (thời điểm sửa).
    pub used: SystemTime,
    pub kind: &'static str,
    /// Khoá peer của chat chứa tệp (ảnh đại diện: peer chủ ảnh).
    pub peer: Option<String>,
    /// Tệp tạm: tải dở, bản gốc chờ chuyển đổi, tệp trong `tmp/`.
    pub temp: bool,
}

/// Loại + peer theo tên tệp (xem cách đặt tên trong `service.rs`: `p<peer>_<id>_<m|y>.jpg`, `t…`, `s…`, `v…`, `d…`).
fn classify(dir: &str, name: &str) -> (&'static str, Option<String>, bool) {
    match dir {
        "avatars" => ("avatar", name.split_once('_').map(|(p, _)| p.to_string()), name.ends_with(".part")),
        "media" => {
            let peer = name.get(1..).and_then(|r| r.split_once('_')).map(|(p, _)| p.to_string());
            let ext = name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
            let first = name.as_bytes().first().copied();
            let temp = ext == "part" || (matches!(first, Some(b's') | Some(b'k')) && ext == "bin") || (first == Some(b'v') && ext == "ogg");
            let kind = match first {
                Some(b'p') | Some(b't') => "photo",
                Some(b's') | Some(b'k') => "sticker",
                Some(b'v') => "voice",
                Some(b'd') => match ext.as_str() {
                    "mp4" | "mov" | "m4v" | "3gp" | "webm" | "mkv" | "avi" | "gif" => "video",
                    "mp3" | "m4a" | "aac" | "ogg" | "oga" | "opus" | "flac" | "wav" => "music",
                    _ => "file",
                },
                _ => "other",
            };
            (kind, peer, temp)
        }
        _ => ("other", None, true),
    }
}

/// Quét toàn bộ tệp đệm.
pub fn scan(data_dir: &Path) -> Vec<Entry> {
    let mut v = Vec::new();
    for dir in DIRS {
        let Ok(rd) = std::fs::read_dir(data_dir.join(dir)) else { continue };
        for e in rd.flatten() {
            // std::fs::metadata (stat), không dùng DirEntry::metadata: std gọi fstatat — chỉ có từ iOS 8
            let Ok(md) = std::fs::metadata(e.path()) else { continue };
            if !md.is_file() {
                continue;
            }
            let name = e.file_name().to_string_lossy().into_owned();
            let (kind, peer, temp) = classify(dir, &name);
            let used = md.modified().unwrap_or(SystemTime::UNIX_EPOCH);
            v.push(Entry { path: e.path(), size: md.len(), used, kind, peer, temp });
        }
    }
    v
}

fn age(now: SystemTime, e: &Entry) -> Duration {
    now.duration_since(e.used).unwrap_or_default()
}

/// Xoá tệp đệm khớp điều kiện (`kinds` rỗng / None = mọi loại, `peer` = chỉ chat đó). Bỏ qua tệp tạm vừa ghi chưa tới 2 phút
/// (đang tải, đang ghi âm). Trả (byte đã xoá, số tệp).
pub fn clear(data_dir: &Path, kinds: Option<&[String]>, peer: Option<&str>) -> (u64, usize) {
    let now = SystemTime::now();
    let (mut freed, mut n) = (0, 0);
    for e in scan(data_dir) {
        if let Some(k) = kinds.filter(|k| !k.is_empty()) {
            if !k.iter().any(|x| x == e.kind) {
                continue;
            }
        }
        if peer.is_some() && e.peer.as_deref() != peer {
            continue;
        }
        if e.temp && age(now, &e) < Duration::from_secs(120) {
            continue;
        }
        if std::fs::remove_file(&e.path).is_ok() {
            freed += e.size;
            n += 1;
        }
    }
    (freed, n)
}

/// Kết quả một lượt tự dọn.
#[derive(Debug, Default)]
pub struct Trimmed {
    pub freed: u64,
    pub files: usize,
    /// Tổng còn lại.
    pub total: u64,
}

/// Tự dọn theo chính sách (xem đầu tệp). Chạy ở luồng blocking.
pub fn trim(data_dir: &Path, p: Policy) -> Trimmed {
    let now = SystemTime::now();
    let keep = (p.keep_days > 0).then(|| Duration::from_secs(p.keep_days * 86400));
    let mut r = Trimmed::default();
    let mut rest = Vec::new();
    for e in scan(data_dir) {
        let a = age(now, &e);
        let stale = (e.temp && a > TEMP_AGE) || (keep.is_some_and(|k| a > k) && a > PROTECT);
        if stale && std::fs::remove_file(&e.path).is_ok() {
            r.freed += e.size;
            r.files += 1;
        } else {
            rest.push(e);
        }
    }
    r.total = rest.iter().map(|e| e.size).sum();
    let limit = p.limit_mb << 20;
    let mut target = if limit > 0 && r.total > limit { limit / 10 * 9 } else { r.total };
    if let Some((free, _)) = disk_space(data_dir) {
        if free < LOW_FREE {
            target = target.min(r.total.saturating_sub(FREE_TARGET - free));
        }
    }
    if r.total > target {
        rest.sort_by_key(|e| e.used);
        for e in &rest {
            if r.total <= target {
                break;
            }
            if age(now, e) < PROTECT {
                continue;
            }
            if std::fs::remove_file(&e.path).is_ok() {
                r.total -= e.size;
                r.freed += e.size;
                r.files += 1;
            }
        }
    }
    r
}

/// Đánh dấu vừa dùng (đổi thời điểm sửa thành bây giờ) — chỉ khi lần đánh dấu trước đã quá 1 giờ, đỡ ghi đĩa.
pub fn touch(path: &Path) {
    let Ok(md) = std::fs::metadata(path) else { return };
    let old = md
        .modified()
        .ok()
        .and_then(|m| SystemTime::now().duration_since(m).ok())
        .is_none_or(|a| a > Duration::from_secs(3600));
    if !old {
        return;
    }
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        if let Ok(c) = std::ffi::CString::new(path.as_os_str().as_bytes()) {
            // utimes(…, NULL) = bây giờ; có từ thuở đầu iOS (File::set_modified của std dùng fsetattrlist)
            unsafe { libc::utimes(c.as_ptr(), std::ptr::null()) };
        }
    }
    #[cfg(not(unix))]
    if let Ok(f) = std::fs::OpenOptions::new().write(true).open(path) {
        let _ = f.set_modified(SystemTime::now());
    }
}

/// (còn trống, tổng) của phân vùng chứa `dir`, byte.
pub fn disk_space(dir: &Path) -> Option<(u64, u64)> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        let c = std::ffi::CString::new(dir.as_os_str().as_bytes()).ok()?;
        let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
        if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
            return None;
        }
        let bs = st.f_frsize as u64;
        Some((st.f_bavail as u64 * bs, st.f_blocks as u64 * bs))
    }
    #[cfg(not(unix))]
    {
        let _ = dir;
        None
    }
}

/// Trạng thái tự dọn của lõi: chính sách hiện hành, đang dọn hay không, lần dọn trước.
pub struct Cache {
    policy: Mutex<Policy>,
    busy: AtomicBool,
    last: Mutex<Option<Instant>>,
}

impl Cache {
    pub fn new(policy: Policy) -> Cache {
        Cache { policy: Mutex::new(policy), busy: AtomicBool::new(false), last: Mutex::new(None) }
    }

    pub fn policy(&self) -> Policy {
        *self.policy.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn set_policy(&self, p: Policy) {
        *self.policy.lock().unwrap_or_else(|e| e.into_inner()) = p;
    }

    /// Có tệp đã tải ở `path` không (có thì đánh dấu vừa dùng).
    pub fn hit(&self, path: &Path) -> bool {
        if path.exists() {
            touch(path);
            true
        } else {
            false
        }
    }

    /// Giành lượt dọn: false nếu đang dọn, hoặc (khi không `force`) vừa dọn chưa tới 1 phút.
    pub fn begin(&self, force: bool) -> bool {
        let mut last = self.last.lock().unwrap_or_else(|e| e.into_inner());
        if !force && last.is_some_and(|t| t.elapsed() < TRIM_GAP) {
            return false;
        }
        if self.busy.swap(true, Ordering::AcqRel) {
            return false;
        }
        *last = Some(Instant::now());
        true
    }

    pub fn end(&self) {
        self.busy.store(false, Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn put(dir: &Path, sub: &str, name: &str, size: usize, age_secs: u64) -> PathBuf {
        let d = dir.join(sub);
        std::fs::create_dir_all(&d).unwrap();
        let p = d.join(name);
        std::fs::write(&p, vec![0u8; size]).unwrap();
        let f = std::fs::OpenOptions::new().write(true).open(&p).unwrap();
        f.set_modified(SystemTime::now() - Duration::from_secs(age_secs)).unwrap();
        p
    }

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("gm-cache-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    #[test]
    fn classify_names() {
        assert_eq!(classify("media", "p123_5_m.jpg"), ("photo", Some("123".into()), false));
        assert_eq!(classify("media", "d-1001_7.mp4"), ("video", Some("-1001".into()), false));
        assert_eq!(classify("media", "d-1001_7.bin"), ("file", Some("-1001".into()), false));
        assert_eq!(classify("media", "s9_1.bin"), ("sticker", Some("9".into()), true));
        assert_eq!(classify("media", "v9_1.ogg"), ("voice", Some("9".into()), true));
        assert_eq!(classify("media", "d9_1.ogg"), ("music", Some("9".into()), false));
        assert_eq!(classify("media", "d9_1.part"), ("file", Some("9".into()), true));
        assert_eq!(classify("avatars", "42_777.jpg"), ("avatar", Some("42".into()), false));
        assert_eq!(classify("tmp", "rec.wav"), ("other", None, true));
    }

    #[test]
    fn trim_lru_and_keep() {
        let d = tmpdir("trim");
        let old = put(&d, "media", "p1_1_m.jpg", 600 << 10, 40 * 86400); // quá hạn giữ 30 ngày
        let a = put(&d, "media", "p1_2_m.jpg", 600 << 10, 5 * 86400); // cũ nhất còn hạn
        let b = put(&d, "media", "p1_3_m.jpg", 600 << 10, 3 * 86400);
        let c = put(&d, "media", "p1_4_m.jpg", 600 << 10, 60); // vừa dùng: được bảo vệ
        let part = put(&d, "media", "d1_9.part", 100, 2 * 3600); // tệp tạm cũ
        // Giới hạn 1 MB: còn 3 × 600 KB > 1 MB → xoá cũ nhất (a, rồi b) tới ≤ 0,9 MB; c được bảo vệ
        let r = trim(&d, Policy { limit_mb: 1, keep_days: 30 });
        assert!(!old.exists() && !part.exists());
        assert!(!a.exists() && !b.exists() && c.exists(), "{r:?}");
        assert_eq!(r.total, 600 << 10);
        assert_eq!(r.files, 4);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn clear_by_kind_and_peer() {
        let d = tmpdir("clear");
        let p = put(&d, "media", "p1_1_m.jpg", 10, 100);
        let v = put(&d, "media", "d2_1.mp4", 20, 100);
        let av = put(&d, "avatars", "1_5.jpg", 30, 100);
        let rec = put(&d, "tmp", "rec.wav", 40, 5); // đang ghi âm: giữ
        assert_eq!(clear(&d, Some(&["video".into()]), None), (20, 1));
        assert!(p.exists() && !v.exists());
        assert_eq!(clear(&d, None, Some("1")), (40, 2));
        assert!(!p.exists() && !av.exists() && rec.exists());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn touch_refreshes_old_only() {
        let d = tmpdir("touch");
        let f = put(&d, "media", "p1_1_m.jpg", 1, 7200);
        touch(&f);
        let a = SystemTime::now().duration_since(std::fs::metadata(&f).unwrap().modified().unwrap()).unwrap_or_default();
        assert!(a < Duration::from_secs(60));
        let _ = std::fs::remove_dir_all(&d);
    }
}
