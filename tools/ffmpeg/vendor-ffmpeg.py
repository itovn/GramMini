# Chép phần FFmpeg cần cho bộ giải mã HEVC (H.265) vào core/vendor/ffmpeg + tự sinh cấu hình (không chạy `configure` của FFmpeg):
#   python tools/ffmpeg/vendor-ffmpeg.py <mã FFmpeg đã giải nén> core/vendor/ffmpeg
# - Tệp .c / .S trong các danh sách dưới + mọi tệp chúng #include (lần theo dây chuyền; bỏ mã của kiến trúc khác ARM).
# - config.h: quét mọi macro CONFIG_* / HAVE_* / ARCH_* trong tệp đã chép → mặc định 0, bật phần cần (bảng GENERIC / ARM).
#   Hai bộ: gm-config (C thuần — thử trên PC / Linux) và gm-config-arm (armv7 + NEON, iOS 5 / 6).
# - Sinh libavutil/avconfig.h, libavutil/ffversion.h, libavcodec/bsf_list.c (chỉ bộ lọc «null»).
# Xem core/vendor/ffmpeg/README-GramMini.md.
import os, re, shutil, sys

src, dst = sys.argv[1], sys.argv[2]
keep = os.path.join(dst, "README-GramMini.md")
readme = open(keep, encoding="utf-8").read() if os.path.exists(keep) else None
if os.path.exists(dst):
    shutil.rmtree(dst)

AVUTIL = """
avstring.c buffer.c bprint.c channel_layout.c cpu.c crc.c dict.c display.c dovi_meta.c error.c eval.c film_grain_params.c
frame.c hdr_dynamic_metadata.c hwcontext.c imgutils.c intmath.c log.c log2_tab.c mastering_display_metadata.c mathematics.c
md5.c mem.c opt.c parseutils.c pixdesc.c rational.c reverse.c samplefmt.c slicethread.c spherical.c stereo3d.c time.c
timecode.c ambient_viewing_environment.c avsscanf.c random_seed.c sha.c integer.c video_enc_params.c detection_bbox.c
downmix_info.c iamf.c video_hint.c pixelutils.c fifo.c file_open.c hdr_dynamic_vivid_metadata.c utils.c
""".split()
AVCODEC = """
avcodec.c decode.c encode.c options.c codec_desc.c packet.c utils.c get_buffer.c bsf.c bitstream_filters.c bsf/null.c
profiles.c allcodecs.c refstruct.c threadprogress.c mathtables.c pthread.c pthread_frame.c pthread_slice.c codec_par.c
version.c imgconvert.c dynamic_hdr_vivid.c
h2645data.c h2645_parse.c h2645_vui.c h2645_sei.c aom_film_grain.c h274.c container_fifo.c atsc_a53.c bswapdsp.c cabac.c
dovi_rpu.c dovi_rpudec.c golomb.c videodsp.c
hevc/cabac.c hevc/data.c hevc/dsp.c hevc/filter.c hevc/hevcdec.c hevc/mvs.c hevc/pred.c hevc/refs.c hevc/parse.c hevc/ps.c
hevc/sei.c
""".split()
# armv7 (iOS 5 / 6 — mọi máy từ A4 có NEON): mã hợp ngữ NEON của FFmpeg cho HEVC + videodsp
ARM = """
libavutil/arm/cpu.c
libavcodec/arm/hevcdsp_init_arm.c libavcodec/arm/hevcdsp_init_neon.c libavcodec/arm/hevcdsp_deblock_neon.S
libavcodec/arm/hevcdsp_idct_neon.S libavcodec/arm/hevcdsp_qpel_neon.S libavcodec/arm/hevcdsp_sao_neon.S
libavcodec/arm/videodsp_init_arm.c libavcodec/arm/videodsp_init_armv5te.c libavcodec/arm/videodsp_armv5te.S
""".split()
C_FILES = ["libavutil/" + f for f in AVUTIL] + ["libavcodec/" + f for f in AVCODEC]
SKIP_DIRS = ("x86/", "aarch64/", "mips/", "ppc/", "loongarch/", "riscv/", "sh4/", "alpha/", "bfin/", "avr32/", "tomi/", "sparc/")
GENERATED = {"config.h", "config_components.h", "libavutil/avconfig.h", "libavutil/ffversion.h", "libavcodec/bsf_list.c",
             "libavcodec/codec_list.c", "libavcodec/parser_list.c"}

INC = re.compile(r'^\s*#\s*include\s+"([^"]+)"', re.M)
copied = set()


def resolve(name, cur):
    """Tệp được #include "name" từ tệp cur: cạnh tệp đang đọc, gốc mã, libavcodec/ (hevc/ dùng -I libavcodec)."""
    for base in (os.path.dirname(cur), "", "libavcodec"):
        rel = os.path.normpath(os.path.join(base, name)).replace("\\", "/")
        if os.path.isfile(os.path.join(src, rel)):
            return rel
    return None


