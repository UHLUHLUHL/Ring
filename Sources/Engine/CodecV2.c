#include "CodecBridge.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include <limits.h>
#include <jpeglib.h>
#include <webp/encode.h>
#include <webp/mux.h>
#include <webp/demux.h>
#include <zlib.h>
#include <math.h>

int ring_video_plane_quality(const uint8_t *reference,size_t reference_stride,
    const uint8_t *encoded,size_t encoded_stride,int width,int height,
    int pixel_stride,int phase,RingVideoPlaneQuality *result) {
    if(!reference || !encoded || !result || width<1 || height<1 || phase<0 ||
       (pixel_stride!=1 && pixel_stride!=2) || reference_stride<(size_t)width*pixel_stride ||
       encoded_stride<(size_t)width*pixel_stride) return 0;
    const int columns=(width+7)/8,rows=(height+7)/8;
    int step=1;
    while(((columns+step-1)/step)*((rows+step-1)/step)>4096) step++;
    const int x_phase=phase%step,y_phase=(phase/step)%step;
    unsigned histogram[1001]={0};
    double sum_ssim=0;unsigned blocks=0;
    for(int by=y_phase;by<rows;by+=step) for(int bx=x_phase;bx<columns;bx+=step) {
        double a=0,b=0,aa=0,bb=0,ab=0;
        const int block_width=width-bx*8<8 ? width-bx*8:8;
        const int block_height=height-by*8<8 ? height-by*8:8;
        const double pixels=block_width*block_height;
        for(int y=0;y<block_height;y++) {
            const uint8_t *r=reference+(by*8+y)*reference_stride+bx*8*pixel_stride;
            const uint8_t *e=encoded+(by*8+y)*encoded_stride+bx*8*pixel_stride;
            for(int x=0;x<block_width;x++) {
                double v=r[x*pixel_stride],w=e[x*pixel_stride];
                a+=v;b+=w;aa+=v*v;bb+=w*w;ab+=v*w;
            }
        }
        a/=pixels;b/=pixels;
        const double va=fmax(0,aa/pixels-a*a),vb=fmax(0,bb/pixels-b*b),cov=ab/pixels-a*b;
        // SSIM constants K1=.01, K2=.03, L=255; box windows, no rescaling.
        double score=((2*a*b+6.5025)*(2*cov+58.5225))/((a*a+b*b+6.5025)*(va+vb+58.5225));
        score=fmin(1,fmax(0,score));
        histogram[(int)(score*1000)]++;sum_ssim+=score;blocks++;
    }
    if(!blocks) return 0;
    const unsigned tail_count=(blocks+9)/10;
    unsigned remaining=tail_count;double tail=0;
    for(int bin=0;bin<=1000 && remaining;bin++) {
        unsigned count=histogram[bin]<remaining ? histogram[bin]:remaining;
        tail+=count*(double)bin/1000;remaining-=count;
    }
    result->ssim=sum_ssim/blocks;result->tail_ssim=tail/tail_count;
    uint64_t squared=0;
    for(int y=0;y<height;y++) {
        const uint8_t *r=reference+y*reference_stride,*e=encoded+y*encoded_stride;
        for(int x=0;x<width;x++) {
            int d=(int)r[x*pixel_stride]-(int)e[x*pixel_stride];
            squared+=(unsigned)(d*d);
        }
    }
    result->mse=(double)squared/((double)width*height);return 1;
}

