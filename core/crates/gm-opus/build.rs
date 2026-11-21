// Dựng libopus 1.4 (core/vendor/opus-1.4 — bản phát hành chính thức của xiph.org, kiểm SHA-256) bằng cc: danh sách tệp lấy
// từ *_sources.mk (phần C chung — không SIMD). Dựng cho iOS thì cc dùng clang của Theos (CC_armv7_apple_ios6 do
// tools/rust/cargo-ios6.sh đặt). ARM dựng SỐ NGUYÊN (FIXED_POINT, silk/fixed): VFP của Cortex-A8 (A4 — iPad 1, iPhone 4) không
// chạy song song lệnh, bản số thực tốn ~40% một nhân mỗi cuộc gọi (gm-cli callselftest, 21/11/2026). PC giữ số thực.
use std::path::{Path, PathBuf};

/// Đọc biến `NAME = a.c b.c \ …` (nhiều dòng) trong tệp .mk.
fn mk_list(path: &Path, name: &str) -> Vec<String> {
    let text = std::fs::read_to_string(path).expect("đọc .mk");
    let mut out = Vec::new();
    let mut on = false;
    for line in text.lines() {
        let l = line.trim();
        if !on {
            if let Some(rest) = l.strip_prefix(&format!("{name} =")) {
                on = true;
                out.extend(rest.split_whitespace().filter(|t| *t != "\\").map(str::to_string));
                if !l.ends_with('\\') {
                    break;
                }
            }
            continue;
        }
        out.extend(l.split_whitespace().filter(|t| *t != "\\").map(str::to_string));
        if !l.ends_with('\\') {
            break;
        }
    }
    out
}

fn main() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../vendor/opus-1.4");
    let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    let fixed = arch == "arm" || arch == "aarch64";
    let silk = if fixed { "SILK_SOURCES_FIXED" } else { "SILK_SOURCES_FLOAT" };
    let mut files = Vec::new();
    for (mk, vars) in [
        ("celt_sources.mk", &["CELT_SOURCES"][..]),
        ("silk_sources.mk", &["SILK_SOURCES", silk][..]),
        ("opus_sources.mk", &["OPUS_SOURCES", "OPUS_SOURCES_FLOAT"][..]),
    ] {
        println!("cargo:rerun-if-changed={}", root.join(mk).display());
        for v in vars {
            files.extend(mk_list(&root.join(mk), v));
        }
    }
    assert!(files.len() > 100, "danh sách tệp libopus quá ngắn: {}", files.len());
    let mut b = cc::Build::new();
    for f in &files {
        b.file(root.join(f));
    }
    b.include(root.join("include"))
        .include(root.join("celt"))
        .include(root.join("silk"))
        .include(root.join(if fixed { "silk/fixed" } else { "silk/float" }))
        .include(root.join("src"))
        .define("OPUS_BUILD", None)
        .define("USE_ALLOCA", None)
        .define("HAVE_LRINTF", None)
        .define("HAVE_LRINT", None)
        .warnings(false)
        .opt_level(2);
    if fixed {
        b.define("FIXED_POINT", "1");
    }
    if !std::env::var("TARGET").unwrap_or_default().contains("windows") {
        b.define("HAVE_ALLOCA_H", None);
    }
    b.compile("opus");
}
