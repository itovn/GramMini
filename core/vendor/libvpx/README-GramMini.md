# libvpx trong GramMini

Bộ giải mã VP9 cho sticker video Telegram (WebM) — crate `core/crates/gm-webm` dựng thư mục này bằng `cc` (xem `build.rs`).

## Nguồn

- Mã: libvpx commit `d3335af9e8ec27395f66206be08e786e3de05e60` (v1.17.0-97-gd3335af9e) — đúng bản Chromium đang dùng
  (`chromium/src/third_party/libvpx/README.chromium`), tải từ `github.com/webmproject/libvpx/archive/<commit>.tar.gz`
  (SHA-256 của tệp nén: `b80401dad29672280e757b10230756a36be6e86498d4cb363296bb8dae5510b3`).
- Chỉ chép phần cần cho bộ giải mã VP9: các tệp `.c` trong `gm-sources.txt` + mọi tệp `.h` của `vpx/`, `vpx_dsp/`, `vpx_mem/`,
  `vpx_ports/`, `vpx_scale/`, `vpx_util/`, `vp9/`, `vp9/common/`, `vp9/decoder/` (không lấy mã SIMD theo kiến trúc, bộ mã hoá,
  VP8, công cụ, bài thử).
- `gm-config/`: cấu hình dựng sẵn của Chromium cho đích `generic` (C thuần, không SIMD) —
  `chromium/src/third_party/libvpx/source/config/linux/generic/{vp9_rtcd.h, vpx_dsp_rtcd.h, vpx_scale_rtcd.h, vpx_config.h}`
  và `source/config/vpx_version.h`. Không chạy `configure` / `rtcd.pl` của libvpx.
  - `vpx_config.h` sửa: chỉ bộ giải mã VP9 (tắt VP8, bộ mã hoá, postproc), 8 bit (`CONFIG_VP9_HIGHBITDEPTH 0`), một luồng
    (`CONFIG_MULTITHREAD 0`), khung tối đa 1024 × 1024 (`DECODE_WIDTH_LIMIT` / `DECODE_HEIGHT_LIMIT` — sticker Telegram 512 px),
    `CONFIG_OS_SUPPORT 0` (chỉ bỏ đồng hồ đo của `vpx_timer.h` — nó dùng `CLOCK_MONOTONIC`, SDK iOS 9.3 không có).
  - `vpx_config.c`: viết lại (chuỗi cấu hình ngắn).
  - Các tệp rtcd giữ nguyên: đích generic chỉ có `#define tên tên_c`, khai báo thừa (bộ mã hoá, 16 bit) vô hại; dựng với
    `-Werror=implicit-function-declaration` để lệch cấu hình thì báo lỗi ngay.

## Giấy phép

BSD 3 điều khoản (`LICENSE`) + cấp quyền bằng sáng chế của WebM (`PATENTS`) — tương thích GPL-3.0 của GramMini.

## Cập nhật

Lấy commit mới trong `README.chromium` của Chromium, tải mã + `source/config/linux/generic` + `vpx_version.h`, chạy lại
`tools/libvpx/vendor-libvpx.py` (lọc như trên, sửa `vpx_config.h` như trên), dựng thử `cargo test -p gm-webm` và
`gm-cli webm <tệp> <thư mục>` trên tệp mẫu.