def take(rel):
    if rel in copied or rel.startswith(SKIP_DIRS) or any("/" + d in rel for d in SKIP_DIRS):
        return
    copied.add(rel)
    os.makedirs(os.path.dirname(os.path.join(dst, rel)) or dst, exist_ok=True)
    shutil.copy2(os.path.join(src, rel), os.path.join(dst, rel))
    text = open(os.path.join(src, rel), encoding="utf-8", errors="replace").read()
    for name in INC.findall(text):
        if name in GENERATED or name.endswith(tuple("/" + g for g in GENERATED)):
            continue
        r = resolve(name, rel)
        if r:
            take(r)


for f in C_FILES + ARM + ["libavutil/arm/asm.S"]:
    take(f)
for f in ["COPYING.LGPLv2.1", "LICENSE.md", "CREDITS", "VERSION", "RELEASE"]:
    if os.path.exists(os.path.join(src, f)):
        shutil.copy2(os.path.join(src, f), os.path.join(dst, f))

# Mọi macro cấu hình xuất hiện trong mã đã chép (trừ macro chính mã tự #define)
text = ""
for rel in copied:
    text += open(os.path.join(dst, rel), encoding="utf-8", errors="replace").read() + "\n"
used = set(re.findall(r"\b((?:CONFIG|HAVE|ARCH)_[A-Z0-9_]+)\b", text))
defined_in_src = set(re.findall(r"#\s*define\s+((?:CONFIG|HAVE|ARCH)_[A-Z0-9_]+)\b", text))
used -= defined_in_src
used -= {"HAVE_AV_CONFIG_H"}

COMMON = {
    # bộ giải mã HEVC + phần nó chọn (configure: hevc_decoder_select)
    "CONFIG_HEVC_DECODER": 1, "CONFIG_GOLOMB": 1, "CONFIG_CABAC": 1, "CONFIG_VIDEODSP": 1, "CONFIG_BSWAPDSP": 1,
    "CONFIG_HEVCPARSE": 1, "CONFIG_HEVC_SEI": 1, "CONFIG_ATSC_A53": 1, "CONFIG_DOVI_RPUDEC": 1, "CONFIG_NULL_BSF": 1,
    "CONFIG_SAFE_BITSTREAM_READER": 1, "CONFIG_AVCODEC": 1, "CONFIG_AVUTIL": 1,
    # luồng: pthread (giải nhiều khung song song — A5 / A6 hai nhân)
    "HAVE_PTHREADS": 1, "HAVE_THREADS": 1,
    # hàm C / libm có trên iOS 5 / 6 và Linux (libm.h tự viết hàm thiếu — báo có để khỏi đè hàm hệ thống)
    "HAVE_UNISTD_H": 1, "HAVE_SYSCONF": 1, "HAVE_POSIX_MEMALIGN": 1, "HAVE_GETTIMEOFDAY": 1, "HAVE_NANOSLEEP": 1,
    "HAVE_USLEEP": 1, "HAVE_GMTIME_R": 1, "HAVE_LOCALTIME_R": 1, "HAVE_ISATTY": 1, "HAVE_ACCESS": 1, "HAVE_FCNTL": 1,
    "HAVE_ATTRIBUTE_PACKED": 1, "HAVE_ATTRIBUTE_MAY_ALIAS": 1, "HAVE_PRAGMA_DEPRECATED": 1, "HAVE_LOCAL_ALIGNED": 1,
    "HAVE_FAST_UNALIGNED": 1, "HAVE_FAST_CLZ": 1, "HAVE_STDATOMIC": 1,
    **{"HAVE_" + f: 1 for f in """ATANF ATAN2F CBRT CBRTF COPYSIGN COSF ERF EXP2 EXP2F EXPF HYPOT ISFINITE ISINF ISNAN LDEXPF
        LLRINT LLRINTF LOG2 LOG2F LOG10F LRINT LRINTF POWF RINT ROUND ROUNDF SINF TRUNC TRUNCF""".split()},
}
GENERIC = {"HAVE_CLOCK_GETTIME": 1, "HAVE_FAST_64BIT": 1}
ARMV7 = {
    "ARCH_ARM": 1,
    **{"HAVE_" + f: 1 for f in """ARMV5TE ARMV6 ARMV6T2 VFP VFPV3 NEON
        ARMV5TE_EXTERNAL ARMV6_EXTERNAL ARMV6T2_EXTERNAL VFP_EXTERNAL VFPV3_EXTERNAL NEON_EXTERNAL
        ARMV5TE_INLINE ARMV6_INLINE ARMV6T2_INLINE VFP_INLINE VFPV3_INLINE NEON_INLINE INLINE_ASM SIMD_ALIGN_16
        MACH_ABSOLUTE_TIME""".split()},
    # iOS: ABI softfp (số thực qua thanh ghi thường), trình hợp dịch của clang (không .func / .arch / .fpu / .dn)
    "HAVE_VFP_ARGS": 0, "CONFIG_THUMB": 0, "HAVE_AS_FUNC": 0,
}
EXTRA = {
    "gm-config": '#define EXTERN_PREFIX ""\n#define EXTERN_ASM\n',
    "gm-config-arm": '#define EXTERN_PREFIX "_"\n#define EXTERN_ASM _\n',
}


