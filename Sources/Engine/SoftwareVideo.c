#define _DARWIN_C_SOURCE
#include "SoftwareVideo.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/pixdesc.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/display.h>
#include <libavutil/sha.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/mathematics.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>

struct RingVideoDecoder {
    AVFormatContext *format;
    AVCodecContext *codec;
    AVPacket *packet;
    AVFrame *frame, *planar, *pending;
    struct SwsContext *scale;
    int video, audio, flushed, ended;
    RingVideoCancel cancel;
    void *context;
};
static int fail(char *error, int code, const char *message) {
    if (error) snprintf(error,512,"%s",message); return code;
}
static int avfail(char *error, int code, const char *operation, int status) {
    char detail[AV_ERROR_MAX_STRING_SIZE]; av_strerror(status,detail,sizeof(detail));
    if(error) snprintf(error,512,"%s: %s",operation,detail); return code;
}
static int interrupted(void *opaque) {
    RingVideoDecoder *d=opaque; return d->cancel && d->cancel(d->context);
}
static int stopped(RingVideoDecoder *d,char *error) {
    return interrupted(d) ? fail(error,3,"작업이 취소됐어요.") : 0;
}
static const char *frame_restriction(const AVFrame *f) {
    const AVPixFmtDescriptor *p=av_pix_fmt_desc_get(f->format);
    if(!p) return "지원하지 않는 픽셀 형식이에요.";
    if(p->flags & AV_PIX_FMT_FLAG_ALPHA) return "투명 영상은 소프트웨어 재압축을 지원하지 않아요.";
    for(int i=0;i<p->nb_components;i++) if(p->comp[i].depth>8) return "고비트 심도 영상은 8비트로 낮추지 않아요.";
    if(f->color_trc==AVCOL_TRC_SMPTE2084 || f->color_trc==AVCOL_TRC_ARIB_STD_B67)
        return "HDR 영상은 SDR로 낮추지 않아요.";
    if(av_frame_get_side_data(f,AV_FRAME_DATA_MASTERING_DISPLAY_METADATA)||av_frame_get_side_data(f,AV_FRAME_DATA_CONTENT_LIGHT_LEVEL)||av_frame_get_side_data(f,AV_FRAME_DATA_DOVI_METADATA))
        return "HDR 메타데이터를 제거하지 않아요.";
    if(f->flags & AV_FRAME_FLAG_INTERLACED) return "인터레이스 영상은 소프트웨어 재압축을 지원하지 않아요.";
    if(f->width%2 || f->height%2) return "홀수 해상도 영상은 해상도를 바꾸지 않아요.";
    if(p->log2_chroma_w!=1 || p->log2_chroma_h!=1 || p->nb_components!=3)
        return "4:2:0 이외 영상의 색상 샘플링을 낮추지 않아요.";
    return NULL;
}
RingSoftwareVideoCapabilities ring_video_capabilities(void) {
    RingSoftwareVideoCapabilities c={0};
    c.h264=avcodec_find_encoder_by_name("libx264")!=NULL;
    c.hevc=avcodec_find_encoder_by_name("libx265")!=NULL;
    c.av1=avcodec_find_encoder_by_name("libsvtav1")!=NULL && avcodec_find_decoder_by_name("libaom-av1")!=NULL;
    c.opus=avcodec_find_encoder_by_name("libopus")!=NULL;
    c.mp4=av_guess_format("mp4",NULL,NULL)!=NULL;
    c.mov=av_guess_format("mov",NULL,NULL)!=NULL;
    c.webm=av_guess_format("webm",NULL,NULL)!=NULL;
    return c;
}
RingVideoDecoder *ring_video_decoder_create(const char *path, RingVideoCancel cancel, void *context, char *error) {
    RingVideoDecoder *d=calloc(1,sizeof(*d)); if(!d){fail(error,4,"메모리가 부족해요.");return NULL;}
    d->video=d->audio=-1; d->cancel=cancel;d->context=context;
    d->format=avformat_alloc_context(); if(!d->format) goto memory;
    d->format->interrupt_callback=(AVIOInterruptCB){interrupted,d};
    int r=avformat_open_input(&d->format,path,NULL,NULL);
    if(r<0){avfail(error,interrupted(d)?3:2,"영상 열기 실패",r);goto bad;}
    r=avformat_find_stream_info(d->format,NULL);
    if(r<0){avfail(error,interrupted(d)?3:2,"영상 정보 읽기 실패",r);goto bad;}
    int nv=0,na=0;
    for(unsigned i=0;i<d->format->nb_streams;i++) {
        AVStream *s=d->format->streams[i];
        if(s->codecpar->codec_type==AVMEDIA_TYPE_VIDEO){d->video=i;nv++;}
        else if(s->codecpar->codec_type==AVMEDIA_TYPE_AUDIO){d->audio=i;na++;}
        else { fail(error,1,"영상과 음성 이외 트랙이 있는 파일은 변환하지 않아요.");goto bad; }
    }
    if(nv!=1 || na>1){fail(error,1,"영상 1트랙·음성 최대 1트랙만 지원해요.");goto bad;}
    AVCodecParameters *par=d->format->streams[d->video]->codecpar;
    const AVCodec *codec=par->codec_id==AV_CODEC_ID_AV1 ? avcodec_find_decoder_by_name("libaom-av1") : avcodec_find_decoder(par->codec_id);
    if(!codec){fail(error,1,"이 영상 디코더가 포함되어 있지 않아요.");goto bad;}
    d->codec=avcodec_alloc_context3(codec);if(!d->codec)goto memory;
    r=avcodec_parameters_to_context(d->codec,par);if(r<0){avfail(error,2,"디코더 정보 실패",r);goto bad;}
    d->codec->pkt_timebase=d->format->streams[d->video]->time_base;
    d->codec->thread_count=4;d->codec->err_recognition=AV_EF_CRCCHECK|AV_EF_BITSTREAM|AV_EF_BUFFER|AV_EF_EXPLODE;
    r=avcodec_open2(d->codec,codec,NULL);if(r<0){avfail(error,1,"디코더 열기 실패",r);goto bad;}
    d->packet=av_packet_alloc();d->frame=av_frame_alloc();d->planar=av_frame_alloc();
    if(!d->packet||!d->frame||!d->planar)goto memory;
    return d;
memory:fail(error,4,"메모리가 부족해요.");
bad:ring_video_decoder_destroy(d);return NULL;
}
static int read_native(RingVideoDecoder *d,char *error) {
    if(d->ended)return 0;
    while(1){
        if(stopped(d,error))return -3;
        av_frame_unref(d->frame);
        int r=avcodec_receive_frame(d->codec,d->frame);
        if(r>=0){
            if(d->frame->flags&AV_FRAME_FLAG_CORRUPT || d->frame->decode_error_flags)
                return -fail(error,2,"손상된 영상 프레임을 발견했어요.");
            if(d->frame->best_effort_timestamp==AV_NOPTS_VALUE)
                return -fail(error,2,"영상 프레임 시각이 없어요.");
            d->frame->pts=d->frame->best_effort_timestamp;
            return 1;
        }
        if(r==AVERROR_EOF){d->ended=1;return 0;}
        if(r!=AVERROR(EAGAIN))return -avfail(error,2,"영상 디코딩 실패",r);
        if(d->flushed)return -fail(error,2,"영상 디코더가 정상 종료하지 않았어요.");
        while(1){
            r=av_read_frame(d->format,d->packet);
            if(r==AVERROR_EOF){d->flushed=1;r=avcodec_send_packet(d->codec,NULL);break;}
            if(r<0)return -avfail(error,interrupted(d)?3:2,"영상 패킷 읽기 실패",r);
            if(d->packet->flags&AV_PKT_FLAG_CORRUPT){av_packet_unref(d->packet);return -fail(error,2,"손상된 영상 패킷을 발견했어요.");}
            if(d->packet->stream_index!=d->video){av_packet_unref(d->packet);continue;}
            r=avcodec_send_packet(d->codec,d->packet);av_packet_unref(d->packet);break;
        }
        if(r<0 && r!=AVERROR_EOF)return -avfail(error,2,"영상 패킷 디코딩 실패",r);
    }
}
static int64_t last_display_duration(RingVideoDecoder *d,AVFrame *frame){
    AVStream *stream=d->format->streams[d->video];
    if(stream->duration!=AV_NOPTS_VALUE&&stream->duration>0){
        int64_t start=stream->start_time==AV_NOPTS_VALUE?0:stream->start_time;
        int64_t remaining=start+stream->duration-frame->pts;
        if(remaining>0)return remaining;
    }
    return frame->duration;
}
/* Packet durations in a reordered stream are decode-order durations. Display
   duration is the hold until the next presented frame; the final hold ends at
   the original video track endpoint. Keep one frame of lookahead, bounded RAM. */
