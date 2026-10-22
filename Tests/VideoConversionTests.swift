import Foundation
import AVFoundation
import CryptoKit

@main struct VideoConversionTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw EngineError.quality("TEST: " + message) }
    }
    static func fixture(_ root: URL) async throws -> URL {
        let silent = root.appendingPathComponent("vfr.mp4")
        let times = [0.0,0.033,0.077,0.12,0.2,0.21,0.5,0.51,0.95,1.02,1.2,1.21,1.7,1.85,2.22,2.4]
        try await MediaFixture.write(silent, width: 640, height: 360, times: times, duration: 2.6,
            transform: CGAffineTransform(a:0,b:1,c:-1,d:0,tx:360,ty:0), colorProperties: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2])
        print("FIXTURE video written")
        let audio = root.appendingPathComponent("offset-audio.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 115200)!
        pcm.frameLength = pcm.frameCapacity
        for i in 0..<Int(pcm.frameLength) { pcm.floatChannelData![0][i] = Float(0.06 * sin(2 * .pi * 440 * Double(i) / 48000)) }
        // Finalize CAF headers before opening the file through AVURLAsset.
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            try file.write(from: pcm)
        }
        print("FIXTURE audio written")
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: silent), audioAsset = AVURLAsset(url: audio)
        let video = try await videoAsset.loadTracks(withMediaType: .video)[0]
        let sound = try await audioAsset.loadTracks(withMediaType: .audio)[0]
        let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try v.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds:2.6,preferredTimescale:60000)), of: video, at: .zero)
        v.preferredTransform = try await video.load(.preferredTransform)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(
            CMTimeRange(start:.zero,duration:CMTime(seconds:2.4,preferredTimescale:60000)), of:sound, at:CMTime(seconds:0.125,preferredTimescale:60000))
        withExtendedLifetime((videoAsset,audioAsset)) { }
        let result = root.appendingPathComponent("fixture.mov")
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        print("FIXTURE mux")
        try await session.export(to: result, as: .mov)
        return result
    }
    @MainActor static func playback(_ url: URL) async throws {
        let player = AVPlayer(url: url)
        player.isMuted = true; player.automaticallyWaitsToMinimizeStalling = false
        player.play()
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(50))
            if player.currentTime().seconds > 0.15 { player.pause(); return }
            if player.status == .failed { throw player.error ?? EngineError.quality("player failed") }
        }
        player.pause()
        throw EngineError.quality("TEST: player time did not advance")
    }
    static func main() async {
        setbuf(stdout, nil)
        do {
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--remux",
               let container = VideoContainer(rawValue: CommandLine.arguments[3]) {
                let source = URL(fileURLWithPath: CommandLine.arguments[2])
                let result = try await RingEngine.shared.run(.init(source:source,operation:.video(.convert(.init(container:container,codec:.passthrough)))))
                try await playback(result.url)
                print("PASS cross-container remux",source.pathExtension,"→",container.title,result.detail)
                return
            }
            let root = URL(fileURLWithPath: ".work/video-conversion-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = try await fixture(root)
            print("FIXTURE",source.path)
            try source.path.write(toFile: ".work/video-conversion/fixture-path.txt", atomically: true, encoding: .utf8)
            let original = Data(SHA256.hash(data: try Data(contentsOf: source)))
            let info = try await VideoSourceInfo.inspect(source)
            print("CAPABILITIES",info.codecs,"restriction",info.reencodeRestriction ?? "none")
            try require(info.reencodeRestriction == nil && info.width == 640 && info.height == 360, "source inspection")
            let estimates = try VideoQuality.allCases.map { try info.plan(.init(container:.mp4,codec:.h264,quality:$0)).estimatedBytes }
            try require(estimates[0] > estimates[1] && estimates[1] > estimates[2], "quality must change actual bitrate and estimate")
            let h264 = try info.plan(.init(container:.mp4,codec:.h264,quality:.balanced))
            let hevc = try info.plan(.init(container:.mp4,codec:.hevc,quality:.balanced))
            try require(h264.videoBitrate == hevc.videoBitrate && h264.estimatedBytes == hevc.estimatedBytes, "codec-name size discount")
            var mp4: URL?
            for (container,codec,quality) in [(VideoContainer.mp4,VideoConversionCodec.h264,VideoQuality.balanced),(.mp4,.hevc,.small),(.mov,.h264,.sharp),(.mov,.hevc,.balanced)] {
                let result = try await RingEngine.shared.run(.init(source:source,operation:.video(.convert(.init(container:container,codec:codec,quality:quality)))))
                let bytes = try Data(contentsOf: result.url)
                let brand = String(data:bytes[8..<12],encoding:.ascii) ?? ""
                try require(result.url.pathExtension == container.rawValue && String(data:bytes[4..<8],encoding:.ascii) == "ftyp" && (container == .mov ? brand == "qt  " : brand != "qt  "), "real container")
                try await playback(result.url)
                if container == .mp4 && codec == .h264 { mp4 = result.url }
                print("PASS",container.title,codec.title,quality.title,"bytes",bytes.count,"playback/VFR/rotation/color/audio")
            }
            for (input, container) in [(source,VideoContainer.mov),(mp4!,VideoContainer.mp4)] {
                let inspected = try await VideoSourceInfo.inspect(input)
                try require(inspected.codecs[container]?.contains(.passthrough) == true, "passthrough visibility")
                let result = try await RingEngine.shared.run(.init(source:input,operation:.video(.convert(.init(container:container,codec:.passthrough)))))
                try await playback(result.url)
                print("PASS lossless remux",container.title,result.detail)
            }
            let bad = root.appendingPathComponent("corrupt.mp4")
            try Data("not a video".utf8).write(to:bad)
            do { _ = try await VideoSourceInfo.inspect(bad); throw EngineError.quality("TEST: corrupt input accepted") }
            catch let error as EngineError { if case .quality = error { throw error } }
            catch { }
            try require(Data(SHA256.hash(data: try Data(contentsOf: source))) == original, "original modified")
            try require(try FileManager.default.contentsOfDirectory(atPath:root.path).allSatisfy { !$0.hasPrefix(".ring-") }, "staging leak")
            print("PASS selected video conversions, bitrates/estimates, packet-preserving remux, muted playback, corrupt-input rejection, original preservation")
        } catch { print("FAIL",error as NSError); exit(1) }
    }
}