void ring_buffer_free(void *buffer) { free(buffer); }
void ring_rgba16_to_rgba8(const uint16_t * restrict source,uint8_t * restrict output,size_t pixels) {
    for(size_t i=0;i<pixels;i++) {
        const uint16_t *s=source+i*4;uint8_t *d=output+i*4;uint32_t a=s[3];
        if(a==65535) {
            d[0]=(s[0]+128u)/257;d[1]=(s[1]+128u)/257;d[2]=(s[2]+128u)/257;
        } else if(a==0) { d[0]=d[1]=d[2]=0; }
        else {
            for(int c=0;c<3;c++) { uint32_t value=(s[c]*255u+a/2)/a;d[c]=(uint8_t)(value>255 ? 255:value); }
        }
        d[3]=(a+128)/257;
    }
}
// Integer reductions preserve the Swift verifier's rounding exactly while
// allowing Clang to vectorize for both NEON and x86_64. No pixel is skipped.
uint64_t ring_compare_pixels16(const uint16_t * restrict a,const uint16_t * restrict b,size_t count,int quantize8,uint16_t *max_difference) {
    uint64_t squared=0;uint32_t largest=0;
    if(quantize8) {
        for(size_t i=0;i<count;i++) {
            int x=((uint32_t)a[i]+128)/257*257,y=((uint32_t)b[i]+128)/257*257;
            uint32_t d=(uint32_t)(x>y ? x-y:y-x);
            squared+=(uint64_t)d*d;if(d>largest) largest=d;
        }
    } else {
        for(size_t i=0;i<count;i++) {
            int x=a[i],y=b[i];uint32_t d=(uint32_t)(x>y ? x-y:y-x);
            squared+=(uint64_t)d*d;if(d>largest) largest=d;
        }
    }
    *max_difference=(uint16_t)largest;return squared;
}
static int message(char *error,size_t n,const char *text) {
    if(n) snprintf(error,n,"%s",text);
    return 0;
}
struct MemoryJPEG {
    struct jpeg_compress_struct codec;
    struct jpeg_error_mgr error;
    jmp_buf jump;
    unsigned char *bytes;
    unsigned long size;
    char *message;
    size_t message_size;
};
static void jpeg_failure(j_common_ptr codec) {
    struct MemoryJPEG *s=(struct MemoryJPEG *)codec->client_data;
    char text[JMSG_LENGTH_MAX];
    codec->err->format_message(codec,text);
    message(s->message,s->message_size,text);
    longjmp(s->jump,1);
}
static int memory_jpeg(const uint8_t *rgba,int width,int height,int stride,
    const uint8_t *icc,size_t icc_size,const uint8_t *exif,size_t exif_size,int quality,
    uint8_t **output,size_t *output_size,char *error,size_t error_size) {
    if(exif_size>65527 || icc_size>65519*255) return message(error,error_size,"JPEG metadata exceeds marker limits");
    struct MemoryJPEG *s=calloc(1,sizeof(*s));
    if(!s) return 0;
    int ok=0;
    s->message=error;s->message_size=error_size;
    s->codec.err=jpeg_std_error(&s->error);s->error.error_exit=jpeg_failure;
    s->codec.client_data=s;
    if(setjmp(s->jump)) goto done;
    jpeg_create_compress(&s->codec);
    jpeg_mem_dest(&s->codec,&s->bytes,&s->size);
    s->codec.image_width=width;s->codec.image_height=height;
    s->codec.input_components=4;s->codec.in_color_space=JCS_EXT_RGBA;
    jpeg_set_defaults(&s->codec);jpeg_set_quality(&s->codec,quality,TRUE);
    s->codec.optimize_coding=TRUE;
    if(quality>=90) for(int c=0;c<3;c++) s->codec.comp_info[c].h_samp_factor=s->codec.comp_info[c].v_samp_factor=1;
    jpeg_start_compress(&s->codec,TRUE);
    if(icc_size) jpeg_write_icc_profile(&s->codec,icc,(unsigned int)icc_size);
    if(exif_size) {
        // jpeg_write_m_header avoids a second large metadata allocation.
        jpeg_write_m_header(&s->codec,JPEG_APP0+1,(unsigned int)exif_size+6);
        const uint8_t prefix[6]={'E','x','i','f',0,0};
        for(int i=0;i<6;i++) jpeg_write_m_byte(&s->codec,prefix[i]);
        for(size_t i=0;i<exif_size;i++) jpeg_write_m_byte(&s->codec,exif[i]);
    }
    while(s->codec.next_scanline<s->codec.image_height) {
        JSAMPROW row=(JSAMPROW)(rgba+(size_t)s->codec.next_scanline*stride);
        jpeg_write_scanlines(&s->codec,&row,1);
    }
    jpeg_finish_compress(&s->codec);
    *output=s->bytes;*output_size=s->size;s->bytes=NULL;ok=1;
done:
    if(s->codec.mem) jpeg_destroy_compress(&s->codec);
    free(s->bytes);free(s);return ok;
}

