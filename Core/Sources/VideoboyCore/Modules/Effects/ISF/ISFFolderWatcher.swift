//
//  ISFFolderWatcher.swift — notices when ISF files change on disk (ISF-PLAN M6).
//
//  Purpose : "Drop an ISF file in, it appears" (SPEC 8), and "save the shader, see
//            the change". Watches the ISF folders with FSEvents and, once the burst
//            of events from a save or a copy has settled, rescans them OFF the main
//            thread and hands the result back on main.
//  Inputs  : folder URLs.
//  Outputs : `onChange([ISFLibraryEntry])` on the main thread, debounced.
//  Connects: Engine.applyLibrary (refreshes the catalogue and live nodes), the
//            Preferences Shaders pane (its imports land in a watched folder).
//  Extend  : a folder created after launch (a shared ISF folder that did not exist)
//            is picked up on the next launch; watching its parent would fix that.
//
//  Nothing here touches the render path: FSEvents calls back on a private queue,
//  the scan (file reads and JSON parses) runs there, and only the finished list is
//  handed to main.
//

import Foundation
import CoreServices

/// Watches ISF folders and reports a fresh scan when anything in them changes.
public final class ISFFolderWatcher {

    private let folders: [(URL, ISFLibraryEntry.Folder)]
    private let onChange: ([ISFLibraryEntry]) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "videoboy.isf.watch", qos: .utility)
    private var pending: DispatchWorkItem?
    /// How long a burst of events must be quiet before rescanning. A save writes a
    /// temporary file and renames it; a copy of a folder is dozens of events.
    private let settle: TimeInterval

    /// Starts watching the folders that exist. The callback runs on main.
    public init(folders: [(URL, ISFLibraryEntry.Folder)] = ISFLibrary.standardFolders,
                settle: TimeInterval = 0.3,
                onChange: @escaping ([ISFLibraryEntry]) -> Void) {
        self.folders = folders
        self.settle = settle
        self.onChange = onChange
        start()
    }

    deinit { stop() }

    /// Stops watching. Safe to call twice.
    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func start() {
        let paths = folders.map(\.0.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else {
            Log.info(.isf, "no ISF folders exist yet; nothing to watch")
            return
        }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ISFFolderWatcher>.fromOpaque(info).takeUnretainedValue().eventsArrived()
        }
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else {
            Log.error(.isf, "could not watch the ISF folders; changes need a relaunch")
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
        Log.info(.isf, "watching \(paths.count) ISF folder(s) for changes")
    }

    /// FSEvents queue: restart the settle timer; when it fires, rescan and report.
    private func eventsArrived() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let entries = ISFLibrary.scan(self.folders)
            DispatchQueue.main.async { self.onChange(entries) }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + settle, execute: work)
    }
}