static int next_native(RingVideoDecoder *d,char *error){
    if(!d->pending){
        d->pending=av_frame_alloc();if(!d->pending)return -fail(error,4,"메모리가 부족해요.");
        int r=read_native(d,error);if(r<=0)return r;av_frame_move_ref(d->pending,d->frame);
    }
    if(!d->pending->buf[0])return 0;
    int r=read_native(d,error);if(r<0)return r;
    if(r>0){
        int64_t delta=d->frame->pts-d->pending->pts;
        if(delta<=0)return -fail(error,2,"영상 표시 시각이 증가하지 않아요.");
        d->pending->duration=delta;
    }else d->pending->duration=last_display_duration(d,d->pending);
    AVFrame *next=d->frame;d->frame=d->pending;d->pending=next;
    return 1;
}
int ring_video_decoder_next(RingVideoDecoder *d, RingSoftwareVideoFrame *frame, char *error) {
    if(!d||!frame)return -fail(error,2,"디코더가 없어요.");
    int r=next_native(d,error);if(r<=0)return r;
    const char *restriction=frame_restriction(d->frame);if(restriction)return -fail(error,1,restriction);
    AVFrame *f=d->frame;
    if(f->format!=AV_PIX_FMT_YUV420P && f->format!=AV_PIX_FMT_YUVJ420P){
        av_frame_unref(d->planar);d->planar->format=AV_PIX_FMT_YUV420P;d->planar->width=f->width;d->planar->height=f->height;
        if(av_frame_get_buffer(d->planar,32)<0)return -fail(error,4,"메모리가 부족해요.");
        d->scale=sws_getCachedContext(d->scale,f->width,f->height,f->format,f->width,f->height,AV_PIX_FMT_YUV420P,SWS_POINT,NULL,NULL,NULL);
        if(!d->scale || sws_scale(d->scale,(const uint8_t *const *)f->data,f->linesize,0,f->height,d->planar->data,d->planar->linesize)!=f->height)
            return -fail(error,4,"영상 픽셀을 읽지 못했어요.");
        f=d->planar;
    }
    AVRational tb=d->format->streams[d->video]->time_base;
    *frame=(RingSoftwareVideoFrame){f->data[0],f->data[1],f->data[2],f->linesize[0],f->linesize[1],f->linesize[2],f->width,f->height,
        d->frame->pts,d->frame->duration,tb.num,tb.den,d->frame->color_primaries,d->frame->color_trc,d->frame->colorspace,d->frame->color_range};
    return 1;
}
void ring_video_decoder_destroy(RingVideoDecoder *d){
    if(!d)return;avformat_close_input(&d->format);avcodec_free_context(&d->codec);av_packet_free(&d->packet);
    av_frame_free(&d->frame);av_frame_free(&d->planar);av_frame_free(&d->pending);sws_freeContext(d->scale);free(d);
}
int ring_video_same_timing(const RingSoftwareVideoFrame *a,const RingSoftwareVideoFrame *b){
    if(!a||!b||a->time_base_num<=0||b->time_base_num<=0||a->time_base_den<=0||b->time_base_den<=0||
       a->pts==AV_NOPTS_VALUE||b->pts==AV_NOPTS_VALUE||a->duration<=0||b->duration<=0||
       a->pts>INT64_MAX-a->duration||b->pts>INT64_MAX-b->duration)return 0;
    AVRational ta={a->time_base_num,a->time_base_den},tb={b->time_base_num,b->time_base_den},ns={1,1000000000};
    return av_rescale_q(a->pts,ta,ns)==av_rescale_q(b->pts,tb,ns)&&
           av_rescale_q(a->pts+a->duration,ta,ns)==av_rescale_q(b->pts+b->duration,tb,ns);
}
static void hash_timing(struct AVSHA *sha,int64_t pts,int64_t duration,AVRational tb){
    int64_t begin=pts==AV_NOPTS_VALUE?INT64_MIN:av_rescale_q(pts,tb,(AVRational){1,1000000000});
    int64_t end=pts==AV_NOPTS_VALUE?INT64_MIN:av_rescale_q(pts+duration,tb,(AVRational){1,1000000000});
    int64_t values[2]={begin,pts==AV_NOPTS_VALUE?av_rescale_q(duration,tb,(AVRational){1,1000000000}):end-begin};
    unsigned char bytes[16];for(int v=0;v<2;v++)for(int i=0;i<8;i++)bytes[v*8+i]=(uint64_t)values[v]>>(i*8);
    av_sha_update(sha,bytes,sizeof(bytes));
}
static double seconds(int64_t t,AVRational tb){return t==AV_NOPTS_VALUE?0:t*av_q2d(tb);}
static double stream_duration(AVStream *s){return seconds(s->duration,s->time_base);}
int ring_video_inspect(const char *path,int decode_all,RingSoftwareVideoInfo *info,RingVideoCancel cancel,void *context,char *error){
    if(!info)return fail(error,2,"출력 정보가 없어요.");memset(info,0,sizeof(*info));
    RingVideoDecoder *d=ring_video_decoder_create(path,cancel,context,error);if(!d)return cancel&&cancel(context)?3:2;
    int status=0;AVStream *s=d->format->streams[d->video];AVCodecParameters *p=s->codecpar;
    info->video_tracks=1;info->audio_tracks=d->audio>=0;info->width=p->width;info->height=p->height;
    info->video_codec=p->codec_id==AV_CODEC_ID_H264?1:p->codec_id==AV_CODEC_ID_HEVC?2:p->codec_id==AV_CODEC_ID_AV1?3:0;info->duration=seconds(d->format->duration,AV_TIME_BASE_Q);info->video_duration=stream_duration(s);
    info->frame_rate=av_q2d(s->avg_frame_rate);info->video_bitrate=p->bit_rate;info->frame_count=s->nb_frames;
    info->color_primaries=p->color_primaries;info->color_transfer=p->color_trc;info->color_space=p->color_space;info->color_range=p->color_range;
    info->time_base_num=s->time_base.num;info->time_base_den=s->time_base.den;
    const AVPixFmtDescriptor *desc=av_pix_fmt_desc_get(p->format);info->bit_depth=desc?desc->comp[0].depth:p->bits_per_raw_sample;
    AVFrame metadata={0};metadata.format=p->format;metadata.width=p->width;metadata.height=p->height;metadata.color_trc=p->color_trc;
    const char *metadata_restriction=desc?frame_restriction(&metadata):NULL;
    if(!metadata_restriction&&info->bit_depth>8)metadata_restriction="고비트 심도 영상은 8비트로 낮추지 않아요.";
    if(!metadata_restriction&&(p->color_trc==AVCOL_TRC_SMPTE2084||p->color_trc==AVCOL_TRC_ARIB_STD_B67))metadata_restriction="HDR 영상은 SDR로 낮추지 않아요.";
    if(!metadata_restriction&&p->sample_aspect_ratio.num&&av_cmp_q(p->sample_aspect_ratio,(AVRational){1,1})!=0)metadata_restriction="비정방형 픽셀은 변경하지 않아요.";
    if(metadata_restriction){info->restricted=1;snprintf(info->restriction,sizeof(info->restriction),"%s",metadata_restriction);}
    const AVPacketSideData *side=av_packet_side_data_get(p->coded_side_data,p->nb_coded_side_data,AV_PKT_DATA_DISPLAYMATRIX);
    if(side && side->size>=9*sizeof(int32_t)){info->rotation=av_display_rotation_get((int32_t *)side->data);memcpy(info->display_matrix,side->data,9*sizeof(int32_t));info->has_display_matrix=1;}
    if(d->audio>=0){AVStream *a=d->format->streams[d->audio];info->audio_codec=a->codecpar->codec_id;info->audio_duration=stream_duration(a);
        info->webm_audio_copy=a->codecpar->codec_id==AV_CODEC_ID_OPUS||a->codecpar->codec_id==AV_CODEC_ID_VORBIS;info->audio_channels=a->codecpar->ch_layout.nb_channels;info->audio_sample_rate=a->codecpar->sample_rate;info->audio_bitrate=a->codecpar->bit_rate;}
    if(d->audio<0)info->webm_audio_copy=1;
    if(decode_all){
        struct AVSHA *timeline=av_sha_alloc();if(!timeline){status=fail(error,4,"메모리가 부족해요.");goto done;}av_sha_init(timeline,256);
        info->frame_count=0;double previous=-INFINITY;
        int r;while((r=next_native(d,error))>0){
            AVFrame *f=d->frame;double pts=seconds(f->pts,s->time_base);
            if(pts<=previous){av_free(timeline);status=fail(error,2,"영상 프레임 시각이 증가하지 않아요.");goto done;}
            hash_timing(timeline,f->pts,f->duration,s->time_base);
            previous=pts;if(!info->frame_count)info->first_pts=pts;info->last_pts=pts;info->last_duration=seconds(f->duration,s->time_base);info->frame_count++;
            const char *restriction=frame_restriction(f);if(restriction){info->restricted=1;snprintf(info->restriction,sizeof(info->restriction),"%s",restriction);}
            if(f->width!=info->width||f->height!=info->height){info->restricted=1;snprintf(info->restriction,sizeof(info->restriction),"도중에 해상도가 바뀌는 영상은 지원하지 않아요.");}
        }
        av_sha_final(timeline,info->decoded_timeline_sha256);av_free(timeline);
        if(r<0){status=-r;goto done;}
        if(!info->frame_count){status=fail(error,2,"영상 프레임이 없어요.");goto done;}
        if(info->last_duration>0)info->video_duration=info->last_pts+info->last_duration-info->first_pts;
    }
    // A separate demux pass counts original payload bytes and hashes audio packets.
    AVFormatContext *scan=NULL;AVPacket *pkt=av_packet_alloc();struct AVSHA *sha=av_sha_alloc();
    if(!pkt||!sha){av_packet_free(&pkt);av_free(sha);status=fail(error,4,"메모리가 부족해요.");goto done;}
    av_sha_init(sha,256);struct AVSHA *audio_timing=av_sha_alloc();
    if(!audio_timing){av_packet_free(&pkt);av_free(sha);status=fail(error,4,"메모리가 부족해요.");goto done;}av_sha_init(audio_timing,256);
    int r=avformat_open_input(&scan,path,NULL,NULL);
    if(r>=0){scan->interrupt_callback=(AVIOInterruptCB){interrupted,d};r=avformat_find_stream_info(scan,NULL);}
    if(r<0){status=avfail(error,2,"패킷 검증 실패",r);goto scanned;}
    double audio_end=-INFINITY,audio_start=INFINITY;
    int pcm_frame_bytes=0;int64_t pcm_start=AV_NOPTS_VALUE,pcm_samples=0;
    if(d->audio>=0){
        AVStream *a=scan->streams[d->audio];AVCodecParameters *p=a->codecpar;
        int bits=av_get_bits_per_sample(p->codec_id);
        if(!strncmp(avcodec_get_name(p->codec_id),"pcm_",4)&&bits>0&&bits%8==0&&
           a->time_base.num==1&&a->time_base.den==p->sample_rate)
            pcm_frame_bytes=bits/8*p->ch_layout.nb_channels;
    }
    while((r=av_read_frame(scan,pkt))>=0){
        if(stopped(d,error)){status=3;av_packet_unref(pkt);break;}
        if(pkt->flags&AV_PKT_FLAG_CORRUPT){status=fail(error,2,"손상된 패킷을 발견했어요.");av_packet_unref(pkt);break;}
        if(pkt->stream_index==d->video)info->video_bytes+=pkt->size;
        if(pkt->stream_index==d->audio){
            AVStream *a=scan->streams[pkt->stream_index];info->audio_bytes+=pkt->size;
            if(pkt->pts!=AV_NOPTS_VALUE){double start=seconds(pkt->pts,a->time_base);audio_start=fmin(audio_start,start);audio_end=fmax(audio_end,start+seconds(pkt->duration,a->time_base));}
            av_sha_update(sha,pkt->data,pkt->size);
            if(pcm_frame_bytes){
                // MOV/MP4 can regroup unchanged PCM into different packets.
                // Hash continuous sample intervals, checking every packet's
                // sample count and boundary, rather than its arbitrary grouping.
                int64_t samples=pkt->size/pcm_frame_bytes;
                if(pkt->pts==AV_NOPTS_VALUE||pkt->size%pcm_frame_bytes||samples<=0||pkt->duration!=samples){
                    status=fail(error,2,"PCM 음성의 표본 시각·길이가 올바르지 않아요.");av_packet_unref(pkt);break;
                }
                if(pcm_start==AV_NOPTS_VALUE||pkt->pts!=pcm_start+pcm_samples){
                    if(pcm_samples)hash_timing(audio_timing,pcm_start,pcm_samples,a->time_base);
                    pcm_start=pkt->pts;pcm_samples=0;
                }
                pcm_samples+=samples;
            }else hash_timing(audio_timing,pkt->pts,pkt->duration,a->time_base);
        }
        av_packet_unref(pkt);
    }
    if(r<0&&r!=AVERROR_EOF&&!status)status=avfail(error,2,"패킷 검증 실패",r);
    if(pcm_samples)hash_timing(audio_timing,pcm_start,pcm_samples,scan->streams[d->audio]->time_base);
    if(isfinite(audio_end)&&isfinite(audio_start)) {
        AVCodecParameters *audio_parameters=d->format->streams[d->audio]->codecpar;
        double padding=audio_parameters->sample_rate>0?(double)audio_parameters->initial_padding/audio_parameters->sample_rate:0;
        info->audio_start=fmax(0,audio_start+padding);
        info->audio_duration=audio_end-info->audio_start;
    }
    av_sha_final(sha,info->audio_sha256);av_sha_final(audio_timing,info->audio_timing_sha256);
scanned:av_packet_free(&pkt);av_free(sha);av_free(audio_timing);avformat_close_input(&scan);
done:ring_video_decoder_destroy(d);return status;
}

