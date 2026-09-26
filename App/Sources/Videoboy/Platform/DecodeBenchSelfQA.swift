//
//  DecodeBenchSelfQA.swift — what one clip costs the main thread, per file.
//
//  Purpose : `stress` and `soak` load the fixtures in samples/, which are small SD
//            files. A performer's library is camera and phone footage: HD H.264,
//            HEVC, ProRes. Every decode runs on the main thread (the render tick), so
//            the costs that matter are per-FILE: opening it (a drop mid-show), the
//            steady frame (playback), the worst frame (a GOP boundary), a cold library
//            thumbnail (hover and import), and how much memory the decoder holds.
//  Inputs  : samples/*, plus any paths in VIDEOBOY_BENCH_CLIPS (colon-separated).
//  Outputs : selfqa/out/perf/decode/{result.txt, decode.csv}.
//  Connects: ClipDecoders, ClipSourceNode, ClipThumbnails.
//  Extend  : add a column to the CSV; keep timing release builds only.
//

import AppKit
import Darwin
import VideoboyCore

enum DecodeBenchSelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/decode")
        var urls = ["bars.dv", "motion.dv", "motion.m2v", "motion.mov"]
            .map { RepoPaths.samples.appendingPathComponent($0) }
        if let extra = ProcessInfo.processInfo.environment["VIDEOBOY_BENCH_CLIPS"] {
            urls += extra.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        urls = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return check.finish(blockedReason: "no clips to measure") }

        let budget = 1000.0 / StandardDefinition.frameRate
        var csv = "file,open_ms,first_frame_ms,steady_mean_ms,steady_worst_ms,frame_w,frame_h,decoder_mb,thumb_cold_ms,thumb_mb_per_clip\n"
        var overBudget: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            let memoryBefore = footprintMB()

            let node = ClipSourceNode(identifier: "bench.\(name)")
            var t = CACurrentMediaTime()
            guard node.load(url: url) else {
                check.note("\(name): could not load")
                continue
            }
            let openMs = (CACurrentMediaTime() - t) * 1000
            node.isPlaying = true
            var frameMs: [Double] = []
            var size = (0, 0)
            for frame in 0..<150 {
                let context = RenderContext(frameIndex: frame, presentationTime: 0, musicalPosition: nil)
                t = CACurrentMediaTime()
                let texture = node.render(inputs: [], context: context)
                MetalContext.shared?.waitForIdle()
                frameMs.append((CACurrentMediaTime() - t) * 1000)
                if let texture { size = (texture.width, texture.height) }
            }
            let decoderMB = footprintMB() - memoryBefore
            let first = frameMs.first ?? 0
            let steady = Array(frameMs.dropFirst())
            let steadyMean = steady.reduce(0, +) / Double(max(steady.count, 1))
            let steadyWorst = steady.max() ?? 0
            node.unload()

            // A cold thumbnail: what hovering a fresh tile costs.
            ClipThumbnails.shared.invalidate()
            let thumbBefore = footprintMB()
            t = CACurrentMediaTime()
            _ = ClipThumbnails.shared.poster(for: url)
            let thumbMs = (CACurrentMediaTime() - t) * 1000
            for step in 1..<ClipThumbnails.steps {
                _ = ClipThumbnails.shared.frame(for: url, at: Double(step) / Double(ClipThumbnails.steps - 1))
            }
            let thumbMB = footprintMB() - thumbBefore
            ClipThumbnails.shared.invalidate()

            csv += String(format: "%@,%.2f,%.2f,%.2f,%.2f,%d,%d,%.1f,%.2f,%.2f\n",
                          name, openMs, first, steadyMean, steadyWorst, size.0, size.1, decoderMB, thumbMs, thumbMB)
            check.note(String(format: "%@: open %.1f ms, first frame %.1f ms, steady %.2f ms (worst %.1f), %dx%d, decoder ~%.0f MB, cold thumbnail %.1f ms",
                              name, openMs, first, steadyMean, steadyWorst, size.0, size.1, decoderMB, thumbMs))
            // One channel's steady decode must leave room for three more plus the effects.
            if steadyWorst > budget / 4 || openMs + first > budget || thumbMs > budget {
                overBudget.append(name)
            }
        }
        do {
            try csv.write(to: check.artifactURL("decode.csv"), atomically: true, encoding: .utf8)
        } catch {
            Log.error(.selfqa, "could not write decode.csv: \(error)")
        }
        check.record(AssertionResult(
            name: "every clip opens, decodes and thumbnails inside the main thread's frame budget",
            passed: overBudget.isEmpty,
            detail: overBudget.isEmpty ? "\(urls.count) clips within budget"
                : "over budget: " + overBudget.joined(separator: ", ")))
        return check.finish()
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
