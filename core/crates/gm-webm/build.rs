// Dựng libvpx (core/vendor/libvpx — chỉ phần bộ giải mã VP9; armv7: NEON intrinsics, đích khác: C chung; cấu hình lấy từ bản dựng sẵn của Chromium,
// xem vendor/libvpx/README-GramMini.md) + lớp bọc csrc/gm_vpx.c bằng cc. Dựng cho iOS thì cc dùng clang của Theos
// (CC_armv7_apple_ios6 do tools/rust/cargo-ios6.sh đặt).
use std::path::PathBuf;

fn main() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../vendor/libvpx");
    // armv7 (iOS 5 / 6 — mọi máy từ A4 có NEON): bản NEON intrinsics; đích khác (PC): C chung
    let neon = std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("arm");
    let (list, config) = if neon { ("gm-sources-neon.txt", "gm-config-neon") } else { ("gm-sources.txt", "gm-config") };
    let list = root.join(list);
    println!("cargo:rerun-if-changed={}", list.display());
    println!("cargo:rerun-if-changed=csrc/gm_vpx.c");
    let files: Vec<String> = std::fs::read_to_string(&list)
        .expect("đọc gm-sources.txt")
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(str::to_string)
        .collect();
    assert!(files.len() > 40, "danh sách tệp libvpx quá ngắn: {}", files.len());
    let mut b = cc::Build::new();
    for f in &files {
        b.file(root.join(f));
    }
    b.file("csrc/gm_vpx.c")
        .include(root.join(config))
        .include(&root)
        .warnings(false)
        .opt_level(3);
    let target = std::env::var("TARGET").unwrap_or_default();
    if !target.contains("msvc") {
        // Hàm thiếu khai báo (cấu hình rtcd lệch) phải báo lỗi lúc dựng, không để tới lúc chạy
        b.flag("-Werror=implicit-function-declaration");
    }
    b.compile("vpx");
}