typedef struct Timing { int64_t pts,duration; struct Timing *next; } Timing;
typedef struct {
    AVFormatContext *output;
    AVCodecContext *video,*audio,*audio_decoder;
    AVStream *video_stream,*audio_stream;
    SwrContext *resample;
    AVAudioFifo *fifo;
    AVPacket *packet;
    AVFrame *held_video;
    Timing *timings;
    int64_t audio_pts;
    int audio_started;
    RingVideoDecoder *input;
    const RingSoftwareVideoOptions *options;
    char *error;
} Encoder;
static int drain_encoder(Encoder *e,AVCodecContext *codec,AVStream *stream,int video){
    while(1){
        int r=avcodec_receive_packet(codec,e->packet);
        if(r==AVERROR(EAGAIN)||r==AVERROR_EOF)return 0;
        if(r<0)return avfail(e->error,4,"인코딩 패킷 실패",r);
        if(video){
            Timing **at=&e->timings;
            while(*at && (*at)->pts!=e->packet->pts)at=&(*at)->next;
            if(!*at){av_packet_unref(e->packet);return fail(e->error,4,"인코더가 원본 프레임 시각을 보존하지 못했어요.");}
            Timing *t=*at;e->packet->duration=t->duration;*at=t->next;free(t);
        }
        av_packet_rescale_ts(e->packet,codec->time_base,stream->time_base);e->packet->stream_index=stream->index;
        r=av_interleaved_write_frame(e->output,e->packet);av_packet_unref(e->packet);
        if(r<0)return avfail(e->error,interrupted(e->input)?3:4,"출력 쓰기 실패",r);
        if(stopped(e->input,e->error))return 3;
    }
}
static int submit_video(Encoder *e,AVFrame *f){
    const char *restriction=frame_restriction(f);if(restriction)return fail(e->error,1,restriction);
    if(f->width!=e->video->width||f->height!=e->video->height ||
       f->color_primaries!=e->video->color_primaries||f->color_trc!=e->video->color_trc||f->colorspace!=e->video->colorspace||f->color_range!=e->video->color_range)
        return fail(e->error,1,"도중에 영상 크기·색상 정보가 달라지면 재압축하지 않아요.");
    if(f->pts==AV_NOPTS_VALUE||f->duration<=0)return fail(e->error,1,"원본 프레임 시각·길이가 없어 보존할 수 없어요.");
    if(f->flags&AV_FRAME_FLAG_CORRUPT||f->decode_error_flags)return fail(e->error,2,"손상된 영상 프레임을 발견했어요.");
    // The decoder and encoder share 8-bit planar 4:2:0; no color conversion occurs.
    if(f->format!=AV_PIX_FMT_YUV420P && f->format!=AV_PIX_FMT_YUVJ420P)
        return fail(e->error,1,"변환 없는 8비트 4:2:0 픽셀만 인코딩해요.");
    f->format=AV_PIX_FMT_YUV420P;f->pict_type=AV_PICTURE_TYPE_NONE;
    Timing *t=calloc(1,sizeof(*t));if(!t)return fail(e->error,4,"메모리가 부족해요.");
    t->pts=f->pts;t->duration=f->duration;t->next=e->timings;e->timings=t;
    int r=avcodec_send_frame(e->video,f);if(r<0)return avfail(e->error,4,"영상 인코딩 실패",r);
    return drain_encoder(e,e->video,e->video_stream,1);
}
static int receive_video(Encoder *e){
    AVFrame *f=e->input->frame;
    while(1){
        av_frame_unref(f);int r=avcodec_receive_frame(e->input->codec,f);
        if(r==AVERROR(EAGAIN)||r==AVERROR_EOF)return 0;
        if(r<0)return avfail(e->error,2,"원본 영상 디코딩 실패",r);
        f->pts=f->best_effort_timestamp;
        if(f->pts==AV_NOPTS_VALUE)return fail(e->error,2,"영상 표시 시각이 없어요.");
        if(e->held_video){
            int64_t delta=f->pts-e->held_video->pts;if(delta<=0)return fail(e->error,2,"영상 표시 시각이 증가하지 않아요.");
            e->held_video->duration=delta;int status=submit_video(e,e->held_video);if(status)return status;
            av_frame_unref(e->held_video);
        }else{e->held_video=av_frame_alloc();if(!e->held_video)return fail(e->error,4,"메모리가 부족해요.");}
        av_frame_move_ref(e->held_video,f);
    }
}
static int audio_fifo_encode(Encoder *e,int final){
    while(av_audio_fifo_size(e->fifo)>=e->audio->frame_size || (final&&av_audio_fifo_size(e->fifo)>0)){
        AVFrame *f=av_frame_alloc();if(!f)return fail(e->error,4,"메모리가 부족해요.");
        f->format=e->audio->sample_fmt;f->sample_rate=e->audio->sample_rate;av_channel_layout_copy(&f->ch_layout,&e->audio->ch_layout);
        f->nb_samples=FFMIN(av_audio_fifo_size(e->fifo),e->audio->frame_size);
        int r=av_frame_get_buffer(f,0);if(r<0){av_frame_free(&f);return avfail(e->error,4,"음성 버퍼 생성 실패",r);}
        av_audio_fifo_read(e->fifo,(void **)f->extended_data,f->nb_samples);f->pts=e->audio_pts;e->audio_pts+=f->nb_samples;
        r=avcodec_send_frame(e->audio,f);av_frame_free(&f);if(r<0)return avfail(e->error,4,"Opus 인코딩 실패",r);
        int status=drain_encoder(e,e->audio,e->audio_stream,0);if(status)return status;
    }
    return 0;
}
static int receive_audio(Encoder *e){
    AVFrame *f=av_frame_alloc();if(!f)return fail(e->error,4,"메모리가 부족해요.");
    int status=0;
    while(1){
        int r=avcodec_receive_frame(e->audio_decoder,f);
        if(r==AVERROR(EAGAIN)||r==AVERROR_EOF)break;
        if(r<0){status=avfail(e->error,2,"원본 음성 디코딩 실패",r);break;}
        if(f->flags&AV_FRAME_FLAG_CORRUPT||f->decode_error_flags){status=fail(e->error,2,"손상된 음성 프레임을 발견했어요.");break;}
        if(!e->audio_started){
            if(f->best_effort_timestamp==AV_NOPTS_VALUE){status=fail(e->error,1,"음성 프레임 시각이 없어요.");break;}
            e->audio_pts=av_rescale_q(f->best_effort_timestamp,e->input->format->streams[e->input->audio]->time_base,e->audio->time_base);e->audio_started=1;
        }
        int capacity=swr_get_out_samples(e->resample,f->nb_samples);uint8_t **samples=NULL;int linesize=0;
        r=av_samples_alloc_array_and_samples(&samples,&linesize,e->audio->ch_layout.nb_channels,capacity,e->audio->sample_fmt,0);
        if(r<0){status=avfail(e->error,4,"음성 메모리 부족",r);break;}
        r=swr_convert(e->resample,samples,capacity,(const uint8_t **)f->extended_data,f->nb_samples);
        if(r<0)status=avfail(e->error,4,"음성 리샘플 실패",r);
        else if(av_audio_fifo_write(e->fifo,(void **)samples,r)!=r)status=fail(e->error,4,"음성 버퍼 쓰기 실패");
        av_freep(&samples[0]);av_freep(&samples);av_frame_unref(f);
        if(status)break;status=audio_fifo_encode(e,0);if(status)break;
    }
    av_frame_free(&f);return status;
}
static int init_opus(Encoder *e){
    AVStream *in=e->input->format->streams[e->input->audio];
    const AVCodec *decoder=avcodec_find_decoder(in->codecpar->codec_id),*encoder=avcodec_find_encoder_by_name("libopus");
    if(!decoder||!encoder)return fail(e->error,1,"음성 디코더 또는 Opus 인코더가 포함되어 있지 않아요.");
    if(in->codecpar->ch_layout.nb_channels<1||in->codecpar->ch_layout.nb_channels>2)
        return fail(e->error,1,"Opus 변환은 모노·스테레오 음성만 지원해요. 채널을 낮추지 않아요.");
    e->audio_decoder=avcodec_alloc_context3(decoder);e->audio=avcodec_alloc_context3(encoder);
    if(!e->audio_decoder||!e->audio)return fail(e->error,4,"메모리가 부족해요.");
    int r=avcodec_parameters_to_context(e->audio_decoder,in->codecpar);if(r<0)return avfail(e->error,2,"음성 디코더 설정 실패",r);
    e->audio_decoder->pkt_timebase=in->time_base;e->audio_decoder->err_recognition=AV_EF_EXPLODE;
    r=avcodec_open2(e->audio_decoder,decoder,NULL);if(r<0)return avfail(e->error,1,"음성 디코더 열기 실패",r);
    e->audio->sample_rate=48000;e->audio->sample_fmt=AV_SAMPLE_FMT_FLT;e->audio->time_base=(AVRational){1,48000};
    e->audio->bit_rate=128000*in->codecpar->ch_layout.nb_channels/2;
    av_channel_layout_copy(&e->audio->ch_layout,&e->audio_decoder->ch_layout);
    if(e->output->oformat->flags&AVFMT_GLOBALHEADER)e->audio->flags|=AV_CODEC_FLAG_GLOBAL_HEADER;
    r=avcodec_open2(e->audio,encoder,NULL);if(r<0)return avfail(e->error,1,"Opus 인코더 열기 실패",r);
    r=swr_alloc_set_opts2(&e->resample,&e->audio->ch_layout,e->audio->sample_fmt,48000,
       &e->audio_decoder->ch_layout,e->audio_decoder->sample_fmt,e->audio_decoder->sample_rate,0,NULL);
    if(r>=0)r=swr_init(e->resample);if(r<0)return avfail(e->error,1,"음성 리샘플 설정 실패",r);
    e->fifo=av_audio_fifo_alloc(e->audio->sample_fmt,e->audio->ch_layout.nb_channels,1920);if(!e->fifo)return fail(e->error,4,"메모리가 부족해요.");
    e->audio_stream=avformat_new_stream(e->output,NULL);if(!e->audio_stream)return fail(e->error,4,"메모리가 부족해요.");
    e->audio_stream->time_base=e->audio->time_base;
    r=avcodec_parameters_from_context(e->audio_stream->codecpar,e->audio);return r<0?avfail(e->error,4,"Opus 트랙 생성 실패",r):0;
}
int ring_video_encode(const char *source,const char *destination,const RingSoftwareVideoOptions *options,
                      RingVideoProgress progress,RingVideoCancel cancel,void *context,char *error){
    if(!source||!destination||!options||options->codec<1||options->codec>3||options->container<1||options->container>3||options->bitrate<0)
        return fail(error,2,"영상 변환 설정이 올바르지 않아요.");
    if(options->container==2&&options->codec==3)return fail(error,1,"AV1은 MP4·WebM에서 지원해요.");
    if(options->container==3&&options->codec!=3)return fail(error,1,"WebM은 AV1 영상만 지원해요.");
    struct stat original,dest;
    if(stat(source,&original))return fail(error,4,"원본 파일을 읽지 못했어요.");
    if(!stat(destination,&dest))return fail(error,4,"출력 파일이 이미 있어요. 덮어쓰지 않아요.");
    if(cancel&&cancel(context))return fail(error,3,"작업이 취소됐어요.");
    RingSoftwareVideoInfo info;int status=ring_video_inspect(source,1,&info,cancel,context,error);if(status)return status;
    if(info.restricted)return fail(error,1,info.restriction);
    Encoder e={0};e.options=options;e.error=error;
    e.input=ring_video_decoder_create(source,cancel,context,error);if(!e.input)return cancel&&cancel(context)?3:2;
    const char *name=options->codec==1?"libx264":options->codec==2?"libx265":"libsvtav1";
    const char *format=options->container==1?"mp4":options->container==2?"mov":"webm";
    const AVCodec *codec=avcodec_find_encoder_by_name(name);
    if(!codec){status=fail(error,1,"선택한 소프트웨어 인코더가 포함되어 있지 않아요.");goto done;}
    int r=avformat_alloc_output_context2(&e.output,NULL,format,NULL);
    if(r<0||!e.output){status=avfail(error,4,"출력 컨테이너 생성 실패",r);goto done;}
    e.output->interrupt_callback=(AVIOInterruptCB){interrupted,e.input};e.output->avoid_negative_ts=AVFMT_AVOID_NEG_TS_DISABLED;
    if(avformat_query_codec(e.output->oformat,codec->id,FF_COMPLIANCE_NORMAL)<=0){status=fail(error,1,"선택한 컨테이너와 영상 코덱이 호환되지 않아요.");goto done;}
    AVStream *in=e.input->format->streams[e.input->video];AVCodecParameters *par=in->codecpar;
    if(par->sample_aspect_ratio.num && av_cmp_q(par->sample_aspect_ratio,(AVRational){1,1})!=0){status=fail(error,1,"비정방형 픽셀은 변경하지 않아요.");goto done;}
    e.video=avcodec_alloc_context3(codec);e.packet=av_packet_alloc();
    if(!e.video||!e.packet){status=fail(error,4,"메모리가 부족해요.");goto done;}
    e.video->width=info.width;e.video->height=info.height;e.video->pix_fmt=AV_PIX_FMT_YUV420P;
    e.video->bit_rate=options->bitrate;e.video->time_base=in->time_base;e.video->framerate=in->avg_frame_rate;
    if(!e.video->framerate.num)e.video->framerate=av_guess_frame_rate(e.input->format,in,NULL);
    if(!e.video->framerate.num){status=fail(error,1,"원본 프레임률이 없어요.");goto done;}
    e.video->sample_aspect_ratio=(AVRational){1,1};e.video->max_b_frames=0;e.video->thread_count=4;
    e.video->gop_size=FFMAX(1,(int)llround(av_q2d(e.video->framerate)*2));
    e.video->color_primaries=par->color_primaries;e.video->color_trc=par->color_trc;e.video->colorspace=par->color_space;e.video->color_range=par->color_range;
    if(e.output->oformat->flags&AVFMT_GLOBALHEADER)e.video->flags|=AV_CODEC_FLAG_GLOBAL_HEADER;
    AVDictionary *settings=NULL;
    if(options->codec==1){av_dict_set(&settings,"preset","medium",0);av_dict_set(&settings,"x264-params","force-cfr=0:bframes=0:repeat-headers=0",0);}
    if(options->codec==2){av_dict_set(&settings,"preset","medium",0);av_dict_set(&settings,"x265-params","bframes=0:repeat-headers=0:pools=4:frame-threads=2:log-level=error",0);}
    if(options->codec==3){av_dict_set(&settings,"preset",options->compression_profile?"8":"6",0);av_dict_set(&settings,"svtav1-params","lp=4",0);}
    if(options->bitrate==0){
        av_dict_set(&settings,"crf",options->compression_profile ? (options->codec==3?"14":"16") : (options->codec==3?"8":"10"),0);
        if(options->codec==3)av_dict_set(&settings,"svtav1-params","lp=4:tune=1",0);
        else av_dict_set(&settings,"tune","psnr",0);
    }
    r=avcodec_open2(e.video,codec,&settings);av_dict_free(&settings);
    if(r<0){status=avfail(error,1,"소프트웨어 인코더 열기 실패",r);goto done;}
    e.video_stream=avformat_new_stream(e.output,NULL);if(!e.video_stream){status=fail(error,4,"메모리가 부족해요.");goto done;}
    e.video_stream->time_base=in->time_base;e.video_stream->avg_frame_rate=in->avg_frame_rate;e.video_stream->duration=in->duration;
    e.video_stream->sample_aspect_ratio=in->sample_aspect_ratio;
    r=avcodec_parameters_from_context(e.video_stream->codecpar,e.video);if(r<0){status=avfail(error,4,"영상 트랙 생성 실패",r);goto done;}
    if(codec->id==AV_CODEC_ID_HEVC)e.video_stream->codecpar->codec_tag=MKTAG('h','v','c','1');
    const AVPacketSideData *matrix=av_packet_side_data_get(par->coded_side_data,par->nb_coded_side_data,AV_PKT_DATA_DISPLAYMATRIX);
    if(matrix){
        AVPacketSideData *copy=av_packet_side_data_new(&e.video_stream->codecpar->coded_side_data,&e.video_stream->codecpar->nb_coded_side_data,
            AV_PKT_DATA_DISPLAYMATRIX,matrix->size,0);
        if(!copy){status=fail(error,4,"회전 정보 복사 실패");goto done;}memcpy(copy->data,matrix->data,matrix->size);
    }
    av_dict_copy(&e.video_stream->metadata,in->metadata,0);
    if(e.input->audio>=0){
        AVStream *audio=e.input->format->streams[e.input->audio];
        int compatible=options->container==3 ? (audio->codecpar->codec_id==AV_CODEC_ID_OPUS||audio->codecpar->codec_id==AV_CODEC_ID_VORBIS)
            : avformat_query_codec(e.output->oformat,audio->codecpar->codec_id,FF_COMPLIANCE_NORMAL)>0;
        if(!compatible){
            if(options->container!=3||!options->allow_opus_transcode){status=fail(error,1,"이 음성 코덱은 출력 컨테이너에 복사할 수 없어요. WebM의 Opus 변환은 명시적으로 선택해야 해요.");goto done;}
            status=init_opus(&e);if(status)goto done;
        }else{
            e.audio_stream=avformat_new_stream(e.output,NULL);if(!e.audio_stream){status=fail(error,4,"메모리가 부족해요.");goto done;}
            r=avcodec_parameters_copy(e.audio_stream->codecpar,audio->codecpar);if(r<0){status=avfail(error,4,"음성 복사 설정 실패",r);goto done;}
            e.audio_stream->codecpar->codec_tag=0;e.audio_stream->time_base=audio->time_base;e.audio_stream->duration=audio->duration;
            av_dict_copy(&e.audio_stream->metadata,audio->metadata,0);
        }
    }
    av_dict_copy(&e.output->metadata,e.input->format->metadata,0);
    char *temporary=malloc(strlen(destination)+32);if(!temporary){status=fail(error,4,"메모리가 부족해요.");goto done;}
    sprintf(temporary,"%s.ring-video-XXXXXX",destination);int fd=mkstemp(temporary);
    if(fd<0){free(temporary);status=fail(error,4,"출력 임시 파일을 만들지 못했어요.");goto done;}close(fd);
    e.output->url=av_strdup(temporary);if(!e.output->url){status=fail(error,4,"메모리가 부족해요.");goto tempdone;}
    r=avio_open(&e.output->pb,temporary,AVIO_FLAG_WRITE);if(r<0){status=avfail(error,4,"출력 파일 열기 실패",r);goto tempdone;}
    AVDictionary *mux=NULL;
    if(options->container!=3){av_dict_set(&mux,"movflags","+faststart",0);av_dict_set(&mux,"use_editlist","1",0);}
    r=avformat_write_header(e.output,&mux);av_dict_free(&mux);if(r<0){status=avfail(error,1,"출력 헤더 쓰기 실패",r);goto tempdone;}
    while((r=av_read_frame(e.input->format,e.input->packet))>=0){
        if(stopped(e.input,error)){status=3;break;}
        AVPacket *pkt=e.input->packet;
        if(pkt->flags&AV_PKT_FLAG_CORRUPT){status=fail(error,2,"손상된 원본 패킷을 발견했어요.");break;}
        if(pkt->stream_index==e.input->video){
            r=avcodec_send_packet(e.input->codec,pkt);if(r<0){status=avfail(error,2,"원본 영상 읽기 실패",r);break;}
            status=receive_video(&e);if(status)break;
            if(progress){double position=seconds(pkt->pts,in->time_base);progress(fmax(0,fmin(0.97,position/fmax(info.duration,0.001)*0.97)),context);}
        }else if(pkt->stream_index==e.input->audio){
            if(e.audio){r=avcodec_send_packet(e.audio_decoder,pkt);if(r<0){status=avfail(error,2,"원본 음성 읽기 실패",r);break;}
                status=receive_audio(&e);if(status)break;
            }else{
                av_packet_rescale_ts(pkt,e.input->format->streams[e.input->audio]->time_base,e.audio_stream->time_base);pkt->stream_index=e.audio_stream->index;
                r=av_interleaved_write_frame(e.output,pkt);if(r<0){status=avfail(error,4,"음성 복사 실패",r);break;}
            }
        }
        av_packet_unref(pkt);
    }
    av_packet_unref(e.input->packet);
    if(!status&&r!=AVERROR_EOF)status=avfail(error,interrupted(e.input)?3:2,"원본 읽기 실패",r);
    if(!status){r=avcodec_send_packet(e.input->codec,NULL);if(r<0&&r!=AVERROR_EOF)status=avfail(error,2,"원본 디코더 종료 실패",r);}
    if(!status)status=receive_video(&e);
    if(!status&&e.held_video&&e.held_video->buf[0]){e.held_video->duration=last_display_duration(e.input,e.held_video);status=submit_video(&e,e.held_video);}
    if(!status){r=avcodec_send_frame(e.video,NULL);if(r<0)status=avfail(error,4,"영상 인코더 종료 실패",r);}
    if(!status)status=drain_encoder(&e,e.video,e.video_stream,1);
    if(!status&&e.timings)status=fail(error,4,"인코더가 일부 프레임을 누락했어요.");
    if(!status&&e.audio){
        r=avcodec_send_packet(e.audio_decoder,NULL);if(r<0&&r!=AVERROR_EOF)status=avfail(error,2,"음성 디코더 종료 실패",r);
        if(!status)status=receive_audio(&e);
        if(!status){
            int capacity=swr_get_out_samples(e.resample,0);uint8_t **samples=NULL;int line=0;
            r=av_samples_alloc_array_and_samples(&samples,&line,e.audio->ch_layout.nb_channels,FFMAX(1,capacity),e.audio->sample_fmt,0);
            if(r<0)status=avfail(error,4,"음성 메모리 부족",r);
            else{r=swr_convert(e.resample,samples,capacity,NULL,0);if(r<0)status=avfail(error,4,"음성 리샘플 종료 실패",r);
                else if(av_audio_fifo_write(e.fifo,(void **)samples,r)!=r)status=fail(error,4,"음성 버퍼 쓰기 실패");
                av_freep(&samples[0]);av_freep(&samples);}
        }
        if(!status)status=audio_fifo_encode(&e,1);
        if(!status){r=avcodec_send_frame(e.audio,NULL);if(r<0)status=avfail(error,4,"Opus 인코더 종료 실패",r);}
        if(!status)status=drain_encoder(&e,e.audio,e.audio_stream,0);
    }
    if(!status){r=av_write_trailer(e.output);if(r<0)status=avfail(error,4,"출력 파일 마무리 실패",r);}
    if(!status&&stopped(e.input,error))status=3;
    if(e.output->pb){r=avio_closep(&e.output->pb);if(!status&&r<0)status=avfail(error,4,"출력 파일 닫기 실패",r);}
    if(!status){struct stat now;if(stat(source,&now)||now.st_size!=original.st_size||now.st_mtimespec.tv_sec!=original.st_mtimespec.tv_sec||now.st_mtimespec.tv_nsec!=original.st_mtimespec.tv_nsec)
        status=fail(error,2,"작업 중 원본 파일이 바뀌었어요.");}
    // link is an atomic, exclusive publication on the same filesystem. It never
    // replaces an existing path, including one created while encoding.
    if(!status&&link(temporary,destination))status=fail(error,4,"출력 파일을 확정하지 못했어요. 기존 파일은 덮어쓰지 않아요.");
    if(!status&&progress)progress(1,context);
tempdone:if(e.output&&e.output->pb)avio_closep(&e.output->pb);unlink(temporary);free(temporary);
done:
    while(e.timings){Timing *next=e.timings->next;free(e.timings);e.timings=next;}
    av_frame_free(&e.held_video);av_packet_free(&e.packet);avcodec_free_context(&e.video);avcodec_free_context(&e.audio);avcodec_free_context(&e.audio_decoder);
    swr_free(&e.resample);if(e.fifo)av_audio_fifo_free(e.fifo);avformat_free_context(e.output);ring_video_decoder_destroy(e.input);return status;
}

