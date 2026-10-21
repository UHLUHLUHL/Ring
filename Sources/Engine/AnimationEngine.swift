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
        let asset = AVURLAsset(url: source), assetDuration = try await asset.load(.duration)
        let duration = options.duration ?? (assetDuration.seconds - options.start)
        guard options.start.isFinite, duration.isFinite, options.start >= 0, duration > 0,
              options.start + duration <= assetDuration.seconds + 0.001,
              options.fps.isFinite, (1...AnimationOptions.maximumFPS).contains(options.fps),
              (16...1920).contains(options.maxDimension), duration * options.fps <= Double(AnimationOptions.maximumFrames),
              options.targetBytes == nil || options.targetBytes! > 0 else {
            throw EngineError.invalid("애니메이션 시간·FPS·크기 오류 (최대 60fps·1,800프레임)")
        }
        guard let sourceTrack=try await asset.loadTracks(withMediaType:.video).first else { throw EngineError.unsupported("비디오 트랙을 찾지 못했어요.") }
        let naturalSize=try await sourceTrack.load(.naturalSize),preferredTransform=try await sourceTrack.load(.preferredTransform)
        let displaySize=naturalSize.applying(preferredTransform)
        func extractionSize(for dimension:Int)->CGSize {
            VideoCropGeometry.extractionSize(width:abs(Double(displaySize.width)),height:abs(Double(displaySize.height)),ratio:options.cropRatio,maxDimension:dimension)
        }
        let resources = AnimationResources.shared
        resources.enter(); defer { resources.leave() }
        var fps = options.fps, dimension = options.maxDimension, lastSize = 0
        let initial = AnimationPlan(duration: duration, fps: fps, format: options.format)
        if let target = options.targetBytes, initial.frames.count >= 48,
           target < Int64(initial.frames.count) * Int64(dimension * dimension) * 2 {
            let sample = initial.sample
            let encoded = try await AnimationPipeline.encode(asset: asset, start: options.start, fps: fps, dimension: dimension,
                extractionSize:extractionSize(for:dimension),cropRatio: options.cropRatio, plan: sample, format: options.format, quality: 85, allowParallelWebP: false) { EngineProgress.report(0.03 + 0.07 * $0) }
            let estimate = Double(encoded.bytes.count) * Double(initial.frames.count) / Double(sample.frames.count) * 1.10
            if estimate > Double(target) * 1.10 {
                let ratio = max(0.4, min(0.95, sqrt(Double(target) / estimate) * 0.95))
                dimension = max(16, Int(Double(dimension) * ratio))
            }
        }
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let plan = AnimationPlan(duration: duration, fps: fps, format: options.format)
            let encoded = try await AnimationPipeline.encode(asset: asset, start: options.start, fps: fps, dimension: dimension,
                extractionSize:extractionSize(for:dimension),cropRatio: options.cropRatio, plan: plan, format: options.format, quality: max(40, 85 - attempt * 10), allowParallelWebP: options.targetBytes == nil) {
                    EngineProgress.report(0.10 + 0.80 * $0)
                }
            EngineProgress.report(0.92)
            lastSize = encoded.bytes.count
            if options.targetBytes == nil || Int64(lastSize) <= options.targetBytes! {
                try AnimationPipeline.verify(encoded, plan: plan, format: options.format)
                try Task.checkCancellation()
                EngineProgress.report(0.94)
                try encoded.bytes.write(to: output)
                return "\(options.format.rawValue.uppercased()) · \(encoded.width)×\(encoded.height) · \(AnimationOptions.frameRateText(fps))fps · \(lastSize)바이트" + (options.format == .gif ? " · 적응형 256색·오차 확산 디더링" : "")
            }
            let ratio = sqrt(Double(options.targetBytes!) / Double(max(1, lastSize))) * 0.90
            dimension = max(16, Int(Double(dimension) * max(0.4, min(0.85, ratio))))
            fps = max(1, fps * 0.8)
            EngineProgress.report(0.10)
        }
        throw EngineError.quality("애니메이션 \(lastSize)바이트가 목표를 초과했어요.")
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
        buckets.reserveCapacity(256)
        while buckets.count<256 {
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
        var cache=[Int](repeating:-1,count:32768),pixels=Data(count:width*height)
        let rowLen = (width + 2) * 3
        var current=[Float](repeating:0,count:rowLen),next=[Float](repeating:0,count:rowLen)
        let pCount = palette.count
        try rgba.withUnsafeBytes { rawIn in
            try pixels.withUnsafeMutableBytes { rawOut in
                let src = rawIn.bindMemory(to: UInt8.self).baseAddress!
                let dst = rawOut.bindMemory(to: UInt8.self).baseAddress!
                try palette.withUnsafeBufferPointer { pal in
                    try cache.withUnsafeMutableBufferPointer { cacheBuf in
                        try current.withUnsafeMutableBufferPointer { curBuf in
                            try next.withUnsafeMutableBufferPointer { nxtBuf in
                                var cur = curBuf.baseAddress!
                                var nxt = nxtBuf.baseAddress!
                                for y in 0..<height {
                                    if (y & 31) == 0 { try Task.checkCancellation() }
                                    let rowOffset = y * width
                                    for x in 0..<width {
                                        let p = (rowOffset + x) * 4, e = (x + 1) * 3
                                        let r = max(0, min(255, Int((Float(src[p]) + cur[e]).rounded())))
                                        let g = max(0, min(255, Int((Float(src[p+1]) + cur[e+1]).rounded())))
                                        let b = max(0, min(255, Int((Float(src[p+2]) + cur[e+2]).rounded())))
                                        let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                                        var index = cacheBuf[key]
                                        if index < 0 {
                                            let rr = ((key >> 10) & 31) * 8 + 4, gg = ((key >> 5) & 31) * 8 + 4, bb = (key & 31) * 8 + 4
                                            var best = 0, distance = Int.max
                                            for i in 0..<pCount {
                                                let c = pal[i]
                                                let d = (rr - c.r) * (rr - c.r) + (gg - c.g) * (gg - c.g) + (bb - c.b) * (bb - c.b)
                                                if d < distance { distance = d; best = i }
                                            }
                                            cacheBuf[key] = best
                                            index = best
                                        }
                                        let color = pal[index]
                                        dst[rowOffset + x] = UInt8(index)
                                        let dr = Float(r - color.r), dg = Float(g - color.g), db = Float(b - color.b)
                                        cur[e+3] += dr * (7.0/16.0); nxt[e-3] += dr * (3.0/16.0); nxt[e] += dr * (5.0/16.0); nxt[e+3] += dr * (1.0/16.0)
                                        cur[e+4] += dg * (7.0/16.0); nxt[e-2] += dg * (3.0/16.0); nxt[e+1] += dg * (5.0/16.0); nxt[e+4] += dg * (1.0/16.0)
                                        cur[e+5] += db * (7.0/16.0); nxt[e-1] += db * (3.0/16.0); nxt[e+2] += db * (5.0/16.0); nxt[e+5] += db * (1.0/16.0)
                                    }
                                    swap(&cur, &nxt)
                                    nxt.initialize(repeating: 0, count: rowLen)
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
