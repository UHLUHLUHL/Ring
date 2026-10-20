import Foundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO

struct RGBAColor {
    let red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
    var cgColor: CGColor { CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[red,green,blue,alpha])! }
}
struct BackgroundOptions {
    var colors: [RGBAColor]
    var imageURL: URL?
    var padding: Double
    var corner: Double
    var shadow: Double
    var ratio: Double?
}

enum ImageEdit {
    case crop(CGRect)
    case cropAspect(width:Double,height:Double)
    case resize(width:Int,height:Int)
    case resizeScale(Double)
    case redact(CGRect)
    case annotate(CGRect,String)
    case adjust(exposure:Double,contrast:Double,saturation:Double)
    case background(BackgroundOptions)
}

enum ImageEdits {
    static func run(_ source:URL,to output:URL,edit:ImageEdit) throws -> String {
        if case .crop(let region) = edit,["jpg","jpeg"].contains(source.pathExtension.lowercased()) {
            return try ExternalCodecs.jpeg(source,to:output,crop:region)
        }
        if case .adjust(let exposure,let contrast,let saturation) = edit,exposure == 0,contrast == 1,saturation == 1 {
            try FileIntegrity.copy(source,to:output)
            return "변경 없음 · 원본 바이트 그대로"
        }
        // Drop source decoder and transient GPU resources before encoding/validating the result.
        let (result,properties,detail) = try autoreleasepool { try prepare(source,edit:edit) }
        try ImageCodec.write(result,properties:properties,format:.png,to:output)
        try ImageCodec.verify(result,properties:properties,output:output,exact:true)
        return detail + " · 저장 픽셀 일치"
    }
    private static func prepare(_ source:URL,edit:ImageEdit) throws -> (CGImage,[CFString:Any],String) {
        let input = try ImageInput(source)
        let result:CGImage
        var properties = input.properties
        var detail = "PNG 무손실 저장"
        switch edit {
        case .resize(let width,let height):
            let displayed = try PDFEngine.oriented(input.image,input.orientation)
            result = try ImageResampler.resize(displayed,width:width,height:height)
            properties[kCGImagePropertyOrientation] = 1
            detail = "크기 조절 · vImage 고품질 · \(width)×\(height)"
        case .resizeScale(let factor):
            guard factor.isFinite,factor>0,factor<=100 else { throw EngineError.invalid("리사이즈 비율 오류") }
            let displayed = try PDFEngine.oriented(input.image,input.orientation)
            let width = Double(displayed.width)*factor,height = Double(displayed.height)*factor
            guard width<=65535,height<=65535 else { throw EngineError.invalid("리사이즈 크기 초과") }
            result = try ImageResampler.resize(displayed,width:max(1,Int(width.rounded())),height:max(1,Int(height.rounded())))
            properties[kCGImagePropertyOrientation] = 1
            detail = "비율 크기 조절 · vImage 고품질"
        case .cropAspect(let width,let height):
            guard width.isFinite,height.isFinite,width>0,height>0 else { throw EngineError.invalid("자르기 종횡비 오류") }
            let displayed = try PDFEngine.oriented(input.image,input.orientation)
            let ratio = width/height,original = Double(displayed.width)/Double(displayed.height)
            let w = ratio<original ? max(1,Int((Double(displayed.height)*ratio).rounded(.down))) : displayed.width
            let h = ratio<original ? displayed.height : max(1,Int((Double(displayed.width)/ratio).rounded(.down)))
            guard let crop = displayed.cropping(to:CGRect(x:(displayed.width-w)/2,y:(displayed.height-h)/2,width:w,height:h)) else { throw EngineError.invalid("자르기 오류") }
            result = try ImageCodec.promoteAlpha(crop)
            properties[kCGImagePropertyOrientation] = 1
            detail = "중앙 종횡비 자르기 · 원본 픽셀 유지"
        case .crop(let normalized):
            let rect = try rawRect(normalized,image:input.image,orientation:input.orientation)
            guard let cropped = input.image.cropping(to:rect) else { throw EngineError.invalid("자르기 범위를 확인해 주세요.") }
            result = try ImageCodec.promoteAlpha(cropped)
            detail = "자르기 · 원본 픽셀 유지 · PNG"
        case .redact(let normalized):
            let rect = try rawRect(normalized,image:input.image,orientation:input.orientation)
            let ctx = try PDFEngine.bitmap(width:input.image.width,height:input.image.height,space:input.image.colorSpace!,depth:16)
            ctx.setBlendMode(.copy);ctx.draw(input.image,in:CGRect(x:0,y:0,width:input.image.width,height:input.image.height))
            // CGImage crop coordinates are top-left; CGContext fill is bottom-left.
            ctx.setFillColor(CGColor(gray:0,alpha:1))
            ctx.fill(CGRect(x:rect.minX,y:CGFloat(input.image.height)-rect.maxY,width:rect.width,height:rect.height))
            result = ctx.makeImage()!
            properties = safeProperties(input,orientation:input.orientation)
            detail = "단색 가리기 · 원본 메타데이터/썸네일 제외 · PNG"
        case .annotate(let normalized,let text):
            guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw EngineError.invalid("주석 내용을 입력해 주세요.") }
            let displayed = try PDFEngine.oriented(input.image,input.orientation)
            let rect = try rawRect(normalized,image:displayed,orientation:1)
            let ctx = try PDFEngine.bitmap(width:displayed.width,height:displayed.height,space:displayed.colorSpace!,depth:16)
            ctx.draw(displayed,in:CGRect(x:0,y:0,width:displayed.width,height:displayed.height))
            let fontSize = max(8,min(rect.height*0.45,CGFloat(displayed.width)*0.05))
            let font = CTFontCreateWithName("Helvetica" as CFString,fontSize,nil)
            let attrs: [NSAttributedString.Key:Any] = [NSAttributedString.Key(kCTFontAttributeName as String):font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)]
            let string = NSAttributedString(string:text,attributes:attrs)
            let setter = CTFramesetterCreateWithAttributedString(string)
            let path = CGPath(rect:CGRect(x:rect.minX,y:CGFloat(displayed.height)-rect.maxY,width:rect.width,height:rect.height),transform:nil)
            let frame = CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),path,nil)
            guard CTFrameGetVisibleStringRange(frame).length == string.length else { throw EngineError.invalid("주석이 영역에 다 들어가지 않아요. 영역을 넓히거나 내용을 줄여 주세요.") }
            CTFrameDraw(frame,ctx)
            result = ctx.makeImage()!
            properties[kCGImagePropertyOrientation] = 1
        case .adjust(let exposure,let contrast,let saturation):
            guard exposure.isFinite,contrast.isFinite,saturation.isFinite,(-5...5).contains(exposure),(0...3).contains(contrast),(0...3).contains(saturation) else { throw EngineError.invalid("보정 값 범위 오류") }
            let cs = input.image.colorSpace!
            // 32-bit float working samples avoid reducing a 16-bit source to half-float precision.
            let context = CIContext(options:[.workingColorSpace:cs,.outputColorSpace:cs,.workingFormat:CIFormat.RGBAf,.cacheIntermediates:false,.priorityRequestLow:true,.memoryTarget:64])
            let image = CIImage(cgImage:input.image).applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:exposure])
                .applyingFilter("CIColorControls",parameters:[kCIInputContrastKey:contrast,kCIInputSaturationKey:saturation])
            guard let rendered = context.createCGImage(image,from:image.extent,format:.RGBA16,colorSpace:cs) else { throw EngineError.io("Core Image 보정 실패") }
            context.clearCaches()
            result = rendered
            detail = "Core Image 보정 · 32비트 부동소수 연산 · PNG16"
        case .background(let options):
            result = try background(input,options:options)
            properties[kCGImagePropertyOrientation] = 1
            detail = "배경 추가 · 원본 1:1 · PNG16"
        }
        properties[kCGImagePropertyPixelWidth] = result.width
        properties[kCGImagePropertyPixelHeight] = result.height
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString:Any] {
            exif[kCGImagePropertyExifPixelXDimension] = result.width
            exif[kCGImagePropertyExifPixelYDimension] = result.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString:Any] {
            var updated = tiff; updated[kCGImagePropertyTIFFOrientation] = properties[kCGImagePropertyOrientation] ?? 1
            properties[kCGImagePropertyTIFFDictionary] = updated
        }
        return (result,properties,detail)
    }
    static func safeProperties(_ input:ImageInput,orientation:Int)->[CFString:Any] {
        // Exclude previews, descriptions, GPS, XMP and maker notes from redacted output.
        [kCGImagePropertyOrientation:orientation]
    }
    static func rawRect(_ rect:CGRect,image:CGImage,orientation:Int) throws -> CGRect {
        try rawRect(rect,width:image.width,height:image.height,orientation:orientation)
    }
    static func rawRect(_ rect:CGRect,width:Int,height:Int,orientation:Int) throws -> CGRect {
        guard [rect.minX,rect.minY,rect.width,rect.height].allSatisfy({$0.isFinite}),rect.width>0,rect.height>0,
              CGRect(x:0,y:0,width:1,height:1).contains(rect) else { throw EngineError.invalid("이미지 안의 유효한 영역을 선택해 주세요.") }
        func point(_ p:CGPoint)->CGPoint {
            switch orientation {
            case 2:return CGPoint(x:1-p.x,y:p.y)
            case 3:return CGPoint(x:1-p.x,y:1-p.y)
            case 4:return CGPoint(x:p.x,y:1-p.y)
            case 5:return CGPoint(x:p.y,y:p.x)
            case 6:return CGPoint(x:p.y,y:1-p.x)
            case 7:return CGPoint(x:1-p.y,y:1-p.x)
            case 8:return CGPoint(x:1-p.y,y:p.x)
            default:return p
            }
        }
        let corners = [CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.minX,y:rect.maxY),CGPoint(x:rect.maxX,y:rect.maxY)].map(point)
        let x = floor(corners.map(\.x).min()!*CGFloat(width)+0.0000001),y = floor(corners.map(\.y).min()!*CGFloat(height)+0.0000001)
        let right = ceil(corners.map(\.x).max()!*CGFloat(width)-0.0000001),bottom = ceil(corners.map(\.y).max()!*CGFloat(height)-0.0000001)
        return CGRect(x:x,y:y,width:right-x,height:bottom-y).intersection(CGRect(x:0,y:0,width:width,height:height))
    }
    static func displayRect(_ raw:CGRect,width:Int,height:Int,orientation:Int)->CGRect {
        func point(_ p:CGPoint)->CGPoint {
            let x=p.x/CGFloat(width),y=p.y/CGFloat(height)
            switch orientation {
            case 2:return CGPoint(x:1-x,y:y)
            case 3:return CGPoint(x:1-x,y:1-y)
            case 4:return CGPoint(x:x,y:1-y)
            case 5:return CGPoint(x:y,y:x)
            case 6:return CGPoint(x:1-y,y:x)
            case 7:return CGPoint(x:1-y,y:1-x)
            case 8:return CGPoint(x:y,y:1-x)
            default:return CGPoint(x:x,y:y)
            }
        }
        let points=[CGPoint(x:raw.minX,y:raw.minY),CGPoint(x:raw.maxX,y:raw.minY),CGPoint(x:raw.minX,y:raw.maxY),CGPoint(x:raw.maxX,y:raw.maxY)].map(point)
        let x=points.map(\.x).min()!,y=points.map(\.y).min()!
        return CGRect(x:x,y:y,width:points.map(\.x).max()!-x,height:points.map(\.y).max()!-y)
    }
    static func background(_ input:ImageInput,options:BackgroundOptions) throws -> CGImage {
        guard options.padding.isFinite,options.corner.isFinite,options.shadow.isFinite,(0...400).contains(options.padding),
              (0...80).contains(options.corner),(0...60).contains(options.shadow),!options.colors.isEmpty else { throw EngineError.invalid("배경 옵션 오류") }
        let image = try PDFEngine.oriented(input.image,input.orientation)
        let padding = CGFloat(options.padding.rounded()),naturalW = CGFloat(image.width)+2*padding,naturalH = CGFloat(image.height)+2*padding
        var w = naturalW,h = naturalH
        if let ratio = options.ratio {
            guard ratio.isFinite,ratio>0 else { throw EngineError.invalid("배경 비율 오류") }
            if w/h > ratio { h = ceil(w/ratio) } else { w = ceil(h*ratio) }
        }
        let ctx = try PDFEngine.bitmap(width:Int(w),height:Int(h),space:image.colorSpace!,depth:16)
        let box = CGRect(x:0,y:0,width:w,height:h)
        if let url = options.imageURL {
            let bg = try ImageInput(url),oriented = try PDFEngine.oriented(bg.image,bg.orientation)
            let scale = max(w/CGFloat(oriented.width),h/CGFloat(oriented.height))
            let bw = CGFloat(oriented.width)*scale,bh = CGFloat(oriented.height)*scale
            ctx.interpolationQuality = .high;ctx.draw(oriented,in:CGRect(x:(w-bw)/2,y:(h-bh)/2,width:bw,height:bh))
        } else if options.colors.count > 1 {
            let colors = options.colors.map{$0.cgColor}
            guard let gradient = CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),colors:colors as CFArray,locations:[0,1]) else { throw EngineError.invalid("그라데이션 생성 실패") }
            ctx.drawLinearGradient(gradient,start:CGPoint(x:0,y:h),end:CGPoint(x:w,y:0),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
        } else { ctx.setFillColor(options.colors[0].cgColor);ctx.fill(box) }
        let imageBox = CGRect(x:floor((w-CGFloat(image.width))/2),y:floor((h-CGFloat(image.height))/2),width:CGFloat(image.width),height:CGFloat(image.height))
        let path = CGPath(roundedRect:imageBox,cornerWidth:options.corner,cornerHeight:options.corner,transform:nil)
        if options.shadow > 0 {
            ctx.saveGState();ctx.setShadow(offset:CGSize(width:0,height:-options.shadow*0.3),blur:options.shadow,color:CGColor(gray:0,alpha:0.28))
            ctx.setFillColor(CGColor(gray:0,alpha:1));ctx.addPath(path);ctx.fillPath();ctx.restoreGState()
        }
        ctx.saveGState();ctx.addPath(path);ctx.clip();ctx.interpolationQuality = .none;ctx.draw(image,in:imageBox);ctx.restoreGState()
        return ctx.makeImage()!
    }
}