int ring_image_encode_memory(const uint8_t *rgba,int width,int height,int stride,
    const uint8_t *icc,size_t icc_size,const uint8_t *exif,size_t exif_size,
    int webp,int quality,int target_bytes,int threads,uint8_t **output,size_t *output_size,char *error,size_t error_size) {
    *output=NULL;*output_size=0;
    if(!rgba || width<1 || height<1 || width>65535 || height>65535 || stride<width*4 || quality<0 || quality>100)
        return message(error,error_size,"Invalid image encoder parameters");
    if(!webp) return memory_jpeg(rgba,width,height,stride,icc,icc_size,exif,exif_size,quality,output,output_size,error,error_size);
    WebPConfig config;WebPPicture picture;WebPMemoryWriter writer;
    WebPMux *mux=NULL;WebPData assembled={0};int ok=0;
    if(!WebPConfigInit(&config)||!WebPPictureInit(&picture)) return 0;
    config.quality=quality;config.method=4;config.thread_level=threads>1;
    config.use_sharp_yuv=1;config.alpha_quality=100;
    if(target_bytes>0) { config.target_size=target_bytes;config.pass=6; }
    picture.width=width;picture.height=height;picture.use_argb=1;
    WebPMemoryWriterInit(&writer);picture.writer=WebPMemoryWrite;picture.custom_ptr=&writer;
    if(!WebPPictureImportRGBA(&picture,rgba,stride)||!WebPValidateConfig(&config)||!WebPEncode(&config,&picture)) goto done;
    WebPData encoded={writer.mem,writer.size};mux=WebPMuxCreate(&encoded,1);
    if(!mux) goto done;
    if(icc_size) { WebPData d={icc,icc_size};if(WebPMuxSetChunk(mux,"ICCP",&d,1)!=WEBP_MUX_OK) goto done; }
    if(exif_size) { WebPData d={exif,exif_size};if(WebPMuxSetChunk(mux,"EXIF",&d,1)!=WEBP_MUX_OK) goto done; }
    if(WebPMuxAssemble(mux,&assembled)!=WEBP_MUX_OK) goto done;
    *output=malloc(assembled.size);
    if(!*output) goto done;
    memcpy(*output,assembled.bytes,assembled.size);*output_size=assembled.size;ok=1;
done:
    if(!ok) message(error,error_size,"WebP memory encoding failed");
    WebPDataClear(&assembled);if(mux) WebPMuxDelete(mux);
    WebPMemoryWriterClear(&writer);WebPPictureFree(&picture);return ok;
}

void *ring_webp_animation_create(int width,int height) {
    WebPAnimEncoderOptions options;
    if(!WebPAnimEncoderOptionsInit(&options)) return NULL;
    options.anim_params.loop_count=0;
    // Avoid encoding both a sub-frame and a key-frame candidate. Independent
    // parallel segments already start with a complete frame.
    options.kmax=0;
    return WebPAnimEncoderNew(width,height,&options);
}
int ring_webp_animation_add(void *animation,const uint8_t *rgba,int width,int height,int timestamp,int quality,int threads) {
    WebPPicture picture;WebPConfig config;
    if(!animation || !WebPPictureInit(&picture)||!WebPConfigInit(&config)) return 0;
    picture.width=width;picture.height=height;picture.use_argb=1;
    config.quality=quality;config.method=4;config.thread_level=threads>1;config.use_sharp_yuv=1;
    int ok=WebPPictureImportRGBA(&picture,rgba,width*4) && WebPAnimEncoderAdd(animation,&picture,timestamp,&config);
    WebPPictureFree(&picture);return ok;
}
int ring_webp_animation_finish(void *animation,int timestamp,uint8_t **output,size_t *size) {
    WebPData data={0};*output=NULL;*size=0;
    if(!WebPAnimEncoderAdd(animation,NULL,timestamp,NULL)||!WebPAnimEncoderAssemble(animation,&data)) return 0;
    *output=malloc(data.size);
    if(*output) { memcpy(*output,data.bytes,data.size);*size=data.size; }
    WebPDataClear(&data);return *output!=NULL;
}
void ring_webp_animation_destroy(void *animation) { if(animation) WebPAnimEncoderDelete(animation); }

