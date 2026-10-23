import Foundation
import AVFoundation
import CryptoKit

@main struct VideoQualityTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw EngineError.quality("TEST: " + message) }
    }
    static func metricChecks() throws {
        let width=128,height=128
        let reference=(0..<(width*height)).map { UInt8(($0%width/4 + $0/width/4)%2 == 0 ? 64:192) }
        func score(_ pixels:[UInt8]) -> RingVideoPlaneQuality {
            var result=RingVideoPlaneQuality()
            reference.withUnsafeBufferPointer { a in pixels.withUnsafeBufferPointer { b in
                precondition(ring_video_plane_quality(a.baseAddress,width,b.baseAddress,width,Int32(width),Int32(height),1,0,&result)==1)
            } }
            return result
        }
        let exact=score(reference),shifted=score(reference.map { $0+10 }),blurred=score([UInt8](repeating:128,count:width*height))
        try require(exact.ssim==1 && exact.mse==0,"identical pixels")
        try require(abs(shifted.mse-100)<0.000001,"known squared error")
        try require(blurred.ssim<0.1 && blurred.tail_ssim<0.1,"lost fine detail")
        var clean=VideoQualityReport(),colorDamage=VideoQualityReport(),flash=VideoQualityReport()
        for index in 0..<100 {
            clean.include(luma:exact,u:exact,v:exact)
            colorDamage.include(luma:exact,u:shifted,v:exact)
            flash.include(luma:index == 51 ? blurred:exact,u:exact,v:exact)
        }
        try require(clean.acceptable && !colorDamage.acceptable && !flash.acceptable,"color drift and single bad frame rejected")
        var floorOnly=VideoQualityReport()
        let nearFloor=RingVideoPlaneQuality(ssim:0.999,tail_ssim:0.99,mse:1.2)
        floorOnly.include(luma:nearFloor,u:nearFloor,v:nearFloor)
        try require(floorOnly.acceptable && !floorOnly.preferredForAutomatic && clean.preferredForAutomatic,
            "automatic fidelity must exceed the explicit-limit safety floor")
        try require(clean.distortion<floorOnly.distortion,"rank fidelity rather than file size")
        try require(clean.rateMargin(preferred:true)>0 && floorOnly.rateMargin(preferred:true)<0 &&
            colorDamage.rateMargin(preferred:false)<0 && flash.rateMargin(preferred:false)<0,"search coordinate respects every quality guard")
        try require(MediaEngine.preferVideoCandidate(floorOnly,bytes:950,over:clean,previousBytes:400,limit:1000,automatic:false),
            "a passing result in the byte band must win over an underfilled fallback")
        try require(!MediaEngine.preferVideoCandidate(clean,bytes:400,over:floorOnly,previousBytes:950,limit:1000,automatic:false),
            "higher fidelity must not silently replace an in-band target with an underfilled result")
        try require(MediaEngine.preferVideoCandidate(clean,bytes:900,over:clean,previousBytes:950,limit:1000,automatic:true) &&
            !MediaEngine.preferVideoCandidate(floorOnly,bytes:800,over:clean,previousBytes:950,limit:1000,automatic:true),
            "auto minimizes actual passing bytes and never relaxes its quality floor")
        let edgeWidth=17,edgeHeight=9
        var edge=[UInt8](repeating:100,count:edgeWidth*edgeHeight),edgeResult=RingVideoPlaneQuality()
        edge[edge.count-1]=200
        let base=[UInt8](repeating:100,count:edge.count)
        base.withUnsafeBufferPointer { a in edge.withUnsafeBufferPointer { b in
            precondition(ring_video_plane_quality(a.baseAddress,edgeWidth,b.baseAddress,edgeWidth,Int32(edgeWidth),Int32(edgeHeight),1,0,&edgeResult)==1)
        } }
        try require(abs(edgeResult.mse-10000.0/Double(edge.count))<1e-9 && edgeResult.ssim<1,"partial edge blocks measured")
        print("PASS pixel identity, known error, fine-detail loss, chroma drift, single-frame quality gate")
    }
    static func compare(_ source: URL,_ output: URL,crop:VideoCrop = .full,maxDimension:Int? = nil) async throws -> VideoQualityReport {
        let asset=AVURLAsset(url:source),result=AVURLAsset(url:output),info=try await VideoSourceInfo.inspect(source)
        let track=try await asset.loadTracks(withMediaType:.video)[0],out=try await result.loadTracks(withMediaType:.video)[0]
        let natural=try await track.load(.naturalSize),transform=try await track.load(.preferredTransform)
        let shown=natural.applying(transform),size=VideoCropGeometry.compressedSize(width:abs(shown.width),height:abs(shown.height),crop:crop,maxDimension:maxDimension)
        let region=crop.isFull ? nil:crop.pixelRect(width:Int(abs(shown.width)),height:Int(abs(shown.height)))
        let swaps=region == nil && abs(transform.b)>0.5
        return try await VideoQuality.compare(source:asset,video:track,output:result,track:out,
            width:swaps ? size.height:size.width,height:swaps ? size.width:size.height,natural:natural,transform:transform,
            crop:region,fullRange:info.fullRange,duration:info.duration)
    }
    static func main() async {
        setbuf(stdout,nil)
        do {
            try metricChecks()
            let root=URL(fileURLWithPath:".work/video-quality-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            if CommandLine.arguments.count==2,CommandLine.arguments[1]=="--budget" {
                let paths=try JSONDecoder().decode([String].self,from:Data(contentsOf:URL(fileURLWithPath:".work/video-fidelity/sources.json")))
                let source=URL(fileURLWithPath:paths[1]),output=root.appendingPathComponent("budget.mp4")
                let before=SHA256.hash(data:try Data(contentsOf:source,options:.mappedIfSafe))
                let detail=try await MediaEngine.compress(source,to:output,options:.init(targetBytes:20_000_000,codec:.hevc))
                let bytes=try output.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                try require(bytes>=18_000_000 && bytes<=20_000_000,"representative 20 MB target should preserve quality within the budget")
                let quality=try await compare(source,output)
                try require(quality.acceptable,"explicit-limit quality floor")
                try require(Array(before)==Array(SHA256.hash(data:try Data(contentsOf:source,options:.mappedIfSafe))),"budget source changed")
                try await VideoConversionTestsPlayback.play(output)
                print("PASS 20 MB quality budget",detail)
                return
            }
            if CommandLine.arguments.count==2,CommandLine.arguments[1]=="--real" {
                let paths=try JSONDecoder().decode([String].self,from:Data(contentsOf:URL(fileURLWithPath:".work/video-fidelity/sources.json")))
                for index in [1,2] {
                    let source=URL(fileURLWithPath:paths[index]),output=root.appendingPathComponent("real-\(index).mp4")
                    let original=SHA256.hash(data:try Data(contentsOf:source,options:.mappedIfSafe)),start=Date()
                    let info=try await VideoSourceInfo.inspect(source)
                    print("START real",info.sourceBytes,"thermal",ProcessInfo.processInfo.thermalState.rawValue,"lowPower",ProcessInfo.processInfo.isLowPowerModeEnabled)
                    let detail=try await MediaEngine.compress(source,to:output,options:.init(codec:.hevc))
                    print("PASS real",detail,"seconds",Date().timeIntervalSince(start),"OUTPUT",output.path)
                    try await VideoConversionTestsPlayback.play(output)
                    try require(Array(original)==Array(SHA256.hash(data:try Data(contentsOf:source,options:.mappedIfSafe))),"real original changed")
                }
                return
            }
            let times=[0.0,0.017,0.033,0.077,0.12,0.2,0.21,0.5,0.51,0.95,1.02,1.2,1.21,1.7,1.85,2.22,2.4]
            let source=root.appendingPathComponent("vfr.mp4"),rotation=CGAffineTransform(a:0,b:1,c:-1,d:0,tx:360,ty:0)
            try await MediaFixture.write(source,width:640,height:360,times:times,duration:2.6,transform:rotation,bitrate:20_000_000,keyFrameInterval:1)
            let identical=try await compare(source,source)
            try require(identical.frames==times.count && identical.meanSSIM==1 && identical.acceptable,"native decoder self comparison")
            for altered in [Array(times.dropFirst()),times.enumerated().map { $0.offset==10 ? $0.element+0.005:$0.element }] {
                let bad=root.appendingPathComponent(UUID().uuidString+".mp4")
                try await MediaFixture.write(bad,width:640,height:360,times:altered,duration:2.6,transform:rotation)
                do {
                    _ = try await compare(source,bad)
                    throw EngineError.quality("TEST: dropped/retimed frame accepted")
                } catch let error as EngineError { if case .quality(let reason)=error,reason.hasPrefix("TEST:") { throw error } }
            }
            print("PASS native VFR identity, dropped/retimed frame rejection")
            // A nonzero first picture creates an empty movie edit. The native
            // decoder can emit a synthetic black placeholder for that gap;
            // encoding it would add a picture, while coarse movie timescales
            // would shift every real presentation timestamp.
            let delayed=root.appendingPathComponent("delayed.mp4"),delayedOut=root.appendingPathComponent("delayed-out.mp4")
            try await MediaFixture.write(delayed,width:640,height:360,times:times.map{$0+0.0297666667},duration:2.64,bitrate:20_000_000)
            let delayedAsset=AVURLAsset(url:delayed),delayedTrack=try await delayedAsset.loadTracks(withMediaType:.video)[0]
            let delayedInfo=try await VideoSourceInfo.inspect(delayed)
            try await MediaEngine.encode(delayedAsset,to:delayedOut,video:delayedTrack,audio:nil,duration:try await delayedAsset.load(.duration),
                width:640,height:360,transform:.identity,natural:CGSize(width:640,height:360),crop:nil,bitrate:20_000_000,codec:.hevc,
                colorProperties:delayedInfo.colorProperties,fullRange:delayedInfo.fullRange)
            let delayedResult=AVURLAsset(url:delayedOut),delayedResultTrack=try await delayedResult.loadTracks(withMediaType:.video)[0]
            try MediaEngine.verifyFrameTiming(source:delayedAsset,video:delayedTrack,output:delayedResult,track:delayedResultTrack)
            let delayedQuality=try await compare(delayed,delayedOut)
            try require(delayedQuality.frames==times.count && delayedQuality.acceptable,"empty edits must not add pictures or shift VFR times")
            print("PASS empty movie edit and nonzero first-picture timing")
            for (crop,limit,codec) in [(VideoCrop.full,Optional<Int>.none,VideoCodec.hevc),(.init(ratio:.square),320,.hevc),(.full,nil,.h264)] {
                let output=root.appendingPathComponent(UUID().uuidString+".mp4")
                let detail=try await MediaEngine.compress(source,to:output,options:.init(codec:codec,maxDimension:limit,crop:crop))
                let quality=try await compare(source,output,crop:crop,maxDimension:limit)
                try require(quality.frames==times.count && quality.preferredForAutomatic,"auto preferred quality/VFR/crop")
                try await VideoConversionTestsPlayback.play(output)
                print("PASS auto",detail)
            }
            let impossible=root.appendingPathComponent("impossible.mp4")
            do {
                _ = try await MediaEngine.compress(source,to:impossible,options:.init(targetBytes:40000,codec:.hevc))
                throw EngineError.quality("TEST: impossible high-quality byte target accepted")
            } catch let error as EngineError {
                if case .quality(let reason)=error,!reason.hasPrefix("TEST:") {
                    try require(!FileManager.default.fileExists(atPath:impossible.path),"rejected target published")
                } else { throw error }
            }
            print("PASS infeasible byte target rejected without publication")
            let before=try FileManager.default.contentsOfDirectory(atPath:root.path).sorted()
            let job=Task { try await RingEngine.shared.run(.init(source:source,operation:.video(.compress(.init(codec:.h264))))) }
            try await Task.sleep(for:.milliseconds(30));job.cancel()
            do { _ = try await job.value;throw EngineError.quality("TEST: cancelled job published") }
            catch is CancellationError { }
            let after=try FileManager.default.contentsOfDirectory(atPath:root.path).sorted()
            try require(before==after,"cancellation output or staging leak")
            print("PASS cancellation without publication or scratch leak")
        } catch { print("FAIL",error as NSError);exit(1) }
    }
}

private enum VideoConversionTestsPlayback {
    @MainActor static func play(_ url:URL) async throws {
        let player=AVPlayer(url:url)
        player.isMuted=true;player.automaticallyWaitsToMinimizeStalling=false;player.play()
        defer { player.pause() }
        for _ in 0..<40 {
            try await Task.sleep(for:.milliseconds(50))
            if player.currentTime().seconds>0.15 { print("PASS muted playback");return }
            if player.status == .failed { throw player.error ?? EngineError.quality("TEST: player failed") }
        }
        throw EngineError.quality("TEST: playback time did not advance")
    }
}