def write_config(cdir, over, label):
    cfg = os.path.join(dst, cdir)
    os.makedirs(cfg)
    vals = {k: 0 for k in used}
    vals.update(COMMON)
    vals.update(over)
    comp = re.compile(r"^CONFIG_.*_(DECODER|ENCODER|PARSER|BSF|HWACCEL|DEMUXER|MUXER|PROTOCOL|FILTER|INDEV|OUTDEV)$")
    head = ("/* Sinh bởi tools/ffmpeg/vendor-ffmpeg.py cho GramMini (FFmpeg 7.1.5, chỉ bộ giải mã HEVC; %s) —\n"
            "   không phải config.h của configure. Xem ../README-GramMini.md */\n" % label)
    lines = [head, "#ifndef FFMPEG_CONFIG_H\n#define FFMPEG_CONFIG_H\n",
             '#define FFMPEG_CONFIGURATION "GramMini: hevc decoder only"\n',
             '#define FFMPEG_LICENSE "LGPL version 2.1 or later"\n', "#define CONFIG_THIS_YEAR 2026\n",
             '#define FFMPEG_DATADIR ""\n#define AVCONV_DATADIR ""\n#define CC_IDENT "clang"\n#define OS_NAME ios\n',
             '#define BUILDSUF ""\n#define SLIBSUF ""\n#define SWS_MAX_FILTER_SIZE 256\n#define av_restrict restrict\n',
             EXTRA[cdir]]
    comps = ["/* Sinh bởi tools/ffmpeg/vendor-ffmpeg.py (thành phần) */\n#ifndef FFMPEG_CONFIG_COMPONENTS_H\n"
             "#define FFMPEG_CONFIG_COMPONENTS_H\n"]
    # config.h: mọi macro; config_components.h nhắc lại nhóm thành phần (định nghĩa trùng y hệt — C cho phép). Không tách hẳn:
    # vd CONFIG_FRAME_THREAD_ENCODER trông như thành phần nhưng configure đặt ở config.h.
    for k in sorted(vals):
        lines.append("#define %s %d\n" % (k, vals[k]))
        if comp.match(k):
            comps.append("#define %s %d\n" % (k, vals[k]))
    lines.append("#endif\n")
    comps.append("#endif\n")
    out(os.path.join(cfg, "config.h"), "".join(lines))
    out(os.path.join(cfg, "config_components.h"), "".join(comps))


def out(path, text):
    open(path, "w", encoding="utf-8", newline="\n").write(text)


write_config("gm-config", GENERIC, "C thuần")
write_config("gm-config-arm", ARMV7, "armv7 + NEON, iOS")
out(os.path.join(dst, "libavutil/avconfig.h"),
    "/* Sinh bởi tools/ffmpeg/vendor-ffmpeg.py */\n#ifndef AVUTIL_AVCONFIG_H\n#define AVUTIL_AVCONFIG_H\n"
    "#define AV_HAVE_BIGENDIAN 0\n#define AV_HAVE_FAST_UNALIGNED 1\n#endif\n")
version = open(os.path.join(src, "VERSION")).read().strip() if os.path.exists(os.path.join(src, "VERSION")) else "7.1.5"
out(os.path.join(dst, "libavutil/ffversion.h"),
    '/* Sinh bởi tools/ffmpeg/vendor-ffmpeg.py */\n#ifndef AVUTIL_FFVERSION_H\n#define AVUTIL_FFVERSION_H\n'
    '#define FFMPEG_VERSION "%s"\n#endif\n' % version)
out(os.path.join(dst, "libavcodec/bsf_list.c"),
    "/* Sinh bởi tools/ffmpeg/vendor-ffmpeg.py: chỉ bộ lọc «null» (decode.c cần khi codec không khai bộ lọc) */\n"
    "static const FFBitStreamFilter * const bitstream_filters[] = {\n    &ff_null_bsf,\n    NULL };\n")
out(os.path.join(dst, "libavcodec/codec_list.c"),
    "/* Sinh bởi tools/ffmpeg/vendor-ffmpeg.py: chỉ bộ giải mã HEVC */\n"
    "static const FFCodec * const codec_list[] = {\n    &ff_hevc_decoder,\n    NULL };\n")
out(os.path.join(dst, "gm-sources.txt"), "\n".join(C_FILES) + "\n")
out(os.path.join(dst, "gm-sources-arm.txt"), "\n".join(C_FILES + ARM) + "\n")
if readme:
    out(keep, readme)

total = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(dst) for f in fs)
print("files", sum(len(fs) for _, _, fs in os.walk(dst)), "bytes", total, "macros", len(used))