int ring_video_copy_nv12(const RingSoftwareVideoFrame *f,uint8_t *y,int ys,uint8_t *uv,int uvs){
    if(!f||!f->y||!f->u||!f->v||!y||!uv||f->width<1||f->height<1||ys<f->width||uvs<((f->width+1)/2)*2)return 0;
    for(int row=0;row<f->height;row++)memcpy(y+(size_t)row*ys,f->y+(size_t)row*f->y_stride,f->width);
    for(int row=0;row<(f->height+1)/2;row++){
        const uint8_t *u=f->u+(size_t)row*f->u_stride,*v=f->v+(size_t)row*f->v_stride;uint8_t *out=uv+(size_t)row*uvs;
        for(int x=0;x<(f->width+1)/2;x++){out[x*2]=u[x];out[x*2+1]=v[x];}
    }
    return 1;
}
static int next_mux_packet(AVFormatContext *input,AVPacket *packet,int stream,RingVideoCancel cancel,void *context,char *error){
    int r;
    while((r=av_read_frame(input,packet))>=0){
        if(cancel&&cancel(context)){av_packet_unref(packet);return -fail(error,3,"작업을 취소했어요.");}
        if(packet->stream_index==stream){
            if(packet->flags&AV_PKT_FLAG_CORRUPT){av_packet_unref(packet);return -fail(error,2,"손상된 미디어 패킷을 발견했어요.");}
            return 1;
        }
        av_packet_unref(packet);
    }
    return r==AVERROR_EOF?0:-avfail(error,2,"미디어 패킷 읽기 실패",r);
}
int ring_video_mux_original(const char *source,const char *video,const char *destination,int original_geometry,
                            RingVideoCancel cancel,void *context,char *error){
    AVFormatContext *original=NULL,*encoded=NULL,*output=NULL;AVPacket *vp=NULL,*ap=NULL;
    char *temporary=NULL;int status=0,r,vi=-1,ai=-1,oi=-1;
    struct stat before,after;
    if(!source||!video||!destination||!strcmp(source,destination)||!strcmp(video,destination)||stat(source,&before))return fail(error,2,"미디어 저장 경로 오류");
    r=avformat_open_input(&original,source,NULL,NULL);if(r>=0)r=avformat_find_stream_info(original,NULL);
    if(r<0){status=avfail(error,2,"원본 컨테이너 읽기 실패",r);goto done;}
    r=avformat_open_input(&encoded,video,NULL,NULL);if(r>=0)r=avformat_find_stream_info(encoded,NULL);
    if(r<0){status=avfail(error,2,"인코딩한 영상 읽기 실패",r);goto done;}
    vi=av_find_best_stream(encoded,AVMEDIA_TYPE_VIDEO,-1,-1,NULL,0);
    ai=av_find_best_stream(original,AVMEDIA_TYPE_AUDIO,-1,-1,NULL,0);
    oi=av_find_best_stream(original,AVMEDIA_TYPE_VIDEO,-1,-1,NULL,0);
    if(vi<0||oi<0){status=fail(error,2,"영상 트랙이 없어요.");goto done;}
    r=avformat_alloc_output_context2(&output,NULL,"mp4",NULL);if(r<0||!output){status=fail(error,4,"MP4 저장 준비 실패");goto done;}
    AVStream *vin=encoded->streams[vi],*vout=avformat_new_stream(output,NULL),*aout=NULL;
    if(!vout){status=fail(error,4,"영상 트랙 생성 실패");goto done;}
    r=avcodec_parameters_copy(vout->codecpar,vin->codecpar);if(r<0){status=avfail(error,4,"영상 정보 복사 실패",r);goto done;}
    vout->time_base=vin->time_base;vout->avg_frame_rate=vin->avg_frame_rate;vout->sample_aspect_ratio=vin->sample_aspect_ratio;vout->duration=vin->duration;
    av_dict_copy(&vout->metadata,vin->metadata,0);
    if(original_geometry){
        AVCodecParameters *par=original->streams[oi]->codecpar;
        av_packet_side_data_remove(vout->codecpar->coded_side_data,&vout->codecpar->nb_coded_side_data,AV_PKT_DATA_DISPLAYMATRIX);
        const AVPacketSideData *matrix=av_packet_side_data_get(par->coded_side_data,par->nb_coded_side_data,AV_PKT_DATA_DISPLAYMATRIX);
        if(matrix){AVPacketSideData *copy=av_packet_side_data_new(&vout->codecpar->coded_side_data,&vout->codecpar->nb_coded_side_data,AV_PKT_DATA_DISPLAYMATRIX,matrix->size,0);
            if(!copy){status=fail(error,4,"회전 정보 복사 실패");goto done;}memcpy(copy->data,matrix->data,matrix->size);}
    }
    if(ai>=0){
        AVStream *audio=original->streams[ai];
        if(avformat_query_codec(output->oformat,audio->codecpar->codec_id,FF_COMPLIANCE_NORMAL)<=0){status=fail(error,1,"MP4에 원본 음성을 그대로 저장할 수 없어요.");goto done;}
        aout=avformat_new_stream(output,NULL);if(!aout){status=fail(error,4,"음성 트랙 생성 실패");goto done;}
        r=avcodec_parameters_copy(aout->codecpar,audio->codecpar);if(r<0){status=avfail(error,4,"음성 정보 복사 실패",r);goto done;}
        aout->codecpar->codec_tag=0;aout->time_base=audio->time_base;av_dict_copy(&aout->metadata,audio->metadata,0);
    }
    av_dict_copy(&output->metadata,original->metadata,0);
    temporary=malloc(strlen(destination)+32);if(!temporary){status=fail(error,4,"메모리가 부족해요.");goto done;}
    sprintf(temporary,"%s.ring-mux-XXXXXX",destination);int fd=mkstemp(temporary);
    if(fd<0){status=fail(error,4,"MP4 임시 파일 생성 실패");goto done;}close(fd);
    output->url=av_strdup(temporary);if(!output->url){status=fail(error,4,"메모리가 부족해요.");goto done;}
    r=avio_open(&output->pb,temporary,AVIO_FLAG_WRITE);if(r<0){status=avfail(error,4,"MP4 파일 열기 실패",r);goto done;}
    int64_t movie_scale=vin->time_base.den;
    if(ai>=0){int64_t a=movie_scale,b=original->streams[ai]->time_base.den;
        while(b){int64_t next=a%b;a=b;b=next;}movie_scale=movie_scale/a*original->streams[ai]->time_base.den;}
    if(movie_scale<1||movie_scale>INT32_MAX){status=fail(error,1,"원본 시각 정밀도를 유지할 수 없어요.");goto done;}
    AVDictionary *settings=NULL;av_dict_set(&settings,"movflags","+faststart",0);
    av_dict_set_int(&settings,"movie_timescale",movie_scale,0);
    av_dict_set_int(&settings,"video_track_timescale",vin->time_base.den,0);
    r=avformat_write_header(output,&settings);av_dict_free(&settings);if(r<0){status=avfail(error,4,"MP4 헤더 저장 실패",r);goto done;}
    vp=av_packet_alloc();ap=av_packet_alloc();if(!vp||!ap){status=fail(error,4,"메모리가 부족해요.");goto done;}
    int hasv=next_mux_packet(encoded,vp,vi,cancel,context,error),hasa=ai>=0?next_mux_packet(original,ap,ai,cancel,context,error):0;
    while(hasv>0||hasa>0){
        if(cancel&&cancel(context)){status=fail(error,3,"작업을 취소했어요.");break;}
        int choosev=hasa<=0||(hasv>0&&av_compare_ts(vp->dts==AV_NOPTS_VALUE?vp->pts:vp->dts,vin->time_base,
            ap->dts==AV_NOPTS_VALUE?ap->pts:ap->dts,original->streams[ai]->time_base)<=0);
        AVPacket *packet=choosev?vp:ap;AVStream *in=choosev?vin:original->streams[ai],*out=choosev?vout:aout;
        av_packet_rescale_ts(packet,in->time_base,out->time_base);packet->stream_index=out->index;
        r=av_interleaved_write_frame(output,packet);av_packet_unref(packet);
        if(r<0){status=avfail(error,4,"MP4 패킷 저장 실패",r);break;}
        if(choosev)hasv=next_mux_packet(encoded,vp,vi,cancel,context,error);else hasa=next_mux_packet(original,ap,ai,cancel,context,error);
        if(hasv<0||hasa<0){status=hasv<0?-hasv:-hasa;break;}
    }
    if(!status&&(hasv<0||hasa<0))status=hasv<0?-hasv:-hasa;
    if(!status){r=av_write_trailer(output);if(r<0)status=avfail(error,4,"MP4 마감 실패",r);}
    if(output->pb){r=avio_closep(&output->pb);if(!status&&r<0)status=avfail(error,4,"MP4 닫기 실패",r);}
    if(!status&&(stat(source,&after)||before.st_size!=after.st_size||before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec||before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec))status=fail(error,2,"작업 중 원본이 바뀌었어요.");
    if(!status&&cancel&&cancel(context))status=fail(error,3,"작업을 취소했어요.");
    if(!status&&link(temporary,destination))status=fail(error,4,"기존 파일을 덮어쓰지 않아요.");
done:
    if(output&&output->pb)avio_closep(&output->pb);
    if(temporary){unlink(temporary);free(temporary);}av_packet_free(&vp);av_packet_free(&ap);
    avformat_close_input(&original);avformat_close_input(&encoded);avformat_free_context(output);return status;
}

