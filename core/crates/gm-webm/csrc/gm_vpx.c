// Lớp mỏng quanh libvpx (bộ giải mã VP9) cho gm-webm: Rust khỏi phải chép bố cục vpx_codec_ctx_t / vpx_image_t.
#include <stdlib.h>

#include "vpx/vp8dx.h"
#include "vpx/vpx_decoder.h"

/// Một khung đã giải mã (8 bit, phẳng): con trỏ còn hiệu lực tới lần giải mã kế tiếp trên cùng bộ giải mã.
typedef struct {
    const unsigned char *planes[3];
    int stride[3];
    int w, h;
    int x_chroma_shift, y_chroma_shift;
    int full_range;  // 1 = YUV 0..255; 0 = dải studio (Y 16..235)
    int bt709;       // 1 = hệ số BT.709; 0 = BT.601
} gm_vpx_frame;

/// Bộ giải mã VP9 một luồng. NULL nếu lỗi.
void *gm_vpx_open(void) {
    vpx_codec_ctx_t *c = calloc(1, sizeof *c);
    vpx_codec_dec_cfg_t cfg = {1, 0, 0};  // threads, w, h
    if (!c) return NULL;
    if (vpx_codec_dec_init(c, vpx_codec_vp9_dx(), &cfg, 0) != VPX_CODEC_OK) {
        free(c);
        return NULL;
    }
    return c;
}

/// Giải mã một khối WebM (một khung / siêu khung VP9). 0 = có khung hiện (out điền), 1 = không có khung để hiện,
/// -1 = dữ liệu hỏng, -2 = định dạng không hỗ trợ (16 bit).
int gm_vpx_decode(void *ctx, const unsigned char *data, size_t len, gm_vpx_frame *out) {
    vpx_codec_ctx_t *c = ctx;
    vpx_codec_iter_t it = NULL;
    vpx_image_t *img;
    if (!c || !data || !len || len > 0x7fffffff) return -1;
    if (vpx_codec_decode(c, data, (unsigned int)len, NULL, 0) != VPX_CODEC_OK) return -1;
    img = vpx_codec_get_frame(c, &it);
    if (!img) return 1;
    if ((img->fmt & VPX_IMG_FMT_HIGHBITDEPTH) || !(img->fmt & VPX_IMG_FMT_PLANAR) || img->fmt == VPX_IMG_FMT_NV12) return -2;
    out->planes[0] = img->planes[VPX_PLANE_Y];
    out->planes[1] = img->planes[VPX_PLANE_U];
    out->planes[2] = img->planes[VPX_PLANE_V];
    out->stride[0] = img->stride[VPX_PLANE_Y];
    out->stride[1] = img->stride[VPX_PLANE_U];
    out->stride[2] = img->stride[VPX_PLANE_V];
    out->w = (int)img->d_w;
    out->h = (int)img->d_h;
    out->x_chroma_shift = (int)img->x_chroma_shift;
    out->y_chroma_shift = (int)img->y_chroma_shift;
    out->full_range = img->range == VPX_CR_FULL_RANGE;
    out->bt709 = img->cs == VPX_CS_BT_709;
    return 0;
}

void gm_vpx_close(void *ctx) {
    if (ctx) {
        vpx_codec_destroy(ctx);
        free(ctx);
    }
}
