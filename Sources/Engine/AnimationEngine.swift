import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

extension MediaEngine {
    static func sourceFrameRate(_ asset: AVAsset) async throws -> Double? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let nominal = Double(try await track.load(.nominalFrameRate))
        if nominal.isFinite, nominal > 0 { return nominal }
        let minimum = try await track.load(.minFrameDuration).seconds
        return minimum.isFinite && minimum > 0 ? 1 / minimum : nil
    }

    static func animate(_ source: URL, to output: URL, options: AnimationOptions) async throws -> String {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let assetDuration = try await asset.load(.duration)
        let duration = options.duration ?? (assetDuration.seconds - options.start)
        guard options.start.isFinite, duration.isFinite, options.start >= 0, duration > 0,
              options.start + duration <= assetDuration.seconds + 0.001,
              options.fps.isFinite, (1...AnimationOptions.maximumFPS).contains(options.fps),
              (2...(options.format == .webp ? 16383:65535)).contains(options.maxDimension), duration * options.fps <= Double(AnimationOptions.maximumFrames),
              options.targetBytes == nil || options.targetBytes! > 0 else {
            throw EngineError.invalid("애니메이션 시간·FPS·크기 오류 (최대 60fps·1,800프레임)")
        }
        guard let sourceTrack=try await asset.loadTracks(withMediaType:.video).first else { throw EngineError.unsupported("비디오 트랙을 찾지 못했어요.") }
        let naturalSize=try await sourceTrack.load(.naturalSize),preferredTransform=try await sourceTrack.load(.preferredTransform)
        let displaySize=naturalSize.applying(preferredTransform)
        func extractionSize(for dimension:Int)->CGSize {
            VideoCropGeometry.extractionSize(width:abs(Double(displaySize.width)),height:abs(Double(displaySize.height)),crop:options.crop,maxDimension:dimension)
        }
        let resources = AnimationResources.shared
        resources.enter(); defer { resources.leave() }
        let fps = options.fps
        var dimension = options.maxDimension, lastSize = 0
        var previousSize: (pixels: Int, bytes: Int)?
        let initial = AnimationPlan(duration: duration, fps: fps, format: options.format)
        if let target = options.targetBytes, initial.frames.count >= 48,
           target < Int64(initial.frames.count) * Int64(dimension * dimension) * 2 {
            let sample = initial.sample
            let encoded = try await AnimationPipeline.encode(asset: asset, start: options.start, fps: fps, dimension: dimension,
                extractionSize:extractionSize(for:dimension),crop: options.crop, plan: sample, format: options.format, quality: 90, allowParallelWebP: true) { EngineProgress.report(0.03 + 0.07 * $0) }
            let estimate = Double(encoded.bytes.count) * Double(initial.frames.count) / Double(sample.frames.count) * 1.03
            if estimate > Double(target) {
                let ratio = max(0.1, min(0.98, sqrt(Double(target) / estimate) * 0.98))
                dimension = max(min(16,dimension), Int(Double(dimension) * ratio))
            }
        }
        for _ in 0..<4 {
            try Task.checkCancellation()
            let plan = AnimationPlan(duration: duration, fps: fps, format: options.format)
            let encoded = try await AnimationPipeline.encode(asset: asset, start: options.start, fps: fps, dimension: dimension,
                extractionSize:extractionSize(for:dimension),crop: options.crop, plan: plan, format: options.format, quality: 90, allowParallelWebP: true) {
                    EngineProgress.report(0.10 + 0.80 * $0)
                }
            EngineProgress.report(0.92)
            lastSize = encoded.bytes.count
            if options.targetBytes == nil || Int64(lastSize) <= options.targetBytes! {
                try AnimationPipeline.verify(encoded, plan: plan, format: options.format)
                try Task.checkCancellation()
                EngineProgress.report(0.94)
                try encoded.bytes.write(to: output)
                return "\(options.format.rawValue.uppercased()) · \(encoded.width)×\(encoded.height) · \(AnimationOptions.frameRateText(fps))fps · \(lastSize)바이트" + (options.format == .gif ? " · 적응형 255색·오차 확산 디더링" : "")
            }
            let excess = Double(options.targetBytes!) / Double(max(1, lastSize))
            // Keep the requested cadence and q90 profile throughout the
            // search. Correct spatial size using actual encoded bytes, rather
            // than simultaneously changing FPS, quality and resolution.
            var ratio = sqrt(excess)
            let pixels = encoded.width*encoded.height
            if let previous=previousSize,previous.pixels>pixels,previous.bytes>lastSize {
                // Fit bytes = pixelCost * pixels + fixedCost from two actual
                // encodes. Palettes/headers otherwise make sqrt(target/bytes)
                // converge very slowly near small GIF/WebP byte limits.
                let cost=Double(previous.bytes-lastSize)/Double(previous.pixels-pixels)
                let overhead=max(0,Double(lastSize)-cost*Double(pixels))
                let projected=max(1,(Double(options.targetBytes!)-overhead)/cost)
                ratio=min(ratio,max(0.35,sqrt(projected/Double(pixels))))
            }
            previousSize=(pixels,lastSize)
            let next = max(min(16, dimension), Int(Double(max(encoded.width,encoded.height)) * min(0.98, ratio * 0.96)))
            if next >= dimension { break }
            dimension = next
            EngineProgress.report(0.10)
        }
        throw EngineError.quality("지정한 FPS와 인코딩 품질 설정으로 목표 용량을 맞추지 못했어요 (\(lastSize)바이트). 목표를 높여 주세요.")
    }
}