void *ring_webp_mux_create(int width,int height) {
    WebPMux *mux=WebPMuxNew();
    WebPMuxAnimParams params={0xffffffff,0};
    if(!mux) return NULL;
    if(WebPMuxSetCanvasSize(mux,width,height)!=WEBP_MUX_OK ||
       WebPMuxSetAnimationParams(mux,&params)!=WEBP_MUX_OK) {
        WebPMuxDelete(mux);return NULL;
    }
    return mux;
}
int ring_webp_mux_append(void *opaque,const uint8_t *bytes,size_t size,int duration_ms) {
    if(!opaque || !bytes || !size || duration_ms<=0) return 0;
    WebPMux *mux=opaque;
    WebPData data={bytes,size};
    WebPMux *part=WebPMuxCreate(&data,0);
    if(!part) return 0;
    int w,h,pw,ph,n=0,total=0;
    int ok=WebPMuxGetCanvasSize(mux,&w,&h)==WEBP_MUX_OK &&
           WebPMuxGetCanvasSize(part,&pw,&ph)==WEBP_MUX_OK && w==pw && h==ph &&
           WebPMuxNumChunks(part,WEBP_CHUNK_ANMF,&n)==WEBP_MUX_OK;
    // libwebp collapses an unchanging segment to a still image. Restore its
    // duration and make its first frame replace the preceding segment's canvas.
    const int still=n==0;
    for(int i=1;ok && i<=(still?1:n);i++) {
        WebPMuxFrameInfo frame={0};
        ok=WebPMuxGetFrame(part,i,&frame)==WEBP_MUX_OK;
        if(ok && still) {
            frame.id=WEBP_CHUNK_ANMF;frame.duration=duration_ms;
            frame.x_offset=frame.y_offset=0;
            frame.dispose_method=WEBP_MUX_DISPOSE_NONE;
            frame.blend_method=WEBP_MUX_NO_BLEND;
        }
        if(ok) {
            if(frame.duration<0 || frame.duration>duration_ms-total) ok=0;
            else { total+=frame.duration;ok=WebPMuxPushFrame(mux,&frame,1)==WEBP_MUX_OK; }
        }
        WebPDataClear(&frame.bitstream);
    }
    WebPMuxDelete(part);return ok && total==duration_ms;
}
struct RingWebPDecoder { WebPData data;WebPAnimDecoder *decoder; };
void ring_webp_image_decoder_destroy(void *opaque) {
    struct RingWebPDecoder *value=opaque;
    if(value) { if(value->decoder) WebPAnimDecoderDelete(value->decoder);WebPDataClear(&value->data);free(value); }
}
void *ring_webp_image_decoder_create(const uint8_t *bytes,size_t size,int threads,int *width,int *height,int *frames,int *loops) {
    if(!bytes || !size || !width || !height || !frames || !loops) return NULL;
    struct RingWebPDecoder *value=calloc(1,sizeof(*value));
    if(!value) return NULL;
    WebPData data={bytes,size};WebPAnimDecoderOptions options;WebPAnimInfo info;
    if(!WebPDataCopy(&data,&value->data) || !WebPAnimDecoderOptionsInit(&options)) goto error;
    options.color_mode=MODE_RGBA;options.use_threads=threads>1;
    value->decoder=WebPAnimDecoderNew(&value->data,&options);
    if(!value->decoder || !WebPAnimDecoderGetInfo(value->decoder,&info) || info.canvas_width>16383 || info.canvas_height>16383 || info.frame_count>10000) goto error;
    *width=(int)info.canvas_width;*height=(int)info.canvas_height;*frames=(int)info.frame_count;*loops=(int)info.loop_count;
    return value;
error:
    ring_webp_image_decoder_destroy(value);return NULL;
}
int ring_webp_image_decoder_next(void *opaque,const uint8_t **pixels) {
    struct RingWebPDecoder *value=opaque;uint8_t *frame=NULL;int timestamp;
    if(!value || !pixels || !WebPAnimDecoderGetNext(value->decoder,&frame,&timestamp)) return 0;
    *pixels=frame;return 1;
}
void ring_webp_image_decoder_reset(void *opaque) {
    struct RingWebPDecoder *value=opaque;
    if(value) WebPAnimDecoderReset(value->decoder);
}

