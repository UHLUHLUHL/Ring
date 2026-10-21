import Foundation
import AVFoundation
import Darwin

/// Run each case in a fresh process: ru_maxrss is a process-lifetime peak.
/// Timed work includes Ring's validation and transactional publication.
@main struct EngineResourceBench {
    struct Case {
        let input: String, format: AnimationFormat, dimension: Int, duration: Double, jobs: Int
    }
    static let cases: [String: Case] = [
        "h264-webp": .init(input: "h264-720p.mp4", format: .webp, dimension: 640, duration: 4, jobs: 1),
        "h264-gif": .init(input: "h264-720p.mp4", format: .gif, dimension: 640, duration: 4, jobs: 1),
        "hevc-4k": .init(input: "hevc-4k.mp4", format: .webp, dimension: 1920, duration: 2, jobs: 1),
        "hevc-4k-dual": .init(input: "hevc-4k.mp4", format: .webp, dimension: 1920, duration: 2, jobs: 2),
        "prores": .init(input: "prores-1080p.mov", format: .webp, dimension: 640, duration: 2, jobs: 1),
        "long": .init(input: "h264-long.mp4", format: .webp, dimension: 640, duration: 12, jobs: 1),
        "single": .init(input: "h264-720p.mp4", format: .webp, dimension: 1280, duration: 4, jobs: 1),
        "dual": .init(input: "h264-720p.mp4", format: .webp, dimension: 1280, duration: 4, jobs: 2)
    ]
    static func emit(_ row: [String: Any]) throws {
        print(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
    }
    static func usage() -> rusage {
        var value = rusage()
        getrusage(RUSAGE_SELF, &value)
        return value
    }
    static func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
    static func main() async throws {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard args.count == 4 else { throw EngineError.invalid("usage: resource-bench fixture|run ROOT CASE") }
        let root = URL(fileURLWithPath: args[2], isDirectory: true), name = args[3]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if args[1] == "fixture" {
            let fixtures: [(String, AVVideoCodecType, Int, Int, Double)] = [
                ("h264-720p.mp4", .h264, 1280, 720, 4), ("hevc-4k.mp4", .hevc, 3840, 2160, 2),
                ("prores-1080p.mov", .proRes422, 1920, 1080, 2), ("h264-long.mp4", .h264, 1280, 720, 12)]
            for (file, codec, width, height, duration) in fixtures {
                let url = root.appendingPathComponent(file)
                // A rerun uses exactly the same input bytes; never replace an existing fixture.
                if !FileManager.default.fileExists(atPath: url.path) {
                    try await MediaFixture.write(url, codec: codec, width: width, height: height,
                        times: (0..<Int(duration * 30)).map { Double($0) / 30 }, duration: duration)
                }
            }
            return
        }
        guard let test = cases[name], args[1] == "run" else { throw EngineError.invalid("unknown benchmark case") }
        let info = ProcessInfo.processInfo, before = usage(), start = info.systemUptime
        let thermal = info.thermalState.rawValue, lowPower = info.isLowPowerModeEnabled
        let workers = ThermalPolicy.threads, policyJobs = ThermalPolicy.jobs
        var outputs: [EngineResult] = [], failure: Error?
        do {
            outputs = try await withThrowingTaskGroup(of: EngineResult.self) { group in
                for _ in 0..<test.jobs {
                    group.addTask {
                        try await RingEngine.shared.run(.init(source: root.appendingPathComponent(test.input),
                            operation: .video(.animation(.init(format: test.format, fps: 15, maxDimension: test.dimension, duration: test.duration)))))
                    }
                }
                var results: [EngineResult] = []
                for try await result in group { results.append(result) }
                return results
            }
        } catch { failure = error }
        let elapsed = info.systemUptime - start, after = usage()
        let cpu = seconds(after.ru_utime) + seconds(after.ru_stime) - seconds(before.ru_utime) - seconds(before.ru_stime)
        var row: [String: Any] = ["case": name, "status": failure == nil ? "ok" : "failed", "seconds": elapsed,
            "cpu_seconds": cpu, "cpu_percent_one_core": cpu / elapsed * 100,
            "peak_rss_bytes": after.ru_maxrss, "jobs": test.jobs, "dimension": test.dimension, "fps": 15,
            "duration_per_job": test.duration, "planned_output_frames_per_second": test.duration * 15 * Double(test.jobs) / elapsed,
            "thermal_start": thermal, "thermal_end": info.thermalState.rawValue, "low_power_start": lowPower,
            "low_power_end": info.isLowPowerModeEnabled, "policy_jobs_start": policyJobs, "workers_start": workers,
            "os": info.operatingSystemVersionString, "active_cpus": info.activeProcessorCount,
            "output_bytes": try outputs.map { try $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize! },
            "details": outputs.map(\.detail)]
        if let failure { row["error"] = failure.localizedDescription }
        try emit(row)
        if failure != nil { exit(1) }
    }
}
