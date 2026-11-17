#!/usr/bin/env bash
# Dựng bản phát hành GramMini (không có công cụ thử Debug/, không giữ màn hình sáng) trên máy Ubuntu có Theos + Rust nightly:
#   bash tools/build-release.sh
# → app/packages/vn.grammini.app_<bản>_iphoneos-arm.deb (bản lấy từ app/control — nhớ đổi cả CFBundleShortVersionString trong
#   app/Resources/Info.plist) + app/packages/symlist-<bản>.txt (ký hiệu cần tra trên máy iOS 5 và iOS 6: … | ssh root@<máy> cbsymcheck).
# Cần keys/telegram.txt (api_id / api_hash — không có trên git).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/^Version: *//p' "$ROOT/app/control")"
PLIST="$ROOT/app/Resources/Info.plist"
PLIST_VERSION="$(grep -A1 CFBundleShortVersionString "$PLIST" | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p')"
if [[ "$VERSION" != "$PLIST_VERSION" ]]; then
    echo "Bản trong app/control ($VERSION) khác Info.plist ($PLIST_VERSION)" >&2
    exit 1
fi
if ! grep -A1 GMUpdateURL "$PLIST" | grep -q "https://api.github.com/repos/"; then
    echo "Info.plist chưa đặt GMUpdateURL (nguồn cập nhật OTA)" >&2
    exit 1
fi
(cd "$ROOT/app" && make clean >/dev/null 2>&1 || true)
bash "$ROOT/tools/build-app.sh" FINALPACKAGE=1
cd "$ROOT/app"
BIN=.theos/_/Applications/GramMini.app/GramMini
if strings "$BIN" | grep -q "GramMini-cmd.txt"; then
    echo "LỖI: bản phát hành còn mã thử (Debug/)" >&2
    exit 1
fi
DEB="packages/vn.grammini.app_${VERSION}_iphoneos-arm.deb"
[[ -f "$DEB" ]] || { echo "không thấy $DEB" >&2; ls packages >&2; exit 1; }
python3 "$ROOT/tools/symlist.py" "$BIN" > "packages/symlist-$VERSION.txt"
# Công cụ cài OTA (setuid root — Security / CommonCrypto để kiểm chữ ký): ký hiệu cũng phải có trên iOS 5 / 6
python3 "$ROOT/tools/symlist.py" .theos/_/usr/libexec/grammini/gmupdate >> "packages/symlist-$VERSION.txt"
sort -u -o "packages/symlist-$VERSION.txt" "packages/symlist-$VERSION.txt"
ls -la "$DEB"
sha256sum "$DEB"
echo "Ký hiệu cần tra: app/packages/symlist-$VERSION.txt (… | ssh root@<máy> cbsymcheck)"