// Animated image edits use full composited frames, with no palette quantization
// or lossy generation. The video encoder above retains its existing settings.
void *ring_webp_lossless_mux_create(int width,int height,int loop_count,const uint8_t *icc,size_t icc_size) {
    if(width<1 || height<1 || width>16383 || height>16383 || loop_count<0 || loop_count>65535) return NULL;
    WebPMux *mux=WebPMuxNew();
    WebPMuxAnimParams params={0,loop_count};
    if(!mux) return NULL;
    int ok=WebPMuxSetCanvasSize(mux,width,height)==WEBP_MUX_OK &&
        WebPMuxSetAnimationParams(mux,&params)==WEBP_MUX_OK;
    if(ok && icc_size) { WebPData profile={icc,icc_size};ok=icc && WebPMuxSetChunk(mux,"ICCP",&profile,1)==WEBP_MUX_OK; }
    if(!ok) { WebPMuxDelete(mux);return NULL; }
    return mux;
}
int ring_webp_lossless_mux_add(void *opaque,const uint8_t *rgba,int width,int height,int duration_ms,int threads,size_t *encoded_size) {
    if(!opaque || !rgba || !encoded_size || width<1 || height<1 || width>16383 || height>16383 || duration_ms<1 || duration_ms>0xffffff) return 0;
    int w,h;
    if(WebPMuxGetCanvasSize(opaque,&w,&h)!=WEBP_MUX_OK || w!=width || h!=height) return 0;
    WebPConfig config;WebPPicture picture;WebPMemoryWriter writer;
    if(!WebPConfigInit(&config) || !WebPConfigLosslessPreset(&config,4) || !WebPPictureInit(&picture)) return 0;
    config.exact=1;config.low_memory=1;config.thread_level=threads>1;
    picture.width=width;picture.height=height;picture.use_argb=1;
    WebPMemoryWriterInit(&writer);picture.writer=WebPMemoryWrite;picture.custom_ptr=&writer;
    int ok=WebPValidateConfig(&config) && WebPPictureImportRGBA(&picture,rgba,width*4) && WebPEncode(&config,&picture);
    if(ok) {
        WebPMuxFrameInfo frame={0};
        frame.bitstream.bytes=writer.mem;frame.bitstream.size=writer.size;
        frame.id=WEBP_CHUNK_ANMF;frame.duration=duration_ms;
        frame.dispose_method=WEBP_MUX_DISPOSE_NONE;frame.blend_method=WEBP_MUX_NO_BLEND;
        ok=WebPMuxPushFrame(opaque,&frame,1)==WEBP_MUX_OK;
        if(ok) *encoded_size=writer.size;
    }
    WebPMemoryWriterClear(&writer);WebPPictureFree(&picture);return ok;
}
int ring_webp_mux_finish(void *opaque,uint8_t **output,size_t *size) {
    if(!output || !size) return 0;
    *output=NULL;*size=0;
    if(!opaque) return 0;
    WebPMux *mux=opaque;
    int n=0;
    if(WebPMuxNumChunks(mux,WEBP_CHUNK_ANMF,&n)!=WEBP_MUX_OK || n==0) return 0;
    // MuxCleanup otherwise removes ANIM for a single full-canvas frame,
    // losing the duration of a completely still clip.
    if(n==1) {
        WebPMuxFrameInfo frame={0};
        if(WebPMuxGetFrame(mux,1,&frame)!=WEBP_MUX_OK) return 0;
        int duration=frame.duration;
        int ok=duration>=2 && WebPMuxDeleteFrame(mux,1)==WEBP_MUX_OK;
        frame.duration=duration/2;
        if(ok) ok=WebPMuxPushFrame(mux,&frame,1)==WEBP_MUX_OK;
        frame.duration=duration-duration/2;
        if(ok) ok=WebPMuxPushFrame(mux,&frame,1)==WEBP_MUX_OK;
        WebPDataClear(&frame.bitstream);
        if(!ok) return 0;
    }
    WebPData data={0};
    if(WebPMuxAssemble(mux,&data)!=WEBP_MUX_OK) return 0;
    *output=malloc(data.size);
    if(*output) {memcpy(*output,data.bytes,data.size);*size=data.size;}
    WebPDataClear(&data);return *output!=NULL;
}
void ring_webp_mux_destroy(void *mux) {if(mux) WebPMuxDelete(mux);}
int ring_inflate_raw(const uint8_t *source,size_t size,uint8_t *output,size_t output_size) {
    if(size>UINT_MAX || output_size>UINT_MAX) return 0;
    z_stream stream={0};stream.next_in=(Bytef *)source;stream.avail_in=(uInt)size;
    stream.next_out=output;stream.avail_out=(uInt)output_size;
    if(inflateInit2(&stream,-MAX_WBITS)!=Z_OK) return 0;
    int rc=inflate(&stream,Z_FINISH);
    int ok=rc==Z_STREAM_END && stream.total_in==size && stream.total_out==output_size;
    inflateEnd(&stream);return ok;
}
