//
//  ImportJob.swift — adding files and folders to the library without stopping the show.
//
//  Purpose : A large drop used to walk folders, decode posters and measure every clip
//            on the main thread; the window froze and looked crashed (audit 09-26
//            R1–R3). The job does all of that on a background queue, adds clips to
//            the library in batches as they are found, measures them (length, frame
//            count — stored in the catalog), and reports progress for the status bar.
//  Inputs  : dropped URLs, a target bin, the library.
//  Outputs : clips in the library and catalog; `ImportProgress` on the main thread.
//  Connects: ImportScan and ClipProbe (Core), LibraryModel, ShellController (which
//            owns jobs and shows their progress in StatusBarView).
//  Extend  : a new stage is a case on `ImportProgress.Stage` and a step in `run`.
//
//  THREADING. `run` executes on `ImportJob.queue` (serial, so a second drop waits for
//  the first). Everything that touches the library is handed to the main run loop.
//

import AppKit
import VideoboyCore

final class ImportJob {

    /// One queue for every import: two drops at once run one after the other.
    private static let queue = DispatchQueue(label: "videoboy.import", qos: .utility)

    /// Progress reaches the main thread at most this often (plus on every stage change),
    /// so the flashing file name reads as motion rather than a flicker.
    static let progressInterval: TimeInterval = 1.0 / 8.0
    /// Measured facts are handed to the library this often: at most four rebuilds a
    /// second, however large the import.
    static let batchInterval: TimeInterval = 0.25
    /// Found clips are handed over more often while scanning, so a drop of many folders
    /// shows its bins a few at a time. All 25 folders of a 1,000-clip drop arriving in
    /// one batch built ~75 folder tiles in one layout pass: a ~46 ms stall (0.4.7). A
    /// rebuild costs ~1.3 ms, so the extra batches are cheap.
    static let scanBatchInterval: TimeInterval = 0.08

    let urls: [URL]
    let bin: String?

    /// Called on the main thread with each progress update.
    var onProgress: ((ImportProgress) -> Void)?
    /// Called on the main thread once, at the end (finished or cancelled).
    var onFinished: ((ImportProgress) -> Void)?
    /// Whether a show is running. While it is, the job paces itself between files so
    /// it never competes with playback for the machine.
    var isLive: () -> Bool = { false }

    private let lock = NSLock()
    private var cancelled = false

    init(urls: [URL], intoBin bin: String?) {
        self.urls = urls
        self.bin = bin
    }

    /// Stops between files. What has been added stays added.
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Queues the job. `library` is only touched on the main thread.
    func start(into library: LibraryModel) {
        Self.queue.async { [self] in run(library: library) }
    }

    // MARK: - The work (on `queue`)

    private func run(library: LibraryModel) {
        let started = Date()
        var progress = ImportProgress()
        var lastPublished = Date.distantPast
        func publish(force: Bool = false) {
            progress.elapsed = Date().timeIntervalSince(started)
            guard force || Date().timeIntervalSince(lastPublished) >= Self.progressInterval else { return }
            lastPublished = Date()
            let snapshot = progress
            onMain("import.progress") { [weak self] in self?.onProgress?(snapshot) }
        }

        // SCAN, adding clips to the library in batches as they are found.
        var pending: [LibraryItem] = []
        var lastBatch = Date()
        var added = 0
        func handOver() {
            guard !pending.isEmpty else { return }
            let batch = pending
            pending = []
            lastBatch = Date()
            onMainSync { added += library.add(batch, measuresDurations: false).count }
        }
        publish(force: true)
        let scan = ImportScan.scan(urls, intoBin: bin, isCancelled: { isCancelled }) { candidate in
            progress.count(candidate)
            pending.append(Self.item(for: candidate))
            if Date().timeIntervalSince(lastBatch) >= Self.scanBatchInterval { handOver() }
            publish()
        }
        handOver()
        progress.includesFolder = scan.includesFolder
        progress.rejected = scan.rejected
        progress.added = added

        // READ each clip: its length and frame count, for the library and the catalog.
        progress.stage = .reading
        progress.current = nil
        publish(force: true)
        var facts: [String: ClipFacts] = [:]
        var lastFacts = Date()
        func handOverFacts() {
            guard !facts.isEmpty else { return }
            let batch = facts
            facts = [:]
            lastFacts = Date()
            onMain("import.facts") { library.applyFacts(byPath: batch) }
        }
        for candidate in scan.candidates {
            if isCancelled { break }
            progress.current = candidate.bin.map { "\($0)/\(candidate.url.lastPathComponent)" }
                ?? candidate.url.lastPathComponent
            progress.activeFolder = candidate.bin
            if let measured = ClipProbe.facts(of: candidate.url) {
                facts[candidate.url.standardizedFileURL.path] = measured
            } else {
                progress.unreadable.append("\(candidate.url.lastPathComponent) — could not be read")
            }
            progress.read += 1
            if Date().timeIntervalSince(lastFacts) >= Self.batchInterval { handOverFacts() }
            publish()
            if isLive() { Thread.sleep(forTimeInterval: 0.002) }
        }
        handOverFacts()

        progress.stage = isCancelled ? .cancelled : .finished
        progress.current = nil
        publish(force: true)
        let final = progress
        onMain { [weak self] in self?.onFinished?(final) }
        Log.info(.app, "import \(final.stage == .cancelled ? "cancelled" : "finished"): "
            + "\(final.found) found, \(final.added) added, \(final.unreadable.count) unreadable, "
            + String(format: "%.1f s", final.elapsed))
    }

    /// A library entry for a found clip, with its bookmark made here, off the main thread.
    private static func item(for candidate: ImportCandidate) -> LibraryItem {
        var item: LibraryItem
        if candidate.isSequence {
            item = LibraryItem(name: candidate.url.lastPathComponent, badge: "SEQ",
                               isAvailable: true, url: candidate.url)
        } else {
            item = ShellController.libraryItem(for: candidate.url)
        }
        item.bin = candidate.bin
        item.bookmark = try? candidate.url.bookmarkData()
        item.standardPath = candidate.url.standardizedFileURL.path
        return item
    }

    // MARK: - Reaching the main thread

    /// Through the run loop rather than the main queue: the self-QA drives the app from
    /// a nested `RunLoop.run`, which never drains a main-queue block.
    private func onMain(_ label: String = "import", _ block: @escaping () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
            autoreleasepool { MainThreadCosts.measure(label, block) }
        }
        CFRunLoopWakeUp(main)
    }

    /// Waits for the main thread to take a batch, so the scan cannot run unboundedly
    /// ahead of what the library has accepted.
    private func onMainSync(_ block: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        onMain("import.add") { block(); done.signal() }
        done.wait()
    }
}

/// Time spent in labelled main-thread work, while a check is watching. Nil in normal
/// use, so recording costs nothing.
enum MainThreadCosts {
    static var byLabel: [String: [Double]]?

    static func measure(_ label: String, _ block: () -> Void) {
        guard byLabel != nil else { return block() }
        let start = CACurrentMediaTime()
        block()
        byLabel?[label, default: []].append((CACurrentMediaTime() - start) * 1000)
    }
}
