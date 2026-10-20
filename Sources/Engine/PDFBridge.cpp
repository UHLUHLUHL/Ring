#include "CodecBridge.h"
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFWriter.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFPageObjectHelper.hh>
#include <qpdf/QPDFAcroFormDocumentHelper.hh>
#include <qpdf/QPDFMatrix.hh>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

static int failure(char *error,size_t n,const std::exception &e) {
    if(n) snprintf(error,n,"%s",e.what());return 0;
}
static void read(QPDF &pdf,const char *path) {
    pdf.setSuppressWarnings(true);pdf.setAttemptRecovery(false);pdf.processFile(path);
    if(pdf.isEncrypted()) throw std::runtime_error("Encrypted PDFs are not supported");
}
static void write(QPDF &pdf,const char *path) {
    QPDFWriter writer(pdf,path);writer.setStreamDataMode(qpdf_s_preserve);
    writer.setObjectStreamMode(qpdf_o_preserve);writer.write();
}
extern "C" int ring_pdf_check(const char *source,int expected,char *error,size_t n) {
    try {
        QPDF pdf;read(pdf,source);
        if((int)QPDFPageDocumentHelper(pdf).getAllPages().size()!=expected) throw std::runtime_error("PDF page count mismatch");
        // Force lazy object/stream reads, including stream lengths and filters.
        for(auto object:pdf.getAllObjects()) if(object.isStream()) object.getRawStreamData();
        if(pdf.anyWarnings()) {
            auto warnings=pdf.getWarnings();
            throw std::runtime_error(warnings.empty()?"PDF structure warnings":warnings.front().what());
        }
        return 1;
    } catch(const std::exception &e) { return failure(error,n,e); }
}
extern "C" int ring_pdf_pages(const char *const *sources,const int *pages,size_t count,double width,const char *output,char *error,size_t n) {
    try {
        if(count==0 || count>10000 || !std::isfinite(width) || width<0) throw std::runtime_error("Invalid PDF page selection");
        QPDF dest;dest.emptyPDF();QPDFPageDocumentHelper target(dest);QPDFAcroFormDocumentHelper target_forms(dest);
        std::map<std::string,std::unique_ptr<QPDF>> inputs;
        std::map<std::string,std::unique_ptr<QPDFAcroFormDocumentHelper>> forms;
        for(size_t i=0;i<count;i++) {
            auto &input=inputs[sources[i]];
            if(!input) {
                input=std::make_unique<QPDF>();read(*input,sources[i]);
                QPDFPageDocumentHelper(*input).pushInheritedAttributesToPage();
                forms[sources[i]]=std::make_unique<QPDFAcroFormDocumentHelper>(*input);
            }
            auto all=QPDFPageDocumentHelper(*input).getAllPages();
            if(pages[i]<0 || (size_t)pages[i]>=all.size()) throw std::runtime_error("PDF page index out of bounds");
            auto page=all[pages[i]].shallowCopyPage();
            if(width>0) {
                auto annotations=page.getObjectHandle().getKey("/Annots");
                if(annotations.isArray() && annotations.getArrayNItems()>0) throw std::runtime_error("Width normalization requires pages without annotations");
                auto form=dest.copyForeignObject(page.getFormXObjectForPage());
                auto box=form.getDict().getKey("/BBox").getArrayAsRectangle();
                auto matrix=form.getDict().getKey("/Matrix");
                if(matrix.isArray()) box=QPDFMatrix(matrix.getArrayAsMatrix()).transformRectangle(box);
                double w=box.urx-box.llx,h=box.ury-box.lly;
                if(w<=0 || h<=0) throw std::runtime_error("Invalid PDF page bounds");
                auto media=QPDFObjectHandle::newArray({QPDFObjectHandle::newInteger(0),QPDFObjectHandle::newInteger(0),QPDFObjectHandle::newReal(width,6),QPDFObjectHandle::newReal(width*h/w,6)});
                auto dictionary=QPDFObjectHandle::newDictionary();dictionary.replaceKey("/Type",QPDFObjectHandle::newName("/Page"));
                dictionary.replaceKey("/MediaBox",media);
                auto resources=QPDFObjectHandle::newDictionary(),objects=QPDFObjectHandle::newDictionary();
                objects.replaceKey("/RingPage",form);resources.replaceKey("/XObject",objects);dictionary.replaceKey("/Resources",resources);
                auto newpage=QPDFPageObjectHelper(dest.makeIndirectObject(dictionary));
                auto commands=newpage.placeFormXObject(form,"/RingPage",{0,0,width,width*h/w},true,true,true);
                newpage.addPageContents(dest.newStream(commands),false);target.addPage(newpage,false);
            } else {
                target.addPage(page,false);
                auto added=target.getAllPages().back().getObjectHandle();
                auto annotations=added.getKey("/Annots");
                bool widgets=false;
                if(annotations.isArray()) for(auto annotation:annotations.getArrayAsVector())
                    if(annotation.getKey("/Subtype").isNameAndEquals("/Widget")) widgets=true;
                if(widgets) target_forms.fixCopiedAnnotations(added,page.getObjectHandle(),*forms[sources[i]]);
                else if(annotations.isArray()) {
                    // Ordinary annotations need private dictionaries but must retain their
                    // original appearance streams. The form helper normalizes appearances.
                    auto private_annotations=QPDFObjectHandle::newArray();
                    for(auto annotation:annotations.getArrayAsVector()) {
                        auto copy=dest.makeIndirectObject(annotation.shallowCopy());
                        copy.replaceKey("/P",added);private_annotations.appendItem(copy);
                    }
                    added.replaceKey("/Annots",private_annotations);
                }
            }
        }
        write(dest,output);return ring_pdf_check(output,(int)count,error,n);
    } catch(const std::exception &e) { return failure(error,n,e); }
}
static std::vector<std::string> protected_streams(QPDF &pdf) {
    std::vector<std::string> result;
    for(auto object:pdf.getAllObjects()) {
        if(!object.isStream()) continue;
        auto d=object.getDict();
        if(d.getKey("/Subtype").isNameAndEquals("/Image") || d.getKey("/Type").isNameAndEquals("/ObjStm") || d.getKey("/Type").isNameAndEquals("/XRef")) continue;
        auto data=object.getRawStreamData();result.emplace_back((const char *)data->getBuffer(),data->getSize());
    }
    std::sort(result.begin(),result.end());return result;
}
extern "C" int ring_pdf_smart_compress(const char *source,const char *output,int minimum,ring_pdf_image_callback callback,void *context,int *changed,char *error,size_t n) {
    try {
        QPDF pdf;read(pdf,source);*changed=0;
        auto protected_data=protected_streams(pdf);
        int count=(int)QPDFPageDocumentHelper(pdf).getAllPages().size();
        for(auto object:pdf.getAllObjects()) {
            if(!object.isStream()) continue;
            auto d=object.getDict();
            if(!d.getKey("/Subtype").isNameAndEquals("/Image") || d.getKey("/BitsPerComponent").getIntValue()!=8) continue;
            auto cs=d.getKey("/ColorSpace");int channels=cs.isNameAndEquals("/DeviceRGB")?3:cs.isNameAndEquals("/DeviceGray")?1:0;
            std::shared_ptr<Buffer> icc;
            if(cs.isArray() && cs.getArrayNItems()==2 && cs.getArrayItem(0).isNameAndEquals("/ICCBased") && cs.getArrayItem(1).isStream()) {
                auto profile=cs.getArrayItem(1);
                channels=(int)profile.getDict().getKey("/N").getIntValue();
                if(channels==1 || channels==3) icc=profile.getStreamData(qpdf_dl_all);else channels=0;
            }
            int w=(int)d.getKey("/Width").getIntValue(),h=(int)d.getKey("/Height").getIntValue();
            if(!channels || w<1 || h<1 || std::max(w,h)<=minimum || (int64_t)w*h>52000000 || d.hasKey("/Decode") || d.hasKey("/SMask") || d.hasKey("/Mask") || d.hasKey("/ImageMask")) continue;
            auto filter=d.getKey("/Filter");bool jpeg=filter.isNameAndEquals("/DCTDecode");
            if(!jpeg && !filter.isNull() && !filter.isNameAndEquals("/FlateDecode")) continue;
            auto original=object.getRawStreamData();
            auto pixels=jpeg?original:object.getStreamData(qpdf_dl_all);
            if(!jpeg && pixels->getSize()!=(size_t)w*h*channels) continue;
            uint8_t *encoded=nullptr;size_t size=0;int ow=0,oh=0;
            int rc=callback(context,pixels->getBuffer(),pixels->getSize(),w,h,channels,jpeg,icc?icc->getBuffer():nullptr,icc?icc->getSize():0,&encoded,&size,&ow,&oh);
            std::unique_ptr<uint8_t,decltype(&free)> owned(encoded,&free);
            if(rc<0) throw std::runtime_error("Image compression cancelled or failed");
            if(!rc || !encoded || !size || ow<1 || oh<1 || size>=original->getSize()) continue;
            object.replaceStreamData(std::string((char *)encoded,size),QPDFObjectHandle::newName("/DCTDecode"),QPDFObjectHandle::newNull());
            d.replaceKey("/Width",QPDFObjectHandle::newInteger(ow));d.replaceKey("/Height",QPDFObjectHandle::newInteger(oh));
            // RGB keeps its original ICCBased/DeviceRGB interpretation. Gray is
            // color-managed into sRGB by the callback and becomes DeviceRGB.
            if(channels==1) d.replaceKey("/ColorSpace",QPDFObjectHandle::newName("/DeviceRGB"));
            (*changed)++;
        }
        write(pdf,output);
        QPDF written;read(written,output);
        if(protected_streams(written)!=protected_data) throw std::runtime_error("Non-image PDF streams changed");
        return ring_pdf_check(output,count,error,n);
    } catch(const std::exception &e) { return failure(error,n,e); }
}
