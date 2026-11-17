/* Sinh bởi tools/ffmpeg/vendor-ffmpeg.py: chỉ bộ lọc «null» (decode.c cần khi codec không khai bộ lọc) */
static const FFBitStreamFilter * const bitstream_filters[] = {
    &ff_null_bsf,
    NULL };
