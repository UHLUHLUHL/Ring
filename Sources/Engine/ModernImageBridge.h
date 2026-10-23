#ifndef RING_MODERN_IMAGE_BRIDGE_H
#define RING_MODERN_IMAGE_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Format: 1=AVIF, 2=JPEG XL. Loops: total plays, 0=infinite.
   A tick lasts timescale_den / timescale_num seconds. Pixels are straight RGBA8.
   Readers own input bytes; metadata pointers live until reader destruction. */
typedef struct {
    int format, width, height, depth, has_alpha, frame_count, orientation, is_animated;
    int color_primaries, transfer_characteristics;
    uint32_t timescale_num, timescale_den, loops;
} RingModernInfo;
int ring_modern_sniff(const uint8_t *data,size_t size);
void *ring_modern_open(const uint8_t *data,size_t size,int threads,RingModernInfo *info,char *error,size_t error_size);
const uint8_t *ring_modern_metadata(void *reader,int exif,size_t *size);
uint64_t ring_modern_duration(void *reader,int index);
int ring_modern_frame(void *reader,int index,uint8_t *rgba,size_t size,char *error,size_t error_size);
void ring_modern_close(void *reader);
void *ring_modern_encoder_create(const RingModernInfo *info,const uint8_t *icc,size_t icc_size,const uint8_t *exif,size_t exif_size,int quality,int threads,char *error,size_t error_size);
int ring_modern_encoder_add(void *encoder,const uint8_t *rgba,size_t size,uint64_t ticks,char *error,size_t error_size);
int ring_modern_encoder_finish(void *encoder,uint8_t **output,size_t *size,char *error,size_t error_size);
void ring_modern_encoder_close(void *encoder);
void ring_modern_free(void *buffer);
#ifdef __cplusplus
}
#endif
#endif
