# Chép phần libvpx cần cho bộ giải mã VP9 vào core/vendor/libvpx + cấu hình dựng sẵn của Chromium (không chạy configure / perl
# của libvpx): bản C chung (gm-config, cho PC) và bản NEON intrinsics cho armv7 (gm-config-neon, cho iOS).
#   python tools/libvpx/vendor-libvpx.py <mã libvpx đã giải nén> <thư mục Chromium: linux-generic/, linux-arm-neon/, vpx_version.h> core/vendor/libvpx
#   (xem core/vendor/libvpx/README-GramMini.md)
import os, re, shutil, sys

src, chrom, dst = sys.argv[1], sys.argv[2], sys.argv[3]
keep = os.path.join(dst, "README-GramMini.md")
readme = open(keep, encoding="utf-8").read() if os.path.exists(keep) else None
if os.path.exists(dst):
    shutil.rmtree(dst)

# Tệp .c dựng (bộ giải mã VP9 + phần chung) — lọc từ libvpx_srcs_generic của Chromium
C_FILES = """
vp9/vp9_dx_iface.c
vp9/vp9_iface_common.c
vp9/common/vp9_alloccommon.c
vp9/common/vp9_blockd.c
vp9/common/vp9_common_data.c
vp9/common/vp9_entropy.c
vp9/common/vp9_entropymode.c
vp9/common/vp9_entropymv.c
vp9/common/vp9_filter.c
vp9/common/vp9_frame_buffers.c
vp9/common/vp9_idct.c
vp9/common/vp9_loopfilter.c
vp9/common/vp9_mvref_common.c
vp9/common/vp9_pred_common.c
vp9/common/vp9_quant_common.c
vp9/common/vp9_reconinter.c
vp9/common/vp9_reconintra.c
vp9/common/vp9_rtcd.c
vp9/common/vp9_scale.c
vp9/common/vp9_scan.c
vp9/common/vp9_seg_common.c
vp9/common/vp9_thread_common.c
vp9/common/vp9_tile_common.c
vp9/decoder/vp9_decodeframe.c
vp9/decoder/vp9_decodemv.c
vp9/decoder/vp9_decoder.c
vp9/decoder/vp9_detokenize.c
vp9/decoder/vp9_dsubexp.c
vp9/decoder/vp9_job_queue.c
vpx/src/vpx_codec.c
vpx/src/vpx_decoder.c
vpx/src/vpx_image.c
vpx_dsp/bitreader.c
vpx_dsp/bitreader_buffer.c
vpx_dsp/intrapred.c
vpx_dsp/inv_txfm.c
vpx_dsp/loopfilter.c
vpx_dsp/prob.c
vpx_dsp/vpx_convolve.c
vpx_dsp/vpx_dsp_rtcd.c
vpx_mem/vpx_mem.c
vpx_scale/generic/gen_scalers.c
vpx_scale/generic/vpx_scale.c
vpx_scale/generic/yv12config.c
vpx_scale/generic/yv12extend.c
vpx_scale/vpx_scale_rtcd.c
vpx_util/vpx_thread.c
""".split()

# NEON (armv7 — mọi máy iOS 5 / 6 từ A4): hàm intrinsics thay cho bản hợp ngữ (.asm cú pháp ARM phải đổi bằng script perl
# của libvpx — không dùng); thêm dò CPU aarch32 (bảng rtcd gọi arm_cpu_caps). Danh sách = libvpx_srcs_arm_neon_neon của
# Chromium (phần bộ giải mã) + bản intrinsics của các tệp .asm (lấy từ libvpx_srcs_arm64_neon).
NEON_FILES = """
vpx_ports/aarch32_cpudetect.c
vp9/common/arm/neon/vp9_iht16x16_add_neon.c
vp9/common/arm/neon/vp9_iht4x4_add_neon.c
vp9/common/arm/neon/vp9_iht8x8_add_neon.c
vpx_dsp/arm/idct16x16_1_add_neon.c
vpx_dsp/arm/idct16x16_add_neon.c
vpx_dsp/arm/idct32x32_135_add_neon.c
vpx_dsp/arm/idct32x32_1_add_neon.c
vpx_dsp/arm/idct32x32_34_add_neon.c
vpx_dsp/arm/idct32x32_add_neon.c
vpx_dsp/arm/idct4x4_1_add_neon.c
vpx_dsp/arm/idct4x4_add_neon.c
vpx_dsp/arm/idct8x8_1_add_neon.c
vpx_dsp/arm/idct8x8_add_neon.c
vpx_dsp/arm/intrapred_neon.c
vpx_dsp/arm/loopfilter_neon.c
vpx_dsp/arm/vpx_convolve8_neon.c
vpx_dsp/arm/vpx_convolve_avg_neon.c
vpx_dsp/arm/vpx_convolve_copy_neon.c
vpx_dsp/arm/vpx_convolve_neon.c
vpx_dsp/arm/vpx_scaled_convolve8_neon.c
""".split()


