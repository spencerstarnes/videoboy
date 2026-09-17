//
//  DiscImage.swift — getting at the contents of a .iso.
//
//  Purpose : The software lives on a disc image. Before anything can be copied off it,
//            macOS has to mount it. This does that, and finds it again when it is
//            already mounted.
//  Inputs  : a path to a disc image.
//  Outputs : the mounted volume's URL.
//  Connects: AmigaSystemInstaller (which copies from it), the EMU panel's SET UP.
//  Extend  : other image formats need no change — hdiutil handles .iso, .cue, .dmg and
//            .toast alike.
//
//  Mounted READ-ONLY and NOBROWSE. Read-only because nothing here should ever write to
//  someone's media, and nobrowse because a volume appearing on the desktop every time
//  the app starts is the app being rude.
//

import Foundation

/// A disc image, and where it is mounted.
public struct DiscImage: Sendable {

    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    /// Where it is mounted, or nil when it is not.
    ///
    /// Found by looking for a volume whose contents match, rather than by remembering
    /// what we mounted: the disc may already have been mounted by hand, and mounting a
    /// second copy of it would be both slow and confusing.
    public func existingMountPoint(fileManager: FileManager = .default) -> URL? {
        let volumes = (try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: nil)) ?? []
        return volumes.first { AmigaSystemInstaller.looksBootable($0, fileManager: fileManager) }
    }

    /// Mounts it, or returns where it already is.
    public func mount(fileManager: FileManager = .default) throws -> URL {
        if let existing = existingMountPoint(fileManager: fileManager) {
            Log.info(.titler, "disc already mounted at \(existing.path)")
            return existing
        }
        guard fileManager.fileExists(atPath: path.path) else {
            throw MountError.noSuchImage(path.lastPathComponent)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-readonly", "-nobrowse", "-plist", path.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw MountError.couldNotMount(path.lastPathComponent)
        }
        guard let mountPoint = DiscImage.mountPoint(inPropertyList: data) else {
            throw MountError.mountedButNotFound(path.lastPathComponent)
        }
        Log.info(.titler, "mounted \(path.lastPathComponent) at \(mountPoint.path)")
        return mountPoint
    }

    /// Pulls the mount point out of hdiutil's plist.
    ///
    /// Parsed as a property list rather than scraped from the text output, because
    /// hdiutil's plain output is tab-separated and a volume name containing a tab — or
    /// simply a long name — makes column-splitting wrong in a way that only shows up on
    /// someone else's disc.
    static func mountPoint(inPropertyList data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            return nil
        }
        // The last entity with a mount point: an image can have several partitions and
        // the filesystem is not the first of them.
        let points = entities.compactMap { $0["mount-point"] as? String }
        guard let last = points.last(where: { !$0.isEmpty }) else { return nil }
        return URL(fileURLWithPath: last)
    }

    public enum MountError: LocalizedError {
        case noSuchImage(String)
        case couldNotMount(String)
        case mountedButNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .noSuchImage(let name):
                return "\(name) is not there any more — it may have been moved."
            case .couldNotMount(let name):
                return "macOS refused to mount \(name). Opening it in Finder once will "
                    + "usually say why."
            case .mountedButNotFound(let name):
                return "\(name) mounted, but nothing about it looks like an Amiga disc."
            }
        }
    }
}
