/* Lớp bọc mỏng quanh bộ giải mã HEVC của FFmpeg cho gm-hevc (Rust): mở với hvcC (extradata), gửi gói / nhận khung, trả con trỏ
 * các mặt phẳng YUV 4:2:0 (8 hoặc 10 bit) của khung vừa giải. Khung giữ nguyên tới lần nhận sau. */
#include <string.h>
#include "libavcodec/avcodec.h"
#include "libavcodec/codec_internal.h"
#include "libavutil/mem.h"
#include "libavutil/pixdesc.h"

extern const FFCodec ff_hevc_decoder;

typedef struct {
    const uint8_t *planes[3];
    int stride[3];
    int w, h;
    int bits;        /* số bit mỗi mẫu: 8 → 1 byte; > 8 → 2 byte little-endian */
    int full_range;  /* 1 = dải đầy (0–255), 0 = dải video (16–235) */
    int64_t pts;
} gm_hevc_frame;

typedef struct {
    AVCodecContext *c;
    AVPacket *pkt;
    AVFrame *frame;
} gm_hevc;

void gm_hevc_close(void *p) {
    gm_hevc *g = p;
    if (!g) return;
    avcodec_free_context(&g->c);
    av_packet_free(&g->pkt);
    av_frame_free(&g->frame);
    av_free(g);
}

/* extradata = nội dung hộp hvcC của MP4; threads = số luồng giải song song theo khung (máy hai nhân: 2); skip_nonref = bỏ
 * khung không làm tham chiếu (không khung nào dựa vào → không nhoè lan; chỉ ít khung / giây hơn — máy một nhân). NULL nếu lỗi. */
void *gm_hevc_open(const uint8_t *extra, int len, int threads, int skip_nonref) {
    gm_hevc *g = av_mallocz(sizeof(*g));
    if (!g) return NULL;
    g->c = avcodec_alloc_context3(&ff_hevc_decoder.p);
    g->pkt = av_packet_alloc();
    g->frame = av_frame_alloc();
    if (!g->c || !g->pkt || !g->frame) goto fail;
    if (extra && len > 0) {
        g->c->extradata = av_mallocz(len + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!g->c->extradata) goto fail;
        memcpy(g->c->extradata, extra, len);
        g->c->extradata_size = len;
    }
    g->c->thread_count = threads > 0 ? threads : 1;
    g->c->thread_type = FF_THREAD_FRAME;
    if (skip_nonref) g->c->skip_frame = AVDISCARD_NONREF;
    if (avcodec_open2(g->c, &ff_hevc_decoder.p, NULL) < 0) goto fail;
    return g;
fail:
    gm_hevc_close(g);
    return NULL;
}

/* Gửi một mẫu (data NULL = hết, xả khung còn giữ). 0 = được, 1 = phải nhận khung trước, 2 = đã xả, -1 = gói hỏng / lỗi. */
int gm_hevc_send(void *p, const uint8_t *data, int len, int64_t pts, int64_t dts) {
    gm_hevc *g = p;
    int r;
    if (!data) {
        r = avcodec_send_packet(g->c, NULL);
    } else {
        av_packet_unref(g->pkt);
        if (len <= 0 || av_new_packet(g->pkt, len) < 0) return -1;
        memcpy(g->pkt->data, data, len);
        g->pkt->pts = pts;
        g->pkt->dts = dts;
        r = avcodec_send_packet(g->c, g->pkt);
    }
    if (r == AVERROR(EAGAIN)) return 1;
    if (r == AVERROR_EOF) return 2;
    return r < 0 ? -1 : 0;
}

/* Nhận khung kế tiếp (thứ tự trình chiếu). 0 = có khung (điền f), 1 = cần gửi thêm, 2 = hết, -1 = lỗi, -2 = dạng điểm ảnh
 * không phải YUV 4:2:0 phẳng. */
int gm_hevc_receive(void *p, gm_hevc_frame *f) {
    gm_hevc *g = p;
    av_frame_unref(g->frame);
    int r = avcodec_receive_frame(g->c, g->frame);
    if (r == AVERROR(EAGAIN)) return 1;
    if (r == AVERROR_EOF) return 2;
    if (r < 0) return -1;
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(g->frame->format);
    if (!d || d->nb_components < 3 || d->log2_chroma_w != 1 || d->log2_chroma_h != 1 ||
        !(d->flags & AV_PIX_FMT_FLAG_PLANAR) || (d->flags & (AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_BE)) ||
        d->comp[0].plane != 0 || d->comp[1].plane != 1 || d->comp[2].plane != 2 || d->comp[0].depth > 16)
        return -2;
    for (int i = 0; i < 3; i++) {
        f->planes[i] = g->frame->data[i];
        f->stride[i] = g->frame->linesize[i];
    }
    f->w = g->frame->width;
    f->h = g->frame->height;
    f->bits = d->comp[0].depth;
    f->full_range = g->frame->color_range == AVCOL_RANGE_JPEG;
    f->pts = g->frame->pts != AV_NOPTS_VALUE ? g->frame->pts : g->frame->best_effort_timestamp;
    return 0;
}
