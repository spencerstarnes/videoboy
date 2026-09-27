//
//  OptimizeQueue.swift — Copy + Optimize's conversions, one child process at a time.
//
//  Purpose : Proposal §5/§7. Each clip is converted by `Videoboy --optimize` running as
//            a separate process at background priority: a crash in a decoder cannot
//            take the show down, and Cancel is a SIGTERM. Output is written into
//            `<Optimized Media>/.videoboy-partial/` and renamed into place only when
//            complete; only then is it linked to the clip in the catalog.
//  Inputs  : jobs (library clip id + source file) and a preset.
//  Outputs : progress for the status strip; a link per finished clip; a reason per
//            failed one (the clip keeps playing its original).
//  Connects: ShellController (enqueues after a Copy import; shows progress),
//            LibraryModel.setOptimized, main.swift's `--optimize`.
//  Extend  : a pause-while-live rule would hold `startNext` while output is on air.
//
//  THREADING: everything here runs on the main thread; the child's output arrives on a
//  pipe handler and is handed back through the main run loop.
//

import Foundation
import VideoboyCore

final class OptimizeQueue {

    struct Job: Equatable {
        let clipID: String
        let source: URL
        let preset: OptimizePreset
    }

    /// "Optimizing 3 / 12 — name.mov (40%)", or nil when idle.
    var onStatus: ((String?) -> Void)?
    /// A clip finished: its optimized file, or nil and why.
    var onFinished: ((Job, URL?, String?) -> Void)?

    private let location: () -> URL
    private var pending: [Job] = []
    private var current: (job: Job, process: Process, partial: URL)?
    private var finishedCount = 0
    private var totalCount = 0

    /// - Parameter location: the Optimized Media folder (read when each job starts).
    init(location: @escaping () -> URL) {
        self.location = location
    }

    var isBusy: Bool { current != nil || !pending.isEmpty }
    /// Jobs waiting or running — for self-QA.
    var countForChecks: Int { pending.count + (current == nil ? 0 : 1) }

    func enqueue(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        pending += jobs
        totalCount += jobs.count
        Log.info(.app, "optimize: \(jobs.count) queued (\(pending.count) waiting)")
        if current == nil { startNext() }
    }

    /// Stops the running conversion (its partial file is deleted) and drops the rest.
    func cancelAll() {
        pending.removeAll()
        if let current {
            current.process.terminate()
            Log.info(.app, "optimize: cancelled \(current.job.source.lastPathComponent)")
        }
    }

    private func startNext() {
        guard current == nil, !pending.isEmpty else {
            if current == nil {
                finishedCount = 0
                totalCount = 0
                onStatus?(nil)
            }
            return
        }
        let job = pending.removeFirst()
        let folder = location()
        let partialFolder = folder.appendingPathComponent(FileTransfer.partialFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: partialFolder, withIntermediateDirectories: true)
        } catch {
            finish(job, nil, "could not create \(partialFolder.path): \(error.localizedDescription)")
            return
        }
        let base = job.source.deletingPathExtension().lastPathComponent
        let partial = partialFolder.appendingPathComponent("\(UUID().uuidString)-\(base).\(job.preset.fileExtension)")

        guard let executable = Bundle.main.executableURL else {
            finish(job, nil, "the helper executable was not found")
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--optimize", job.source.path, partial.path, job.preset.rawValue]
        process.qualityOfService = .background
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        var errorText = ""
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("progress") }) else { return }
            let parts = line.split(separator: " ")
            guard parts.count == 3, let done = Double(parts[1]), let total = Double(parts[2]), total > 0 else { return }
            Self.onMain { self?.report(job, fraction: done / total) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            errorText += String(decoding: handle.availableData, as: UTF8.self)
        }
        process.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            Self.onMain { self?.childEnded(job, partial: partial, status: status, reason: reason, errors: errorText) }
        }
        do {
            try process.run()
            current = (job, process, partial)
            report(job, fraction: 0)
        } catch {
            finish(job, nil, "could not start the helper: \(error.localizedDescription)")
        }
    }

    private func report(_ job: Job, fraction: Double) {
        onStatus?("Optimizing \(finishedCount + 1) / \(totalCount) — \(job.source.lastPathComponent) "
            + "(\(Int(fraction * 100))%)")
    }

    private func childEnded(_ job: Job, partial: URL, status: Int32,
                            reason: Process.TerminationReason, errors: String) {
        current = nil
        let files = FileManager.default
        guard status == 0, reason == .exit, files.fileExists(atPath: partial.path) else {
            try? files.removeItem(at: partial)
            let why = reason == .uncaughtSignal ? "stopped" : (errors.isEmpty ? "exit \(status)" : errors)
            finish(job, nil, why.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        // Complete: into place under a free name, then (and only then) linked.
        let base = job.source.deletingPathExtension().lastPathComponent
        let final = FileTransfer.freeName(for: "\(base).\(job.preset.fileExtension)", in: location())
        do {
            try files.moveItem(at: partial, to: final)
            finish(job, final, nil)
        } catch {
            try? files.removeItem(at: partial)
            finish(job, nil, "could not move the finished file: \(error.localizedDescription)")
        }
    }

    private func finish(_ job: Job, _ result: URL?, _ reason: String?) {
        finishedCount += 1
        if let result {
            Log.info(.app, "optimize: \(job.source.lastPathComponent) → \(result.lastPathComponent)")
        } else {
            Log.warn(.app, "optimize: \(job.source.lastPathComponent) failed — \(reason ?? "?")")
        }
        onFinished?(job, result, reason)
        startNext()
    }

    /// Through the main run loop (the self-QA's nested RunLoop.run does not drain the
    /// main queue).
    private static func onMain(_ block: @escaping () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(main)
    }
}
