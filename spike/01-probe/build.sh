#!/usr/bin/env bash
# Dựng gm-probe cho iOS 5 / 6 trên máy Ubuntu có Theos + Rust nightly (rust-src):
# lõi Rust (crate gm-cli) → thư viện tĩnh armv7 → nối với main.c + app/Core/GMShims.c bằng clang của Theos → ký ldid (SHA-1).
#   bash spike/01-probe/build.sh            → <thư mục dựng>/gm-probe   (mặc định ../target-ios cạnh repo)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
THEOS="${THEOS:-$HOME/theos}"
TC="$THEOS/toolchain/linux/iphone/bin"
SDK="$THEOS/sdks/iPhoneOS9.3.sdk"
OUT="${CARGO_TARGET_DIR:-$(cd "$ROOT/.." && pwd)/target-ios}"
cd "$ROOT/core"
CARGO_TARGET_DIR="$OUT" bash "$ROOT/tools/rust/cargo-ios6.sh" rustc --release -p gm-cli --lib --crate-type staticlib
LIB="$OUT/armv7-apple-ios6/release/libgm_cli.a"
# Dựng cho iOS 5.0: ld64 dùng LC_UNIXTHREAD + crt1.3.1.o — chạy cả iOS 5 và 6
"$TC/clang" -target armv7-apple-ios5.0 -isysroot "$SDK" -mcpu=cortex-a8 -O2 -Wall \
    "$ROOT/spike/01-probe/main.c" "$ROOT/app/Core/GMShims.c" "$LIB" \
    -framework CoreFoundation -framework Security -Wl,-dead_strip -o "$OUT/gm-probe"
"$TC/ldid" -S -Hsha1 "$OUT/gm-probe"
ls -la "$LIB" "$OUT/gm-probe"
