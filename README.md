# GramMini

App nhắn tin Telegram **không chính thức** cho **iPhone / iPad chạy iOS 5 và iOS 6 đã jailbreak**: giao diện kiểu iOS 6 kết hợp
hiệu ứng kính trong, lõi **Rust** nói chuyện thẳng với máy chủ Telegram bằng MTProto (thư viện
[grammers](https://codeberg.org/Lonami/grammers)), vỏ **Objective-C / UIKit** dựng bằng Theos. Không cần server riêng — phiên
đăng nhập chỉ nằm trên máy. Một gói `.deb` chạy cả iOS 5 và 6, cài qua Cydia, tự cập nhật (OTA).

> GramMini dùng Telegram API nhưng **không phải** sản phẩm của Telegram.

**Nhóm Telegram:** [t.me/tivikit](https://t.me/tivikit) — hỏi đáp, báo lỗi, bản mới.

## Máy chạy được

iOS 5.0 – 6.1.x, đã jailbreak (cần MobileSubstrate): iPhone 4 / 4S / 5, iPad 1 / 2 / 3 / 4 / mini 1, iPod touch 4 / 5.
Đã thử trên iPhone 5 (iOS 6.1.4), iPad mini 1 (iOS 6.1.3), iPad 1 (iOS 5.1.1).

## Có gì

- Chat riêng / nhóm / kênh: tin chữ, trả lời, chuyển tiếp, sửa, xoá, ảnh, video (tự nén), tệp từ bộ nhớ máy, tin thoại, sticker,
  GIF; lưu ảnh / video vào máy; hàng chờ gửi khi mất mạng.
- Thư mục chat (đồng bộ với tài khoản), tìm kiếm chat / người / tin nhắn, danh bạ, tạo nhóm.
- Bộ sticker như app gốc: xem bộ, thêm / gỡ, bộ nổi bật, tìm bộ, tạo bộ riêng qua bot @Stickers.
- **MTProxy** (`dd`, `ee` fake-TLS) và SOCKS5 — dùng được khi nhà mạng chặn Telegram.
- Thông báo tin mới khi app ở nền (chế độ VoIP của iOS + tweak GMNotify để app có mục «Thông báo»), số chưa đọc trên biểu tượng.
- Khoá app bằng mật mã, chế độ tối, sửa hồ sơ, quyền riêng tư, phiên đăng nhập.
- Tự cập nhật: app kiểm bản mới trên GitHub Releases, tải, kiểm SHA-256, cài rồi tự khởi động lại SpringBoard.

## Cài đặt

- **Cydia:** thêm nguồn `https://GramMini.github.io/cydia/` rồi cài **GramMini**. Cài xong Cydia xin khởi động lại SpringBoard
  (tweak GMNotify cho thông báo).
- **Tay:** tải `vn.grammini.app_<bản>_iphoneos-arm.deb` ở [Releases](https://github.com/itovn/GramMini/releases), chép vào máy,
  `dpkg -i` rồi khởi động lại SpringBoard.

Các bản sau tự cập nhật trong app (Cài đặt → Phiên bản: kiểm ngay).

## Dựng từ mã nguồn

Máy Ubuntu có [Theos](https://theos.dev) (SDK iPhoneOS 9.3) và Rust nightly (`rust-src`):

1. Tạo `api_id` / `api_hash` của riêng bạn ở [my.telegram.org](https://my.telegram.org), ghi vào `keys/telegram.txt`
   (không có trên git — xem `core/crates/gm-ffi/build.rs`).
2. `bash tools/build-app.sh` — bản thử (có công cụ thử `app/Debug/`); `bash tools/build-release.sh` — bản phát hành.

Lõi dựng cho armv7 Cortex-A8 bằng target tự định nghĩa (`tools/rust/armv7-apple-ios6.json`, `-Z build-std`); thư viện mã hoá
`ring` được vá cho ARM 32-bit của Apple (`tools/rust/vendor-ring.sh`). Chạy thử lõi trên PC:

```sh
cd core
cargo test -p gm-net
cargo run -p gm-cli -- probe --dc 2
```

## Tài liệu

| Tệp | Nội dung |
| --- | --- |
| [docs/THIET-KE.md](docs/THIET-KE.md) | Phương án thiết kế: kiến trúc, lõi Rust, cầu FFI, app iOS, media, thông báo |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Các quyết định kỹ thuật và kết quả kiểm chứng |
| [docs/FFI.md](docs/FFI.md) | Hợp đồng lệnh / sự kiện giữa app và lõi |
| [docs/PROGRESS.md](docs/PROGRESS.md) | Nhật ký tiến độ |

## Giấy phép

[GPL-3.0](LICENSE). Phần SOCKS5 lấy từ lõi Côn Bằng TV (GPL-3.0). `core/vendor/grammers-mtsender` giữ giấy phép MIT / Apache-2.0
của grammers; `core/vendor/opus-1.4` giữ giấy phép BSD của Opus.
