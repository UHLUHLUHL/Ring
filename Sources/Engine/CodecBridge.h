#ifndef RING_CODEC_BRIDGE_H
#define RING_CODEC_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
uint32_t ring_crc32(uint32_t crc,const uint8_t *data,size_t size);
uint64_t ring_compare_pixels16(const uint16_t *a,const uint16_t *b,size_t count,int quantize8,uint16_t *max_difference);
void ring_rgba16_to_rgba8(const uint16_t *source,uint8_t *output,size_t pixels);
int ring_pdf_add_info(const char *source,const char *output);
int ring_pdf_replace_page(const char *source,const char *page,int page_number,int page_count,const char *output);
int ring_webp_encode(const uint8_t *rgba,int width,int height,int stride,const uint8_t *icc,size_t icc_size,const uint8_t *exif,size_t exif_size,int threads,const char *path,char *error,size_t error_size);
int ring_avif_encode(const uint8_t *rgba,int width,int height,int stride,const uint8_t *icc,size_t icc_size,const uint8_t *exif,size_t exif_size,int threads,const char *path,char *error,size_t error_size);
int ring_jpeg_transform(const uint8_t *source,size_t size,int crop,int x,int y,int width,int height,const char *path,char *error,size_t error_size);
int ring_jpeg_coefficients_equal(const uint8_t *source,size_t source_size,const uint8_t *output,size_t output_size,int x,int y,char *error,size_t error_size);
void ring_buffer_free(void *buffer);
int ring_image_encode_memory(const uint8_t *rgba,int width,int height,int stride,const uint8_t *icc,size_t icc_size,const uint8_t *exif,size_t exif_size,int webp,int quality,int target_bytes,int threads,uint8_t **output,size_t *output_size,char *error,size_t error_size);
void *ring_webp_animation_create(int width,int height);
int ring_webp_animation_add(void *animation,const uint8_t *rgba,int width,int height,int timestamp,int quality,int threads);
int ring_webp_animation_finish(void *animation,int timestamp,uint8_t **output,size_t *size);
void ring_webp_animation_destroy(void *animation);
void *ring_webp_mux_create(int width,int height);
void *ring_webp_lossless_mux_create(int width,int height,int loop_count,const uint8_t *icc,size_t icc_size);
int ring_webp_lossless_mux_add(void *mux,const uint8_t *rgba,int width,int height,int duration_ms,int threads,size_t *encoded_size);
void *ring_webp_image_decoder_create(const uint8_t *bytes,size_t size,int threads,int *width,int *height,int *frames,int *loops);
int ring_webp_image_decoder_next(void *decoder,const uint8_t **pixels);
void ring_webp_image_decoder_reset(void *decoder);
void ring_webp_image_decoder_destroy(void *decoder);
int ring_webp_mux_append(void *mux,const uint8_t *bytes,size_t size,int duration_ms);
int ring_webp_mux_finish(void *mux,uint8_t **output,size_t *size);
void ring_webp_mux_destroy(void *mux);
int ring_inflate_raw(const uint8_t *source,size_t size,uint8_t *output,size_t output_size);
int ring_pdf_pages(const char *const *sources,const int *pages,size_t count,double uniform_width,const char *output,char *error,size_t error_size);
typedef int (*ring_pdf_image_callback)(void *context,const uint8_t *data,size_t size,int width,int height,int channels,int jpeg,const uint8_t *icc,size_t icc_size,uint8_t **output,size_t *output_size,int *out_width,int *out_height);
int ring_pdf_smart_compress(const char *source,const char *output,int minimum_dimension,ring_pdf_image_callback callback,void *context,int *changed,char *error,size_t error_size);
int ring_pdf_check(const char *source,int expected_pages,char *error,size_t error_size);
#ifdef __cplusplus
}
#endif
#endif