/// Native median cut over a bounded RGB histogram, followed by Floyd–Steinberg
/// error diffusion. vImage is used by the shared resize path; no codec subprocess.
enum AdaptivePalette {
    private static let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func sRGB(_ image:CGImage) throws -> Data {
        let w = image.width, h = image.height
        var data = Data(count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: w,
                      height: h,
                      bitsPerComponent: 8,
                      bytesPerRow: w * 4,
                      space: sRGBSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw EngineError.io("sRGB 변환 버퍼 생성 실패") }
        return data
    }
    private struct Color {
        var r:Int=0,g:Int=0,b:Int=0,count:Int=0
        @inline(__always) func component(_ channel:Int)->Int { channel==0 ? r:(channel==1 ? g:b) }
    }
    static func indexed(_ image:CGImage) throws -> CGImage {
        let rgba=try sRGB(image),width=image.width,height=image.height
        var histogram=[Color](repeating:Color(),count:32768)
        rgba.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            let total = width * height * 4
            var p = 0
            while p < total {
                let r = Int(ptr[p]), g = Int(ptr[p+1]), b = Int(ptr[p+2])
                let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                histogram[key].r += r
                histogram[key].g += g
                histogram[key].b += b
                histogram[key].count += 1
                p += 4
            }
        }
        var colors:[Color]=[]
        colors.reserveCapacity(4096)
        for h in histogram where h.count > 0 {
            colors.append(Color(r:h.r/h.count,g:h.g/h.count,b:h.b/h.count,count:h.count))
        }
        if colors.isEmpty { throw EngineError.invalid("빈 애니메이션 이미지") }
        struct Bucket { var colors:[Color];var channel:Int;var score:Int }
        func bucket(_ colors:[Color])->Bucket {
            var minR=255,maxR=0,minG=255,maxG=0,minB=255,maxB=0,totalCount=0
            for c in colors {
                if c.r < minR { minR = c.r }; if c.r > maxR { maxR = c.r }
                if c.g < minG { minG = c.g }; if c.g > maxG { maxG = c.g }
                if c.b < minB { minB = c.b }; if c.b > maxB { maxB = c.b }
                totalCount += c.count
            }
            let rRange = maxR - minR, gRange = maxG - minG, bRange = maxB - minB
            let channel: Int
            let maxRange: Int
            if rRange >= gRange && rRange >= bRange { channel = 0; maxRange = rRange }
            else if gRange >= bRange { channel = 1; maxRange = gRange }
            else { channel = 2; maxRange = bRange }
            return Bucket(colors:colors,channel:channel,score:maxRange*totalCount)
        }
        var buckets=[bucket(colors)]
        // ImageIO's GIF writer marks index 255 transparent on every frame, so
        // the palette stops at 255 colors and leaves that index unused.
        buckets.reserveCapacity(255)
        while buckets.count<255 {
            var bestIdx = -1, bestScore = -1
            for idx in buckets.indices where buckets[idx].colors.count > 1 {
                if buckets[idx].score > bestScore { bestScore = buckets[idx].score; bestIdx = idx }
            }
            guard bestIdx >= 0 else { break }
            let old=buckets.remove(at:bestIdx),channel=old.channel
            colors=old.colors.sorted { $0.component(channel)<$1.component(channel) }
            let half=colors.reduce(0) { $0+$1.count }/2
            var count=0,split=1
            for i in 0..<(colors.count-1) { count+=colors[i].count;split=i+1;if count>=half { break } }
            buckets.append(bucket(Array(colors[..<split])));buckets.append(bucket(Array(colors[split...])))
        }
        let palette=buckets.map { bucket -> Color in
            let count=bucket.colors.reduce(0) { $0+$1.count }
            return Color(r:bucket.colors.reduce(0) { $0+$1.r*$1.count }/count,g:bucket.colors.reduce(0) { $0+$1.g*$1.count }/count,b:bucket.colors.reduce(0) { $0+$1.b*$1.count }/count,count:count)
        }
        var lookup=Data( capacity: palette.count * 3 )
        for color in palette { lookup.append(contentsOf:[UInt8(color.r),UInt8(color.g),UInt8(color.b)]) }
        var cache=[Int16](repeating:-1,count:32768),pixels=Data(count:width*height)
        var errors=[Float](repeating:0,count:(width+2)*3*2)
        try rgba.withUnsafeBytes { input in
            try pixels.withUnsafeMutableBytes { output in
                try lookup.withUnsafeBytes { palette in
                    try cache.withUnsafeMutableBufferPointer { cache in
                        try errors.withUnsafeMutableBufferPointer { errors in
                            for row in stride(from:0,to:height,by:32) {
                                try Task.checkCancellation()
                                guard ring_palette_dither(input.bindMemory(to:UInt8.self).baseAddress!,Int32(width),Int32(height),
                                    Int32(row),Int32(min(32,height-row)),palette.bindMemory(to:UInt8.self).baseAddress!,Int32(buckets.count),
                                    output.bindMemory(to:UInt8.self).baseAddress!,cache.baseAddress!,errors.baseAddress!) == 1 else {
                                    throw EngineError.io("팔레트 픽셀 변환 실패")
                                }
                            }
                        }
                    }
                }
            }
        }
        let space=lookup.withUnsafeBytes { CGColorSpace(indexedBaseSpace:sRGBSpace,last:palette.count-1,colorTable:$0.bindMemory(to:UInt8.self).baseAddress!) }
        guard let space,let provider=CGDataProvider(data:pixels as CFData),let result=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:width,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { throw EngineError.io("팔레트 이미지 생성 실패") }
        return result
    }
}
