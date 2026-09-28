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
    let root: URL?
    /// Add, Move or Copy (Import mode). Move and Copy run first, on this job's queue.
    let method: ImportMethod
    /// Where Move and Copy put the files.
    let destination: URL?
    /// Files the transfer could not move or copy, for the caller's notice.
    private(set) var transferFailures: [String] = []
    /// Where the files ended up (after Move/Copy) — what Optimize converts.
    private(set) var resultingURLs: [URL] = []
    /// Copy + Optimize: convert the copies once they are in the library.
    var optimizePreset: OptimizePreset?

    /// Called on the main thread with each progress update.
    var onProgress: ((ImportProgress) -> Void)?
    /// Called on the main thread once, at the end (finished or cancelled).
    var onFinished: ((ImportProgress) -> Void)?
    /// Whether a show is running. While it is, the job paces itself between files so
    /// it never competes with playback for the machine.
    var isLive: () -> Bool = { false }

    private let lock = NSLock()
    private var cancelled = false

    /// - Parameter root: the folder the URLs were picked from (Import mode with
    ///   "Include subfolders"). Its folder tree is kept: made again under the
    ///   destination by Move/Copy, and as bins inside `bin`. Nil for a drop, whose
    ///   folders are walked (and kept) by ImportScan itself.
    init(urls: [URL], intoBin bin: String?, method: ImportMethod = .add, destination: URL? = nil,
         root: URL? = nil) {
        self.urls = urls
        self.bin = bin
        self.root = root
        self.method = method
        self.destination = destination
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

        // TRANSFER (Move/Copy), before anything is cataloged: the library records the
        // files where they END UP.
        var sources = urls
        if method.usesDestination {
            progress.stage = .transferring
            progress.transferLabel = method == .move ? "MOVING" : "COPYING"
            progress.found = urls.count
            publish(force: true)
            let moved = FileTransfer.transfer(
                urls, method: method, to: destination, keepingFoldersBelow: root, isCancelled: { isCancelled }
            ) { name in
                progress.current = name
                progress.read += 1
                publish()
            }
            sources = moved.urls
            transferFailures = moved.failures
            progress.unreadable += moved.failures
            progress.found = 0
            progress.read = 0
            progress.stage = .scanning
        }

        resultingURLs = sources

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
        // After a Move/Copy the files sit under the destination in the same folders
        // they had under the root, so the tree is read from wherever they now are.
        let treeRoot = method.usesDestination ? (root == nil ? nil : destination) : root
        let scan = ImportScan.scan(sources, intoBin: bin, keepingFoldersBelow: treeRoot,
                                   isCancelled: { isCancelled }) { candidate in
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
