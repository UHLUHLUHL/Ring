#ifndef RING_SOFTWARE_VIDEO_H
#define RING_SOFTWARE_VIDEO_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Return: 0 success, 1 unsupported, 2 malformed input, 3 cancelled,
   4 I/O/codec failure. Decoder next: 1 frame, 0 clean EOF, negative error code.
   Errors are UTF-8 strings written to a caller-owned 512-byte buffer. */
typedef int (*RingVideoCancel)(void *context);
typedef void (*RingVideoProgress)(double fraction, void *context);
typedef void (*RingVideoTimestamp)(double seconds,void *context);
typedef struct {
    int h264, hevc, av1, mp4, mov, webm, opus;
} RingSoftwareVideoCapabilities;
typedef struct {
    /* video_codec: 1 H.264, 2 HEVC, 3 AV1, 0 other. audio_codec: AVCodecID. */
    int width, height, video_codec, audio_codec, audio_tracks, video_tracks;
    int color_primaries, color_transfer, color_space, color_range, bit_depth;
    int audio_channels, audio_sample_rate, restricted, webm_audio_copy;
    int32_t display_matrix[9];
    int has_display_matrix;
    double duration, video_duration, audio_duration, frame_rate, video_bitrate, audio_bitrate;
    double rotation, first_pts, last_pts, last_duration, audio_start;
    int64_t frame_count, video_bytes, audio_bytes;
    int time_base_num, time_base_den;
    unsigned char audio_sha256[32];
    unsigned char decoded_timeline_sha256[32], audio_timing_sha256[32];
    char restriction[256];
} RingSoftwareVideoInfo;
typedef struct {
    /* codec: 1 x264, 2 x265, 3 SVT-AV1; container: 1 MP4, 2 MOV, 3 WebM.
       WebM accepts AV1 only. Audio is always copied; incompatible audio is
       rejected unless allow_opus_transcode is explicitly set. */
    int codec, container, allow_opus_transcode;
    /* Compression only: SVT preset 8 and native CRF14 (x264/x265 CRF16).
       Zero preserves the conservative format-conversion profile. */
    int compression_profile;
    /* Positive: ABR bit budget for compression. Zero: conservative native
       constant-quality format conversion (x264/x265 CRF10, SVT CRF8, PSNR tune).
       Final decoded-frame quality verification is still required by the caller. */
    int64_t bitrate;
} RingSoftwareVideoOptions;
typedef struct RingVideoDecoder RingVideoDecoder;
typedef struct {
    const uint8_t *y, *u, *v;
    int y_stride, u_stride, v_stride, width, height;
    int64_t pts, duration;
    int time_base_num, time_base_den;
    int color_primaries, color_transfer, color_space, color_range;
} RingSoftwareVideoFrame;
RingSoftwareVideoCapabilities ring_video_capabilities(void);
int ring_video_inspect(const char *path, int decode_all, RingSoftwareVideoInfo *info,
                       RingVideoCancel cancel, void *context, char *error);
int ring_video_encode(const char *source, const char *destination, const RingSoftwareVideoOptions *options,
                      RingVideoProgress progress, RingVideoCancel cancel, void *context, char *error);
int ring_video_copy_nv12(const RingSoftwareVideoFrame *frame,uint8_t *y,int y_stride,uint8_t *uv,int uv_stride);
int ring_video_same_timing(const RingSoftwareVideoFrame *a,const RingSoftwareVideoFrame *b);
int ring_video_mux_original(const char *source,const char *video,const char *destination,int original_geometry,
                            RingVideoCancel cancel,void *context,char *error);
RingVideoDecoder *ring_video_decoder_create(const char *path, RingVideoCancel cancel, void *context, char *error);
int ring_video_decoder_next(RingVideoDecoder *decoder, RingSoftwareVideoFrame *frame, char *error);
int ring_video_decoder_seek(RingVideoDecoder *decoder,double seconds,char *error);
int ring_video_presentation_times(const char *source,double start,double duration,RingVideoTimestamp timestamp,
                                  RingVideoCancel cancel,void *context,char *error);
void ring_video_decoder_destroy(RingVideoDecoder *decoder);
#ifdef __cplusplus
}
#endif
#endif
