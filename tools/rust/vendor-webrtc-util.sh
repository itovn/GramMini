#!/usr/bin/env bash
# Chép webrtc-util (phụ thuộc của webrtc-dtls — DTLS cho gọi thoại, gm-call) vào vendor/ và bỏ phụ thuộc `nix` 0.26:
# nix chỉ dùng cho tính năng `ifaces` (liệt kê card mạng) mà gm-call / webrtc-dtls đều tắt, nhưng Cargo.toml của webrtc-util
# khai báo nix bắt buộc trên Unix → dựng cho armv7 iOS 6 hỏng (nix 0.26 dùng sockaddr_ctl / AF_SYS_CONTROL — libc chỉ có cho
# Apple 64-bit).
# Dùng: bash tools/rust/vendor-webrtc-util.sh [phiên bản] → $DST/webrtc-util-<bản>; cargo-ios6.sh vá qua [patch.crates-io].
set -euo pipefail
VER="${1:-0.11.0}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$(ls -d "$HOME"/.cargo/registry/src/*/webrtc-util-"$VER" | head -1)"
DST="${VENDOR_DST:-$ROOT/vendor}/webrtc-util-$VER"
[[ -d "$SRC" ]] || { echo "chưa có webrtc-util-$VER trong ~/.cargo/registry — chạy cargo fetch trước"; exit 1; }

rm -rf "$DST"
mkdir -p "$(dirname "$DST")"
cp -r "$SRC" "$DST"
cd "$DST"
python3 - <<'EOF'
p = "Cargo.toml"
s = open(p).read()
block = '[target."cfg(not(windows))".dependencies.nix]\nversion = "0.26.2"\n'
assert block in s, "không thấy khối phụ thuộc nix trong Cargo.toml"
s = s.replace(block, "# GramMini: bỏ nix (chỉ dùng cho tính năng ifaces / vnet — không được bật)\n", 1)
open(p, "w").write(s)
EOF
echo "đã vá $DST"
