/* Sinh bởi tools/ffmpeg/vendor-ffmpeg.py: chỉ bộ giải mã HEVC */
static const FFCodec * const codec_list[] = {
    &ff_hevc_decoder,
    NULL };