def copy(rel):
    os.makedirs(os.path.dirname(os.path.join(dst, rel)) or dst, exist_ok=True)
    shutil.copy2(os.path.join(src, rel), os.path.join(dst, rel))


for f in ["LICENSE", "PATENTS", "AUTHORS", "README", "CHANGELOG"]:
    copy(f)
for f in C_FILES + NEON_FILES:
    copy(f)
# Mọi tệp .h ở các thư mục liên quan (không lấy x86, mips, ppc, loongarch)
HDR_DIRS = ["vpx", "vpx/internal", "vpx_dsp", "vpx_mem", "vpx_mem/include", "vpx_ports", "vpx_scale", "vpx_util",
            "vp9", "vp9/common", "vp9/decoder", "vpx_dsp/arm", "vp9/common/arm/neon"]
for d in HDR_DIRS:
    for n in sorted(os.listdir(os.path.join(src, d))):
        if n.endswith(".h"):
            copy(d + "/" + n)

# Chung cho hai bộ cấu hình: chỉ bộ giải mã VP9 8 bit, một luồng, khung tối đa 1024
SET = {
    "HAVE_PTHREAD_SETNAME_NP": 0, "HAVE_UNISTD_H": 0, "CONFIG_INSTALL_BINS": 0, "CONFIG_POSTPROC": 0, "CONFIG_VP9_POSTPROC": 0,
    "CONFIG_MULTITHREAD": 0, "CONFIG_VP8_ENCODER": 0, "CONFIG_VP8_DECODER": 0, "CONFIG_VP9_ENCODER": 0, "CONFIG_VP8": 0,
    "CONFIG_ENCODERS": 0, "CONFIG_SPATIAL_RESAMPLING": 0, "CONFIG_UNIT_TESTS": 0, "CONFIG_WEBM_IO": 0,
    "CONFIG_MULTI_RES_ENCODING": 0, "CONFIG_TEMPORAL_DENOISING": 0, "CONFIG_VP9_TEMPORAL_DENOISING": 0,
    "CONFIG_VP9_HIGHBITDEPTH": 0, "DECODE_WIDTH_LIMIT": 1024, "DECODE_HEIGHT_LIMIT": 1024,
    # vpx_timer.h dùng CLOCK_MONOTONIC (SDK iOS 9.3 chưa có) — bộ giải mã không cần đồng hồ
    "CONFIG_OS_SUPPORT": 0,
}


def write_config(cdir, chrom_dir, extra, label):
    cfg = os.path.join(dst, cdir)
    os.makedirs(cfg)
    for n in ["vp9_rtcd.h", "vpx_dsp_rtcd.h", "vpx_scale_rtcd.h"]:
        shutil.copy2(os.path.join(chrom, chrom_dir, n), os.path.join(cfg, n))
    shutil.copy2(os.path.join(chrom, "vpx_version.h"), os.path.join(cfg, "vpx_version.h"))
    c = open(os.path.join(chrom, chrom_dir, "vpx_config.h")).read()
    for k, v in dict(SET, **extra).items():
        c, n = re.subn(r"#define %s \S+" % k, "#define %s %d" % (k, v), c)
        assert n == 1, k
    c = c.replace("/* This file automatically generated by configure. Do not edit! */",
                  "/* From Chromium third_party/libvpx/source/config/linux/%s/vpx_config.h (libvpx d3335af9),\n"
                  "   modified for GramMini: VP9 decoder only, 8-bit, single thread, max frame 1024x1024%s.\n"
                  "   See ../README-GramMini.md */" % (chrom_dir.replace("linux-", ""), label))
    open(os.path.join(cfg, "vpx_config.h"), "w", encoding="utf-8", newline="\n").write(c)
    open(os.path.join(cfg, "vpx_config.c"), "w", newline="\n").write(
        '#include "vpx/vpx_codec.h"\n'
        'static const char *const cfg = "GramMini: %s, vp9 decoder only, 8-bit, single thread, size-limit 1024x1024";\n'
        'const char *vpx_codec_build_config(void) { return cfg; }\n' % chrom_dir.replace("linux-", ""))


write_config("gm-config", "linux-generic", {}, "")
# armv7 NEON không hợp ngữ: HAVE_NEON_ASM 0 → intrapred_neon.c tự có bản intrinsics
write_config("gm-config-neon", "linux-arm-neon", {"HAVE_NEON_ASM": 0}, ", NEON intrinsics (no asm)")
open(os.path.join(dst, "gm-sources.txt"), "w", newline="\n").write("\n".join(C_FILES + ["gm-config/vpx_config.c"]) + "\n")
open(os.path.join(dst, "gm-sources-neon.txt"), "w", newline="\n").write(
    "\n".join(C_FILES + NEON_FILES + ["gm-config-neon/vpx_config.c"]) + "\n")
if readme:
    open(keep, "w", encoding="utf-8", newline="\n").write(readme)

total = 0
for r, _, fs in os.walk(dst):
    for f in fs:
        total += os.path.getsize(os.path.join(r, f))
print("files", sum(len(fs) for _, _, fs in os.walk(dst)), "bytes", total)