int ring_video_decoder_seek(RingVideoDecoder *d,double time,char *error){
    if(!d||!isfinite(time)||time<0)return fail(error,2,"프레임 탐색 시각 오류");
    if(stopped(d,error))return 3;
    AVRational tb=d->format->streams[d->video]->time_base;
    int64_t target=av_rescale_q((int64_t)floor(time*1000000),(AVRational){1,1000000},tb);
    int r=avformat_seek_file(d->format,d->video,INT64_MIN,target,target,AVSEEK_FLAG_BACKWARD);
    if(r<0)return avfail(error,2,"원본 프레임 탐색 실패",r);
    avcodec_flush_buffers(d->codec);av_packet_unref(d->packet);av_frame_unref(d->frame);
    av_frame_free(&d->pending);
    d->flushed=0;d->ended=0;return 0;
}
int ring_video_presentation_times(const char *source,double start,double duration,RingVideoTimestamp callback,
                                  RingVideoCancel cancel,void *context,char *error){
    if(!source||!callback||!isfinite(start)||!isfinite(duration)||start<0||duration<=0)return fail(error,2,"영상 구간 오류");
    AVFormatContext *input=NULL;AVPacket *packet=NULL;int status=0,r,count=0;double previous=-INFINITY;
    r=avformat_open_input(&input,source,NULL,NULL);if(r>=0)r=avformat_find_stream_info(input,NULL);
    if(r<0){status=avfail(error,2,"원본 시각 읽기 실패",r);goto done;}
    int video=av_find_best_stream(input,AVMEDIA_TYPE_VIDEO,-1,-1,NULL,0);
    if(video<0){status=fail(error,2,"영상 트랙이 없어요.");goto done;}
    enum AVCodecID codec=input->streams[video]->codecpar->codec_id;
    if(codec!=AV_CODEC_ID_H264&&codec!=AV_CODEC_ID_HEVC&&codec!=AV_CODEC_ID_AV1){status=1;goto done;}
    packet=av_packet_alloc();if(!packet){status=fail(error,4,"메모리가 부족해요.");goto done;}
    while((r=av_read_frame(input,packet))>=0){
        if(cancel&&cancel(context)){status=fail(error,3,"작업을 취소했어요.");av_packet_unref(packet);break;}
        if(packet->stream_index==video&&!(packet->flags&AV_PKT_FLAG_DISCARD)){
            if(packet->flags&AV_PKT_FLAG_CORRUPT||packet->pts==AV_NOPTS_VALUE){status=fail(error,2,"원본 프레임 시각이 손상됐어요.");av_packet_unref(packet);break;}
            double time=seconds(packet->pts,input->streams[video]->time_base);
            if(time<=start)previous=fmax(previous,time);
            else if(time<start+duration){if(++count>1800){status=fail(error,1,"선택 구간은 최대 1,800프레임이어야 해요.");av_packet_unref(packet);break;}callback(time,context);}
        }
        av_packet_unref(packet);
    }
    if(!status&&r!=AVERROR_EOF)status=avfail(error,2,"원본 시각 읽기 실패",r);
    if(!status&&isfinite(previous))callback(previous,context);
done:av_packet_free(&packet);avformat_close_input(&input);return status;
}
