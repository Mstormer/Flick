// The parts of FFmpeg Flick uses, plus the macros Swift can't import.
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/pixdesc.h>

static inline int ff_eagain(void) { return AVERROR(EAGAIN); }
static inline int ff_eof(void) { return AVERROR_EOF; }
static inline int64_t ff_nopts(void) { return AV_NOPTS_VALUE; }
