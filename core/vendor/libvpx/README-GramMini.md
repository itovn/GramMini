# libvpx trong GramMini

Bộ giải mã VP9 cho sticker video Telegram (WebM) — crate `core/crates/gm-webm` dựng thư mục này bằng `cc` (xem `build.rs`).

## Nguồn

- Mã: libvpx commit `d3335af9e8ec27395f66206be08e786e3de05e60` (v1.17.0-97-gd3335af9e) — đúng bản Chromium đang dùng
  (`chromium/src/third_party/libvpx/README.chromium`), tải từ `github.com/webmproject/libvpx/archive/<commit>.tar.gz`
  (SHA-256 của tệp nén: `b80401dad29672280e757b10230756a36be6e86498d4cb363296bb8dae5510b3`).
- Chỉ chép phần cần cho bộ giải mã VP9: các tệp `.c` trong `gm-sources.txt` / `gm-sources-neon.txt` + mọi tệp `.h` của `vpx/`,
  `vpx_dsp/`, `vpx_mem/`, `vpx_ports/`, `vpx_scale/`, `vpx_util/`, `vp9/`, `vp9/common/`, `vp9/decoder/`, `vpx_dsp/arm/`,
  `vp9/common/arm/neon/` (không lấy mã x86 / mips / ppc / loongarch, hợp ngữ `.asm`, bộ mã hoá, VP8, công cụ, bài thử).
- Hai bộ cấu hình dựng sẵn của Chromium (`chromium/src/third_party/libvpx/source/config/linux/<đích>/{vp9_rtcd.h,
  vpx_dsp_rtcd.h, vpx_scale_rtcd.h, vpx_config.h}` + `source/config/vpx_version.h`). Không chạy `configure` / `rtcd.pl` của libvpx.
  - `gm-config/` (đích `generic`, C thuần) — dựng cho PC (`cargo test`, `gm-cli`), danh sách tệp `gm-sources.txt`.
  - `gm-config-neon/` (đích `arm-neon`) — dựng cho armv7 iOS 5 / 6 (mọi máy từ A4 có NEON), danh sách `gm-sources-neon.txt`:
    thêm các hàm NEON intrinsics (`vpx_dsp/arm/*_neon.c`, `vp9/common/arm/neon/*.c`) và `vpx_ports/aarch32_cpudetect.c`;
    `HAVE_NEON_ASM 0` — không dùng tệp hợp ngữ `.asm` (phải đổi cú pháp bằng script perl của libvpx), chỗ đó lấy bản intrinsics.
    Trên iPhone 5: ~11 ms / khung 512 px (bản C thuần ~28 ms).
  - `vpx_config.h` sửa (cả hai bộ): chỉ bộ giải mã VP9 (tắt VP8, bộ mã hoá, postproc), 8 bit (`CONFIG_VP9_HIGHBITDEPTH 0`),
    một luồng (`CONFIG_MULTITHREAD 0`), khung tối đa 1024 × 1024 (`DECODE_WIDTH_LIMIT` / `DECODE_HEIGHT_LIMIT` — sticker
    Telegram 512 px), `CONFIG_OS_SUPPORT 0` (chỉ bỏ đồng hồ đo của `vpx_timer.h` — nó dùng `CLOCK_MONOTONIC`, SDK iOS 9.3
    không có).
  - `vpx_config.c`: viết lại (chuỗi cấu hình ngắn).
  - Các tệp rtcd giữ nguyên: khai báo thừa (bộ mã hoá, 16 bit) vô hại; dựng với `-Werror=implicit-function-declaration` để
    lệch cấu hình thì báo lỗi ngay.

## Giấy phép

BSD 3 điều khoản (`LICENSE`) + cấp quyền bằng sáng chế của WebM (`PATENTS`) — tương thích GPL-3.0 của GramMini.

## Cập nhật

Lấy commit mới trong `README.chromium` của Chromium, tải mã + `source/config/linux/generic` + `source/config/linux/arm-neon` +
`vpx_version.h` (đặt thành `linux-generic/`, `linux-arm-neon/`, `vpx_version.h` trong một thư mục), chạy lại
`tools/libvpx/vendor-libvpx.py` (lọc như trên, sửa `vpx_config.h` như trên), dựng thử `cargo test -p gm-webm`,
`gm-cli webm <tệp> <thư mục>` trên tệp mẫu, rồi dựng armv7 (`tools/rust/cargo-ios6.sh`) và đo trên máy.
