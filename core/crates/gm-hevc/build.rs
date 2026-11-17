// Dựng phần FFmpeg cần cho bộ giải mã HEVC (core/vendor/ffmpeg — cấu hình tự sinh bởi tools/ffmpeg/vendor-ffmpeg.py, xem
// vendor/ffmpeg/README-GramMini.md) + lớp bọc csrc/gm_hevc.c bằng cc. armv7 (iOS 5 / 6): thêm mã hợp ngữ NEON của FFmpeg;
// đích khác: C thuần. MSVC (dựng thử trên Windows): FFmpeg không dựng được → bản rỗng (`gm_hevc_stub`, mở video báo lỗi).
use std::path::PathBuf;

fn main() {
    println!("cargo::rustc-check-cfg=cfg(gm_hevc_stub)");
    println!("cargo:rerun-if-changed=csrc/gm_hevc.c");
    let target = std::env::var("TARGET").unwrap_or_default();
    if target.contains("msvc") {
        println!("cargo:rustc-cfg=gm_hevc_stub");
        return;
    }
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../vendor/ffmpeg");
    let arm = std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("arm");
    let (list, config) = if arm { ("gm-sources-arm.txt", "gm-config-arm") } else { ("gm-sources.txt", "gm-config") };
    let list = root.join(list);
    println!("cargo:rerun-if-changed={}", list.display());
    let files: Vec<String> = std::fs::read_to_string(&list)
        .expect("đọc danh sách tệp FFmpeg")
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(str::to_string)
        .collect();
    assert!(files.len() > 60, "danh sách tệp FFmpeg quá ngắn: {}", files.len());
    let mut b = cc::Build::new();
    for f in &files {
        b.file(root.join(f));
    }
    b.file("csrc/gm_hevc.c")
        .include(root.join(config))
        .include(&root)
        .include(root.join("libavcodec"))
        .define("HAVE_AV_CONFIG_H", None)
        .define("_ISOC99_SOURCE", None)
        .define("_FILE_OFFSET_BITS", "64")
        .define("_LARGEFILE_SOURCE", None)
        .warnings(false)
        // FFmpeg dựa vào trình dịch bỏ nhánh `if (CONFIG_X)` = 0 → luôn tối ưu, kể cả bản debug
        .opt_level(3)
        .flag("-std=c11")
        // Hàm thiếu khai báo (cấu hình lệch: libm, hàm hệ thống) phải báo lỗi lúc dựng, không để tới lúc chạy
        .flag("-Werror=implicit-function-declaration");
    if !arm && target.contains("linux") {
        b.define("_POSIX_C_SOURCE", "200112").define("_XOPEN_SOURCE", "600");
    }
    b.compile("ffhevc");
}
