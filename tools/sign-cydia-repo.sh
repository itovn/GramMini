#!/usr/bin/env bash
# Ký nguồn Cydia sau update-cydia-repo.sh: <thư mục cydia>/Release → Release.gpg (chữ ký tách, ASCII — apt 0.7.25 của Cydia
# iOS 5 / 6 đọc tệp này) + InRelease (ký lồng — apt mới / Sileo / Zebra). Chạy trên máy phát hành (PC của anh):
#   bash tools/sign-cydia-repo.sh <thư mục trang>/cydia
# Khoá riêng: keys/cydia-gnupg (GNUPGHOME riêng, không đụng khoá GPG cá nhân; /keys/ nằm trong .gitignore). Khoá công khai đi
# kèm gói app (app/layout/etc/apt/trusted.gpg.d/vn.grammini.gpg — apt tin khoá này) và đặt ở <cydia>/vn.grammini.gpg.
# Mất khoá riêng: tạo khoá mới, phát hành bản app mang khoá mới — máy chưa cập nhật sẽ thấy cảnh báo GPG khi làm mới Cydia.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:?cách dùng: sign-cydia-repo.sh <thư mục cydia>}"
export GNUPGHOME="$ROOT/keys/cydia-gnupg"
[[ -d "$GNUPGHOME" ]] || { echo "thiếu keys/cydia-gnupg" >&2; exit 1; }
FPR="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')"
[[ -n "$FPR" ]] || { echo "keys/cydia-gnupg không có khoá riêng" >&2; exit 1; }
# Khoá công khai gắn trong app phải đúng khoá đang ký
PUB="$(mktemp)"
trap 'rm -f "$PUB"' EXIT
gpg --export "$FPR" > "$PUB"
cmp -s "$PUB" "$ROOT/app/layout/etc/apt/trusted.gpg.d/vn.grammini.gpg" || { echo "khoá trong app/layout khác khoá ký" >&2; exit 1; }
cp "$PUB" "$DIR/vn.grammini.gpg"
gpg --batch --yes --local-user "$FPR" --digest-algo SHA256 --armor --detach-sign -o "$DIR/Release.gpg" "$DIR/Release"
gpg --batch --yes --local-user "$FPR" --digest-algo SHA256 --clearsign -o "$DIR/InRelease" "$DIR/Release"
gpg --verify "$DIR/Release.gpg" "$DIR/Release"
ls -la "$DIR/Release" "$DIR/Release.gpg" "$DIR/InRelease" "$DIR/vn.grammini.gpg"
