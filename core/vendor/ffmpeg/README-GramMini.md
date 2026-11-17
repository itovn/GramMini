# FFmpeg trong GramMini

Bộ giải mã HEVC (H.265) cho video quay bằng máy mới: iOS 5 / 6 chỉ giải được hình H.264, nên app chuyển video H.265 sang
H.264 ngay trên máy (crate `core/crates/gm-hevc` giải mã, `app/Core/GMHevcTranscoder.m` mã lại bằng phần cứng). Crate
`gm-hevc` dựng thư mục này bằng `cc` (xem `build.rs`).

## Nguồn

- FFmpeg **7.1.5** (20/06/2026), tải từ `https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz`
  (SHA-256 `de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f`), chữ ký PGP `ffmpeg-7.1.5.tar.xz.asc` đã kiểm
  với khoá phát hành của FFmpeg (`FCF9 86EA 15E6 E293 A564 4F10 B432 2F04 D676 58D8`).
- Không chạy `configure` / `make` của FFmpeg. `tools/ffmpeg/vendor-ffmpeg.py` chép:
  - các tệp `.c` trong `gm-sources.txt` (libavutil + libavcodec: lõi giải mã, `hevc/`, `h2645_*`, `cabac`, `golomb`,
    `videodsp`, `bswapdsp`, `dovi_rpu*`, `aom_film_grain`, `h274`, `atsc_a53`, `container_fifo`, bộ lọc `bsf/null.c`…);
  - armv7 (`gm-sources-arm.txt`): thêm hợp ngữ NEON của FFmpeg cho HEVC (`arm/hevcdsp_*_neon.S`) + `videodsp_armv5te.S`,
    `libavutil/arm/cpu.c`;
  - mọi tệp mà chúng `#include` (lần theo dây chuyền; bỏ mã x86 / aarch64 / mips / ppc / loongarch / riscv).
- Tự sinh (không có trong bản gốc): `gm-config/` (C thuần — dựng thử trên Linux), `gm-config-arm/` (armv7 + NEON, iOS):
  `config.h` = mọi macro `CONFIG_*` / `HAVE_*` / `ARCH_*` xuất hiện trong mã đã chép, mặc định 0, bật phần cần (bộ giải HEVC +
  phần nó chọn theo `configure`: `hevc_decoder_select`, pthread, hàm libm có trên iOS 5 / 6, NEON / ARMv6T2 / VFP, ABI softfp
  của iOS: `HAVE_VFP_ARGS 0`, không `clock_gettime` (iOS 10+) → `mach_absolute_time`); `config_components.h`;
  `libavutil/avconfig.h`, `libavutil/ffversion.h`; `libavcodec/codec_list.c` (chỉ `ff_hevc_decoder`), `libavcodec/bsf_list.c`
  (chỉ `null`).

## Giấy phép

LGPL 2.1 trở lên (`COPYING.LGPLv2.1`, `LICENSE.md`) — chỉ dùng phần LGPL (không bật thành phần GPL / nonfree), tương thích
GPL-3.0 của GramMini. Mã nguồn đầy đủ đã dùng nằm ngay trong thư mục này.

## Đo (video 1080 × 1920, 30 khung / giây, 200 giây → H.264 480 × 854)

- iPhone 5 (A6, hai nhân, NEON, giải song song 2 khung): 6006 khung trong 222 giây — **27 khung / giây** (gần thời gian thực).
- iPad 1 (A4, một nhân): 1019 giây (5,9 khung / giây); bật bỏ khung không làm tham chiếu (`skip_frame = AVDISCARD_NONREF`, máy
  một nhân): 537 giây, video ra ~15 khung / giây, không nhoè.

## Cập nhật

Tải bản mới + `.asc`, kiểm chữ ký, giải nén vào thư mục riêng, chạy
`python tools/ffmpeg/vendor-ffmpeg.py <mã FFmpeg> core/vendor/ffmpeg` (sửa danh sách tệp nếu thiếu ký hiệu lúc liên kết), dựng thử
`cargo test -p gm-hevc` và `gm-cli hevc <tệp H.265> <thư mục>` trên Linux, dựng armv7 (`tools/rust/cargo-ios6.sh`), kiểm ký
hiệu (`cbsymcheck`) trên iOS 5 và iOS 6, đo trên máy.
