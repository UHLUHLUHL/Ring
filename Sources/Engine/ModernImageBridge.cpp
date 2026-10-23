#include "ModernImageBridge.h"
#include <avif/avif.h>
#include <jxl/decode.h>
#include <jxl/encode.h>
#include <jxl/thread_parallel_runner.h>
#include <jxl/color_encoding.h>
#include <algorithm>
#include <array>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
void require(bool ok,const char *message) { if(!ok) throw std::runtime_error(message); }
void errorText(char *error,size_t size,const std::exception &e) { if(error&&size) snprintf(error,size,"%s",e.what()); }
size_t pixelSize(const RingModernInfo &i) {
 require(i.width>0&&i.height>0&&i.width<=65535&&i.height<=65535&&int64_t(i.width)*i.height<=52000000,"Image exceeds 52MP limit");
 return size_t(i.width)*i.height*4;
}
int orientation(const avifImage *im) {
 // Match EXIF's eight affine orientations, retaining untransformed raster.
 int v=1;
 if(im->transformFlags&AVIF_TRANSFORM_IROT) { const int map[]={1,8,3,6};v=map[im->irot.angle&3]; }
 if(im->transformFlags&AVIF_TRANSFORM_IMIR) {
  const int horizontal[]={0,2,1,4,3,6,5,8,7};
  const int vertical[]={0,4,3,2,1,8,7,6,5};
  v=(im->imir.axis==1?horizontal:vertical)[v];
 }
 return v;
}
struct Reader {
 RingModernInfo info{};
 std::vector<uint8_t> bytes,icc,exif;
 std::vector<uint64_t> durations;
 avifDecoder *avif=nullptr;
 JxlDecoder *jxl=nullptr;
 void *runner=nullptr;
 int next=0;
 ~Reader(){if(avif)avifDecoderDestroy(avif);if(jxl)JxlDecoderDestroy(jxl);if(runner)JxlThreadParallelRunnerDestroy(runner);}
 void initJXL(bool scan) {
  if(jxl)JxlDecoderDestroy(jxl);
  jxl=JxlDecoderCreate(nullptr);require(jxl,"JXL decoder allocation failed");
  require(JxlDecoderSetParallelRunner(jxl,JxlThreadParallelRunner,runner)==JXL_DEC_SUCCESS,"JXL thread runner failed");
  require(JxlDecoderSetKeepOrientation(jxl,JXL_TRUE)==JXL_DEC_SUCCESS,"JXL orientation setup failed");
  require(JxlDecoderSetUnpremultiplyAlpha(jxl,JXL_TRUE)==JXL_DEC_SUCCESS,"JXL alpha setup failed");
  int events=JXL_DEC_BASIC_INFO|JXL_DEC_COLOR_ENCODING|JXL_DEC_FRAME|JXL_DEC_FULL_IMAGE;
  if(scan)events|=JXL_DEC_BOX;
  require(JxlDecoderSubscribeEvents(jxl,events)==JXL_DEC_SUCCESS,"JXL event setup failed");
  require(JxlDecoderSetInput(jxl,bytes.data(),bytes.size())==JXL_DEC_SUCCESS,"JXL input failed");JxlDecoderCloseInput(jxl);next=0;
 }
 void scanJXL() {
  initJXL(true);
  std::vector<uint8_t> box;bool exifBox=false;size_t boxCapacity=0;
  auto finishBox=[&](){ if(boxCapacity){size_t remaining=JxlDecoderReleaseBoxBuffer(jxl);box.resize(boxCapacity-remaining);if(exifBox){require(box.size()>=4,"Truncated JXL EXIF");uint32_t skip=(uint32_t(box[0])<<24)|(uint32_t(box[1])<<16)|(uint32_t(box[2])<<8)|box[3];require(skip<=box.size()-4,"Invalid JXL EXIF offset");exif.assign(box.begin()+4+skip,box.end());}boxCapacity=0;} };
  require(JxlDecoderSetDecompressBoxes(jxl,JXL_TRUE)==JXL_DEC_SUCCESS,"JXL box decompression setup failed");
  for(;;){
   JxlDecoderStatus status=JxlDecoderProcessInput(jxl);
   if(status==JXL_DEC_BASIC_INFO){
    JxlBasicInfo basic;require(JxlDecoderGetBasicInfo(jxl,&basic)==JXL_DEC_SUCCESS,"Invalid JXL header");
    info.is_animated=basic.have_animation;info.width=int(basic.xsize);info.height=int(basic.ysize);info.depth=int(basic.bits_per_sample);info.has_alpha=basic.alpha_bits>0;info.orientation=int(basic.orientation);
    pixelSize(info);
    require(basic.bits_per_sample<=8&&basic.exponent_bits_per_sample==0&&basic.alpha_bits<=8&&basic.alpha_exponent_bits==0,"High-bit-depth/float JXL requires a preservation path");
    require(basic.num_color_channels==3||basic.num_color_channels==1,"Unsupported JXL color channels");
    require(basic.num_extra_channels==(basic.alpha_bits?1u:0u),"JXL auxiliary/gainmap channels cannot be preserved");
    require(basic.intensity_target<=255,"HDR JXL cannot be reduced to 8-bit");
    info.timescale_num=basic.have_animation?basic.animation.tps_numerator:1;info.timescale_den=basic.have_animation?basic.animation.tps_denominator:1;info.loops=basic.have_animation?basic.animation.num_loops:1;
    require(info.timescale_num&&info.timescale_den,"Invalid JXL animation timescale");
   }else if(status==JXL_DEC_COLOR_ENCODING){
    JxlColorEncoding color{};
    if(JxlDecoderGetColorAsEncodedProfile(jxl,JXL_COLOR_PROFILE_TARGET_DATA,&color)==JXL_DEC_SUCCESS)
      require(color.transfer_function!=JXL_TRANSFER_FUNCTION_PQ&&color.transfer_function!=JXL_TRANSFER_FUNCTION_HLG,"HDR JXL is unsupported");
    size_t n=0;require(JxlDecoderGetICCProfileSize(jxl,JXL_COLOR_PROFILE_TARGET_DATA,&n)==JXL_DEC_SUCCESS&&n<=16*1024*1024,"Invalid JXL ICC");icc.resize(n);
    require(JxlDecoderGetColorAsICCProfile(jxl,JXL_COLOR_PROFILE_TARGET_DATA,icc.data(),n)==JXL_DEC_SUCCESS,"JXL ICC decode failed");
   }else if(status==JXL_DEC_FRAME){JxlFrameHeader frame;require(JxlDecoderGetFrameHeader(jxl,&frame)==JXL_DEC_SUCCESS,"Invalid JXL frame");require(durations.size()<100000,"JXL frame limit exceeded");durations.push_back(frame.duration);}
   else if(status==JXL_DEC_NEED_IMAGE_OUT_BUFFER){require(JxlDecoderSkipCurrentFrame(jxl)==JXL_DEC_SUCCESS,"JXL scan skip failed");}
   else if(status==JXL_DEC_BOX){
    finishBox();JxlBoxType type;require(JxlDecoderGetBoxType(jxl,type,JXL_TRUE)==JXL_DEC_SUCCESS,"Invalid JXL box");
    // Gain map/JUMBF content is deliberately rejected rather than dropped.
    require(memcmp(type,"jhgm",4)!=0&&memcmp(type,"jumb",4)!=0,"JXL gainmap/JUMBF metadata cannot be preserved");
    exifBox=memcmp(type,"Exif",4)==0;
    if(exifBox){box.assign(16*1024*1024,0);boxCapacity=box.size();require(JxlDecoderSetBoxBuffer(jxl,box.data(),box.size())==JXL_DEC_SUCCESS,"JXL EXIF buffer failed");}
   }else if(status==JXL_DEC_BOX_NEED_MORE_OUTPUT){throw std::runtime_error("JXL EXIF exceeds metadata limit");}
   else if(status==JXL_DEC_SUCCESS){finishBox();break;}
   else if(status==JXL_DEC_ERROR||status==JXL_DEC_NEED_MORE_INPUT){throw std::runtime_error("Invalid or truncated JXL stream");}
  }
  require(!durations.empty(),"JXL contains no display frames");info.frame_count=int(durations.size());initJXL(false);
 }
};
struct Encoder {
 RingModernInfo info{};std::vector<uint8_t> icc,exif,encoded;
 avifEncoder *avif=nullptr;JxlEncoder *jxl=nullptr;void *runner=nullptr;
 int quality=100,count=0;
 ~Encoder(){if(avif)avifEncoderDestroy(avif);if(jxl)JxlEncoderDestroy(jxl);if(runner)JxlThreadParallelRunnerDestroy(runner);}
};
}
extern "C" {
int ring_modern_sniff(const uint8_t *data,size_t size) {
 if(!data)return 0;
 JxlSignature sig=JxlSignatureCheck(data,size);if(sig==JXL_SIG_CODESTREAM||sig==JXL_SIG_CONTAINER)return 2;
 avifROData raw={data,size};return avifPeekCompatibleFileType(&raw)?1:0;
}
void *ring_modern_open(const uint8_t *data,size_t size,int threads,RingModernInfo *info,char *error,size_t error_size) {
 try {
  require(data&&size&&info,"Missing image input");auto r=std::make_unique<Reader>();r->info.format=ring_modern_sniff(data,size);require(r->info.format,"Not an AVIF/JXL stream");r->bytes.assign(data,data+size);
  if(r->info.format==1){
   r->avif=avifDecoderCreate();require(r->avif,"AVIF decoder allocation failed");r->avif->maxThreads=std::clamp(threads,1,16);r->avif->imageSizeLimit=52000000;r->avif->imageDimensionLimit=65535;r->avif->imageCountLimit=100000;
   require(avifDecoderSetIOMemory(r->avif,r->bytes.data(),r->bytes.size())==AVIF_RESULT_OK,"AVIF input failed");
   require(avifDecoderParse(r->avif)==AVIF_RESULT_OK,"Invalid AVIF container");
   auto d=r->avif;auto im=d->image;r->info.width=im->width;r->info.height=im->height;r->info.depth=im->depth;r->info.has_alpha=d->alphaPresent;r->info.frame_count=d->imageCount;r->info.is_animated=d->imageSequenceTrackPresent;r->info.orientation=orientation(im);r->info.color_primaries=im->colorPrimaries;r->info.transfer_characteristics=im->transferCharacteristics;pixelSize(r->info);
   require(im->depth==8,"High-bit-depth AVIF requires a preservation path");
   require(!im->gainMap&&im->transferCharacteristics!=AVIF_TRANSFER_CHARACTERISTICS_SMPTE2084&&im->transferCharacteristics!=AVIF_TRANSFER_CHARACTERISTICS_HLG,"HDR/gainmap AVIF cannot be reduced to 8-bit");
   require(!(im->transformFlags&AVIF_TRANSFORM_CLAP)&&!(im->transformFlags&AVIF_TRANSFORM_PASP),"AVIF crop/pixel-aspect transforms cannot be preserved");
   require(d->timescale<=UINT32_MAX,"AVIF timescale exceeds supported range");r->info.timescale_num=d->timescale?uint32_t(d->timescale):1;r->info.timescale_den=1;
   require(d->repetitionCount!=AVIF_REPETITION_COUNT_UNKNOWN||d->imageCount==1,"AVIF repetition count is unspecified");
   r->info.loops=d->repetitionCount==AVIF_REPETITION_COUNT_INFINITE?0:uint32_t(std::max(0,d->repetitionCount)+1);
   if(im->icc.size)r->icc.assign(im->icc.data,im->icc.data+im->icc.size);if(im->exif.size){size_t offset=0;require(avifGetExifTiffHeaderOffset(im->exif.data,im->exif.size,&offset)==AVIF_RESULT_OK,"Invalid AVIF EXIF");r->exif.assign(im->exif.data+offset,im->exif.data+im->exif.size);}
   for(int n=0;n<d->imageCount;n++){avifImageTiming t;require(avifDecoderNthImageTiming(d,n,&t)==AVIF_RESULT_OK,"Invalid AVIF timing");r->durations.push_back(t.durationInTimescales);}
  }else{r->runner=JxlThreadParallelRunnerCreate(nullptr,std::clamp(threads,1,16));require(r->runner,"JXL runner allocation failed");r->scanJXL();}
  *info=r->info;return r.release();
 }catch(const std::exception &e){errorText(error,error_size,e);return nullptr;}
}
const uint8_t *ring_modern_metadata(void *reader,int exif,size_t *size){auto r=static_cast<Reader*>(reader);if(!r||!size)return nullptr;auto &v=exif?r->exif:r->icc;*size=v.size();return v.empty()?nullptr:v.data();}
uint64_t ring_modern_duration(void *reader,int index){auto r=static_cast<Reader*>(reader);return r&&index>=0&&size_t(index)<r->durations.size()?r->durations[index]:0;}
int ring_modern_frame(void *reader,int index,uint8_t *rgba,size_t size,char *error,size_t error_size){
 try{
  auto r=static_cast<Reader*>(reader);require(r&&rgba&&index>=0&&index<r->info.frame_count&&size>=pixelSize(r->info),"Invalid frame buffer/index");
  if(r->avif){require(avifDecoderNthImage(r->avif,index)==AVIF_RESULT_OK,"AVIF frame decoding failed");require(r->avif->image->depth==8,"High-bit-depth AVIF frame cannot be reduced to 8-bit");avifRGBImage rgb;avifRGBImageSetDefaults(&rgb,r->avif->image);rgb.format=AVIF_RGB_FORMAT_RGBA;rgb.depth=8;rgb.alphaPremultiplied=AVIF_FALSE;rgb.pixels=rgba;rgb.rowBytes=r->info.width*4;require(avifImageYUVToRGB(r->avif->image,&rgb)==AVIF_RESULT_OK,"AVIF RGB conversion failed");}
  else{
   if(index<r->next)r->initJXL(false);
   JxlPixelFormat fmt={4,JXL_TYPE_UINT8,JXL_NATIVE_ENDIAN,0};
   for(;;){auto s=JxlDecoderProcessInput(r->jxl);
    if(s==JXL_DEC_NEED_IMAGE_OUT_BUFFER)require(JxlDecoderSetImageOutBuffer(r->jxl,&fmt,rgba,size)==JXL_DEC_SUCCESS,"JXL output buffer failed");
    else if(s==JXL_DEC_FULL_IMAGE){int current=r->next++;if(current==index)break;}
    else if(s==JXL_DEC_ERROR||s==JXL_DEC_NEED_MORE_INPUT||s==JXL_DEC_SUCCESS)throw std::runtime_error("JXL frame decoding failed");
   }
  }
  return 1;
 }catch(const std::exception &e){errorText(error,error_size,e);return 0;}
}
void ring_modern_close(void *reader){delete static_cast<Reader*>(reader);}
void *ring_modern_encoder_create(const RingModernInfo *info,const uint8_t *icc,size_t icc_size,const uint8_t *exif,size_t exif_size,int quality,int threads,char *error,size_t error_size){
 try{
  require(info,"Missing encoder info");require((icc||icc_size==0)&&(exif||exif_size==0),"Missing metadata bytes");pixelSize(*info);require((info->format==1||info->format==2)&&info->depth==8&&info->frame_count>0&&info->frame_count<=100000&&info->orientation>=1&&info->orientation<=8&&quality>=0&&quality<=100,"Invalid encoder parameters");
  require(info->timescale_num&&info->timescale_den,"Invalid animation timescale");require(icc_size<=16*1024*1024&&exif_size<=16*1024*1024,"Metadata exceeds limit");
  auto e=std::make_unique<Encoder>();e->info=*info;e->quality=quality;if(icc_size)e->icc.assign(icc,icc+icc_size);if(exif_size)e->exif.assign(exif,exif+exif_size);
  if(info->format==1){e->avif=avifEncoderCreate();require(e->avif,"AVIF encoder allocation failed");e->avif->maxThreads=std::clamp(threads,1,16);e->avif->speed=6;e->avif->quality=quality;e->avif->qualityAlpha=100;e->avif->timescale=info->timescale_num;e->avif->repetitionCount=info->loops?int(info->loops-1):AVIF_REPETITION_COUNT_INFINITE;}
  else{
   e->jxl=JxlEncoderCreate(nullptr);require(e->jxl,"JXL encoder allocation failed");e->runner=JxlThreadParallelRunnerCreate(nullptr,std::clamp(threads,1,16));require(e->runner,"JXL runner allocation failed");
   require(JxlEncoderSetParallelRunner(e->jxl,JxlThreadParallelRunner,e->runner)==JXL_ENC_SUCCESS,"JXL encoder runner failed");require(JxlEncoderUseContainer(e->jxl,JXL_TRUE)==JXL_ENC_SUCCESS,"JXL container setup failed");
   JxlBasicInfo b;JxlEncoderInitBasicInfo(&b);b.xsize=info->width;b.ysize=info->height;b.bits_per_sample=8;b.num_color_channels=3;b.uses_original_profile=JXL_TRUE;b.orientation=JxlOrientation(info->orientation);b.num_extra_channels=info->has_alpha?1:0;b.alpha_bits=info->has_alpha?8:0;b.have_animation=info->is_animated;
   b.animation.tps_numerator=info->timescale_num;b.animation.tps_denominator=info->timescale_den;b.animation.num_loops=info->loops;
   require(JxlEncoderSetBasicInfo(e->jxl,&b)==JXL_ENC_SUCCESS,"JXL basic info rejected");
   if(icc_size)require(JxlEncoderSetICCProfile(e->jxl,icc,icc_size)==JXL_ENC_SUCCESS,"JXL ICC rejected");else{JxlColorEncoding c;JxlColorEncodingSetToSRGB(&c,JXL_FALSE);require(JxlEncoderSetColorEncoding(e->jxl,&c)==JXL_ENC_SUCCESS,"JXL sRGB setup failed");}
   if(exif_size){require(JxlEncoderUseBoxes(e->jxl)==JXL_ENC_SUCCESS,"JXL EXIF setup failed");std::vector<uint8_t> box(4+exif_size,0);memcpy(box.data()+4,exif,exif_size);require(JxlEncoderAddBox(e->jxl,"Exif",box.data(),box.size(),JXL_FALSE)==JXL_ENC_SUCCESS,"JXL EXIF rejected");JxlEncoderCloseBoxes(e->jxl);}
  }
  return e.release();
 }catch(const std::exception &e){errorText(error,error_size,e);return nullptr;}
}
int ring_modern_encoder_add(void *encoder,const uint8_t *rgba,size_t size,uint64_t ticks,char *error,size_t error_size){
 try{
  auto e=static_cast<Encoder*>(encoder);require(e&&rgba&&size>=pixelSize(e->info)&&e->count<e->info.frame_count,"Invalid encoder frame");require(!e->info.is_animated||ticks>0,"Animation frame duration must be positive");
  if(e->avif){
   require(ticks<=UINT64_MAX/e->info.timescale_den,"AVIF duration overflow");
   auto deleter=[](avifImage *p){avifImageDestroy(p);};std::unique_ptr<avifImage,decltype(deleter)> im(avifImageCreate(e->info.width,e->info.height,8,AVIF_PIXEL_FORMAT_YUV444),deleter);require(bool(im),"AVIF image allocation failed");
   im->matrixCoefficients=e->quality==100?AVIF_MATRIX_COEFFICIENTS_IDENTITY:AVIF_MATRIX_COEFFICIENTS_BT601;im->yuvRange=AVIF_RANGE_FULL;im->colorPrimaries=AVIF_COLOR_PRIMARIES_UNSPECIFIED;im->transferCharacteristics=AVIF_TRANSFER_CHARACTERISTICS_UNSPECIFIED;
   if(!e->icc.empty())require(avifImageSetProfileICC(im.get(),e->icc.data(),e->icc.size())==AVIF_RESULT_OK,"AVIF ICC rejected");
   if(!e->exif.empty())require(avifImageSetMetadataExif(im.get(),e->exif.data(),e->exif.size())==AVIF_RESULT_OK,"AVIF EXIF rejected");
   // EXIF sets transform properties. Set explicitly as well for metadata-free inputs.
   const int angle[]={0,0,0,2,0,1,3,3,1};const int mirror[]={-1,-1,1,-1,0,0,-1,0,-1};
   im->transformFlags&=~(AVIF_TRANSFORM_IROT|AVIF_TRANSFORM_IMIR);
   if(angle[e->info.orientation]){im->transformFlags|=AVIF_TRANSFORM_IROT;im->irot.angle=angle[e->info.orientation];}
   if(mirror[e->info.orientation]>=0){im->transformFlags|=AVIF_TRANSFORM_IMIR;im->imir.axis=mirror[e->info.orientation];}
   avifRGBImage rgb;avifRGBImageSetDefaults(&rgb,im.get());rgb.format=AVIF_RGB_FORMAT_RGBA;rgb.depth=8;rgb.alphaPremultiplied=AVIF_FALSE;rgb.pixels=const_cast<uint8_t*>(rgba);rgb.rowBytes=e->info.width*4;
   require(avifImageRGBToYUV(im.get(),&rgb)==AVIF_RESULT_OK,"AVIF RGB input conversion failed");
   require(avifEncoderAddImage(e->avif,im.get(),std::max(uint64_t(1),ticks*e->info.timescale_den),e->info.is_animated?AVIF_ADD_IMAGE_FLAG_NONE:AVIF_ADD_IMAGE_FLAG_SINGLE)==AVIF_RESULT_OK,"AVIF frame encoding failed");
  }else{
   require(ticks<=UINT32_MAX,"JXL frame duration overflow");auto f=JxlEncoderFrameSettingsCreate(e->jxl,nullptr);require(f,"JXL frame settings failed");
   require(JxlEncoderSetFrameLossless(f,e->quality==100?JXL_TRUE:JXL_FALSE)==JXL_ENC_SUCCESS,"JXL lossless setup failed");
   require(JxlEncoderSetFrameDistance(f,e->quality==100?0.0f:float(0.1+(100-e->quality)*0.15))==JXL_ENC_SUCCESS,"JXL quality setup failed");
   require(JxlEncoderFrameSettingsSetOption(f,JXL_ENC_FRAME_SETTING_EFFORT,5)==JXL_ENC_SUCCESS,"JXL effort setup failed");
   require(JxlEncoderFrameSettingsSetOption(f,JXL_ENC_FRAME_SETTING_KEEP_INVISIBLE,1)==JXL_ENC_SUCCESS,"JXL invisible color preservation failed");
   JxlFrameHeader h;JxlEncoderInitFrameHeader(&h);h.duration=e->info.is_animated?uint32_t(ticks):0;require(JxlEncoderSetFrameHeader(f,&h)==JXL_ENC_SUCCESS,"JXL timing setup failed");
   JxlPixelFormat fmt={4,JXL_TYPE_UINT8,JXL_NATIVE_ENDIAN,0};require(JxlEncoderAddImageFrame(f,&fmt,rgba,pixelSize(e->info))==JXL_ENC_SUCCESS,"JXL frame input rejected");
   // Drain each submitted frame so libjxl releases its uncompressed input.
   // The final frame must be closed before its first ProcessOutput call.
   if(e->count+1==e->info.frame_count)JxlEncoderCloseInput(e->jxl);
   std::array<uint8_t,65536> chunk;
   for(;;){
    uint8_t *next=chunk.data();size_t available=chunk.size();
    auto status=JxlEncoderProcessOutput(e->jxl,&next,&available);
    size_t produced=chunk.size()-available;
    require(produced<=e->encoded.max_size()-e->encoded.size(),"JXL output overflow");
    e->encoded.insert(e->encoded.end(),chunk.data(),chunk.data()+produced);
    if(status==JXL_ENC_SUCCESS)break;
    require(status==JXL_ENC_NEED_MORE_OUTPUT,"JXL encoding failed");
   }
  }
  e->count++;return 1;
 }catch(const std::exception &e){errorText(error,error_size,e);return 0;}
}
int ring_modern_encoder_finish(void *encoder,uint8_t **output,size_t *size,char *error,size_t error_size){
 try{
  auto e=static_cast<Encoder*>(encoder);require(e&&output&&size&&e->count==e->info.frame_count,"Incomplete image frame sequence");*output=nullptr;*size=0;
  std::vector<uint8_t> bytes;
  if(e->avif){avifRWData data=AVIF_DATA_EMPTY;avifResult result=avifEncoderFinish(e->avif,&data);if(result!=AVIF_RESULT_OK){avifRWDataFree(&data);throw std::runtime_error("AVIF finalization failed");}bytes.assign(data.data,data.data+data.size);avifRWDataFree(&data);}
  else{bytes.swap(e->encoded);}
  auto memory=static_cast<uint8_t*>(malloc(bytes.size()));require(memory&&!bytes.empty(),"Encoded output allocation failed");memcpy(memory,bytes.data(),bytes.size());*output=memory;*size=bytes.size();return 1;
 }catch(const std::exception &e){errorText(error,error_size,e);return 0;}
}
void ring_modern_encoder_close(void *encoder){delete static_cast<Encoder*>(encoder);}
void ring_modern_free(void *buffer){free(buffer);}
}
