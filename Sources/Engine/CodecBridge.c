#include "CodecBridge.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include <webp/encode.h>
#include <webp/mux.h>
#include <avif/avif.h>
#include <turbojpeg.h>
#include <jpeglib.h>
#include <zlib.h>
#include <qpdf/qpdfjob-c.h>
#include <qpdf/qpdf-c.h>
uint32_t ring_crc32(uint32_t crc,const uint8_t *data,size_t size) { return (uint32_t)crc32_z(crc,data,size); }
int ring_pdf_replace_page(const char *source,const char *page,int page_number,int page_count,const char *output) {
 if(page_number<1 || page_number>page_count)return 0;
 char before[32],after[32];const char *args[20];int n=0;
 args[n++]="Ring PDF";args[n++]="--empty";args[n++]="--stream-data=preserve";args[n++]="--object-streams=preserve";args[n++]="--pages";
 if(page_number>1){snprintf(before,sizeof(before),"1-%d",page_number-1);args[n++]=source;args[n++]=before;}
 args[n++]=page;args[n++]="1";
 if(page_number<page_count){snprintf(after,sizeof(after),"%d-%d",page_number+1,page_count);args[n++]=source;args[n++]=after;}
 args[n++]="--";args[n++]=output;args[n]=NULL;
 return qpdfjob_run_from_argv(args)==0;
}

// PDFKit drops new document attributes when the source has no Info dictionary.
// Add an ASCII placeholder Info entry without rewriting stream data.
int ring_pdf_add_info(const char *source,const char *output) {
 qpdf_data q=qpdf_init();int ok=0;
 qpdf_set_suppress_warnings(q,QPDF_TRUE);
 if(!(qpdf_read(q,source,NULL)&QPDF_ERRORS) && !qpdf_is_encrypted(q)) {
  qpdf_set_info_key(q,"/Producer","Ring");
  if(!(qpdf_init_write(q,output)&QPDF_ERRORS)) {
   qpdf_set_stream_data_mode(q,qpdf_s_preserve);qpdf_set_object_stream_mode(q,qpdf_o_preserve);
   ok=!(qpdf_write(q)&QPDF_ERRORS);
  }
 }
 qpdf_cleanup(&q);return ok;
}

