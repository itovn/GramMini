#include "vpx/vpx_codec.h"
static const char *const cfg = "GramMini: generic, vp9 decoder only, 8-bit, single thread, size-limit 1024x1024";
const char *vpx_codec_build_config(void) { return cfg; }