static int fail(char *error,size_t n,const char *text) { if(n) snprintf(error,n,"%s",text);return 0; }
static int write_file(const char *path,const uint8_t *data,size_t n) {
 FILE *file=fopen(path,"wb");if(!file)return 0;
 int ok=fwrite(data,1,n,file)==n; if(fclose(file))ok=0;return ok;
}
int ring_webp_encode(const uint8_t *rgba,int width,int height,int stride,const uint8_t *icc,size_t icc_size,const uint8_t *exif,size_t exif_size,int threads,const char *path,char *error,size_t error_size) {
 WebPConfig config;WebPPicture picture;WebPMemoryWriter writer;WebPMux *mux=NULL;WebPData assembled={0};int ok=0;
 if(!WebPConfigInit(&config)||!WebPPictureInit(&picture))return fail(error,error_size,"WebP initialization failed");
 config.lossless=1;config.quality=100;config.method=4;config.exact=1;config.thread_level=threads>1;config.low_memory=1;
 picture.width=width;picture.height=height;picture.use_argb=1;
 WebPMemoryWriterInit(&writer);picture.writer=WebPMemoryWrite;picture.custom_ptr=&writer;
 if(!WebPPictureImportRGBA(&picture,rgba,stride)||!WebPValidateConfig(&config)||!WebPEncode(&config,&picture)) { fail(error,error_size,"WebP lossless encoding failed");goto done; }
 WebPData encoded={writer.mem,writer.size};mux=WebPMuxCreate(&encoded,1);
 if(!mux) { fail(error,error_size,"WebP mux failed");goto done; }
 if(icc_size) { WebPData d={icc,icc_size};if(WebPMuxSetChunk(mux,"ICCP",&d,1)!=WEBP_MUX_OK)goto done; }
 if(exif_size) { WebPData d={exif,exif_size};if(WebPMuxSetChunk(mux,"EXIF",&d,1)!=WEBP_MUX_OK)goto done; }
 if(WebPMuxAssemble(mux,&assembled)!=WEBP_MUX_OK)goto done;
 ok=write_file(path,assembled.bytes,assembled.size);if(!ok)fail(error,error_size,"WebP output write failed");
 done:WebPDataClear(&assembled);if(mux)WebPMuxDelete(mux);WebPMemoryWriterClear(&writer);WebPPictureFree(&picture);return ok;
}
int ring_avif_encode(const uint8_t *rgba,int width,int height,int stride,const uint8_t *icc,size_t icc_size,const uint8_t *exif,size_t exif_size,int threads,const char *path,char *error,size_t error_size) {
 avifImage *image=avifImageCreate(width,height,8,AVIF_PIXEL_FORMAT_YUV444);avifEncoder *encoder=NULL;avifRWData encoded=AVIF_DATA_EMPTY;int ok=0;avifResult result=AVIF_RESULT_UNKNOWN_ERROR;
 if(!image)return fail(error,error_size,"AVIF allocation failed");
 image->yuvRange=AVIF_RANGE_FULL;image->matrixCoefficients=AVIF_MATRIX_COEFFICIENTS_IDENTITY;
 image->colorPrimaries=AVIF_COLOR_PRIMARIES_UNSPECIFIED;image->transferCharacteristics=AVIF_TRANSFER_CHARACTERISTICS_UNSPECIFIED;
 if(icc_size&&(result=avifImageSetProfileICC(image,icc,icc_size))!=AVIF_RESULT_OK)goto done;
 if(exif_size&&(result=avifImageSetMetadataExif(image,exif,exif_size))!=AVIF_RESULT_OK)goto done;
 avifRGBImage rgb;avifRGBImageSetDefaults(&rgb,image);rgb.format=AVIF_RGB_FORMAT_RGBA;rgb.depth=8;rgb.pixels=(uint8_t *)rgba;rgb.rowBytes=stride;rgb.alphaPremultiplied=AVIF_FALSE;
 int opaque=1;for(int y=0;y<height&&opaque;y++)for(int x=0;x<width;x++)if(rgba[y*stride+x*4+3]!=255){opaque=0;break;}
 rgb.ignoreAlpha=opaque;
 result=avifImageRGBToYUV(image,&rgb);if(result!=AVIF_RESULT_OK)goto done;
 encoder=avifEncoderCreate();if(!encoder)goto done;
 encoder->codecChoice=AVIF_CODEC_CHOICE_AOM;encoder->maxThreads=threads;encoder->speed=8;encoder->autoTiling=AVIF_TRUE;
 encoder->quality=AVIF_QUALITY_LOSSLESS;encoder->qualityAlpha=AVIF_QUALITY_LOSSLESS;
 if((int64_t)width*height>3000000 && width>=128 && height>=128 && !(image->transformFlags & (AVIF_TRANSFORM_IROT|AVIF_TRANSFORM_IMIR))) {
  const int cols=(width+1535)/1536,rows=(height+1535)/1536,cw=(width+cols-1)/cols,ch=(height+rows-1)/rows;
  avifImage **cells=calloc((size_t)cols*rows,sizeof(*cells));
  if(!cells)goto done;
  int created=0;
  for(int y=0;y<rows;y++)for(int x=0;x<cols;x++) {
   avifCropRect rect={(uint32_t)(x*cw),(uint32_t)(y*ch),(uint32_t)(x==cols-1?width-x*cw:cw),(uint32_t)(y==rows-1?height-y*ch:ch)};
   cells[created]=avifImageCreateEmpty();
   if(!cells[created]){result=AVIF_RESULT_OUT_OF_MEMORY;goto grid_done;}
   created++;result=avifImageSetViewRect(cells[created-1],image,&rect);if(result!=AVIF_RESULT_OK)goto grid_done;
  }
  if(icc_size) { result=avifImageSetProfileICC(cells[0],icc,icc_size);if(result!=AVIF_RESULT_OK)goto grid_done; }
  if(exif_size) { result=avifImageSetMetadataExif(cells[0],exif,exif_size);if(result!=AVIF_RESULT_OK)goto grid_done; }
  encoder->maxThreads=threads>1?2:1;
  result=avifEncoderAddImageGrid(encoder,cols,rows,(const avifImage *const *)cells,AVIF_ADD_IMAGE_FLAG_SINGLE);
  if(result==AVIF_RESULT_OK)result=avifEncoderFinish(encoder,&encoded);
  grid_done:for(int i=0;i<created;i++)avifImageDestroy(cells[i]);free(cells);
 } else { result=avifEncoderWrite(encoder,image,&encoded); }
 if(result!=AVIF_RESULT_OK)goto done;
 ok=write_file(path,encoded.data,encoded.size);
 done:if(!ok)fail(error,error_size,avifResultToString(result));avifRWDataFree(&encoded);if(encoder)avifEncoderDestroy(encoder);avifImageDestroy(image);return ok;
}
int ring_jpeg_transform(const uint8_t *source,size_t size,int crop,int x,int y,int width,int height,const char *path,char *error,size_t error_size) {
 tjhandle handle=tj3Init(TJINIT_TRANSFORM);if(!handle)return fail(error,error_size,"JPEG init failed");
 unsigned char *output=NULL;size_t out_size=0;tjtransform transform={0};
 transform.op=TJXOP_NONE;transform.options=TJXOPT_OPTIMIZE|TJXOPT_PERFECT;
 if(crop) { transform.options|=TJXOPT_CROP;transform.r.x=x;transform.r.y=y;transform.r.w=width;transform.r.h=height; }
 tj3Set(handle,TJPARAM_MAXMEMORY,128);
 int ok=tj3Transform(handle,source,size,1,&output,&out_size,&transform)==0;
 if(ok)ok=write_file(path,output,out_size);
 if(!ok)fail(error,error_size,tj3GetErrorStr(handle));if(output)tj3Free(output);tj3Destroy(handle);return ok;
}
struct RingJpegError { struct jpeg_error_mgr base;jmp_buf *jump;char *message;size_t message_size; };
static void jpeg_error_exit(j_common_ptr info) {
 struct RingJpegError *err=(struct RingJpegError *)info->err;
 if(err->message_size) { char buffer[JMSG_LENGTH_MAX];(*info->err->format_message)(info,buffer);snprintf(err->message,err->message_size,"%s",buffer); }
 longjmp(*err->jump,1);
}
struct CompareState { struct jpeg_decompress_struct a,b;struct RingJpegError ea,eb; };
int ring_jpeg_coefficients_equal(const uint8_t *source,size_t source_size,const uint8_t *output,size_t output_size,int x,int y,char *error,size_t error_size) {
 struct CompareState *state=calloc(1,sizeof(*state));if(!state)return 0;
 jmp_buf jump;int ok=0;
 state->a.err=jpeg_std_error(&state->ea.base);state->b.err=jpeg_std_error(&state->eb.base);
 state->ea.base.error_exit=state->eb.base.error_exit=jpeg_error_exit;
 state->ea.jump=state->eb.jump=&jump;state->ea.message=state->eb.message=error;state->ea.message_size=state->eb.message_size=error_size;
 if(setjmp(jump))goto done;
 jpeg_create_decompress(&state->a);jpeg_create_decompress(&state->b);
 jpeg_mem_src(&state->a,source,source_size);jpeg_mem_src(&state->b,output,output_size);
 jpeg_read_header(&state->a,TRUE);jpeg_read_header(&state->b,TRUE);
 if(state->a.num_components!=state->b.num_components)goto done;
 jvirt_barray_ptr *a=jpeg_read_coefficients(&state->a),*b=jpeg_read_coefficients(&state->b);
 for(int q=0;q<NUM_QUANT_TBLS;q++) {
  JQUANT_TBL *ta=state->a.quant_tbl_ptrs[q],*tb=state->b.quant_tbl_ptrs[q];
  if((ta==NULL)!=(tb==NULL)||(ta&&memcmp(ta->quantval,tb->quantval,sizeof(ta->quantval))))goto done;
 }
 for(int c=0;c<state->a.num_components;c++) {
  jpeg_component_info *ca=&state->a.comp_info[c],*cb=&state->b.comp_info[c];
  int bx=x*ca->h_samp_factor/(8*state->a.max_h_samp_factor),by=y*ca->v_samp_factor/(8*state->a.max_v_samp_factor);
  if(ca->h_samp_factor!=cb->h_samp_factor||ca->v_samp_factor!=cb->v_samp_factor||bx+cb->width_in_blocks>ca->width_in_blocks||by+cb->height_in_blocks>ca->height_in_blocks)goto done;
  for(JDIMENSION row=0;row<cb->height_in_blocks;row++) {
   JBLOCKARRAY ar=(*state->a.mem->access_virt_barray)((j_common_ptr)&state->a,a[c],by+row,1,FALSE);
   JBLOCKARRAY br=(*state->b.mem->access_virt_barray)((j_common_ptr)&state->b,b[c],row,1,FALSE);
   for(JDIMENSION col=0;col<cb->width_in_blocks;col++)if(memcmp(ar[0][bx+col],br[0][col],sizeof(JBLOCK)))goto done;
  }
 }
 ok=1;
 done:if(state->a.mem)jpeg_destroy_decompress(&state->a);if(state->b.mem)jpeg_destroy_decompress(&state->b);free(state);
 if(!ok&&error_size&&error[0]==0)fail(error,error_size,"DCT coefficient/quantization table mismatch");return ok;
}
