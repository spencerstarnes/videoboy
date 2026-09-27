//
//  ImportSources.swift — what Import mode's sidebar lists (proposal §5).
//
//  Purpose : Devices (mounted volumes, removable ones ejectable), Network shares,
//            iCloud Drive, Favorites (our own list — macOS has no public API for
//            Finder's sidebar) and Locations (Movies, Desktop, Downloads).
//  Inputs  : the file system, the preference store's favorites.
//  Outputs : sections of `ImportSource`.
//  Connects: ImportModeView.
//  Extend  : a new section is a case in `Section` and a few lines in `discover`.
//
//  THREADING: `discover` asks the file system about volumes, which can stall on a slow
//  network share — call it off the main thread.
//

import Foundation

/// One place clips can be imported from.
struct ImportSource: Equatable {
    enum Section: String, CaseIterable {
        case devices = "Devices"
        case network = "Network"
        case iCloud = "iCloud Drive"
        case favorites = "Favorites"
        case locations = "Locations"
    }

    let title: String
    let url: URL
    let section: Section
    let symbolName: String
    /// Lightroom's rule: never Move from a card, a share, iCloud or a read-only disk.
    let allowsMove: Bool
    let isEjectable: Bool
}

enum ImportSources {

    /// Every source, grouped, in sidebar order. Empty sections are left out.
    static func discover(favorites: [String]) -> [(ImportSource.Section, [ImportSource])] {
        var bySection: [ImportSource.Section: [ImportSource]] = [:]
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                      .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsBrowsableKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable ?? true else { continue }
            let local = values.volumeIsLocal ?? true
            let removable = (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false)
            let readOnly = values.volumeIsReadOnly ?? false
            let source = ImportSource(
                title: values.volumeName ?? volume.lastPathComponent, url: volume,
                section: local ? .devices : .network,
                symbolName: local ? (removable ? "sdcard" : "internaldrive") : "network",
                allowsMove: local && !removable && !readOnly,
                isEjectable: removable)
            bySection[source.section, default: []].append(source)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: iCloud.path) {
            bySection[.iCloud] = [ImportSource(title: "iCloud Drive", url: iCloud, section: .iCloud,
                                               symbolName: "icloud", allowsMove: false, isEjectable: false)]
        }
        bySection[.favorites] = favorites.map { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return ImportSource(title: url.lastPathComponent, url: url, section: .favorites,
                                symbolName: "star", allowsMove: allowsMove(url), isEjectable: false)
        }
        bySection[.locations] = [("Movies", "film"), ("Desktop", "menubar.dock.rectangle"),
                                 ("Downloads", "arrow.down.circle")].map { name, symbol in
            let url = home.appendingPathComponent(name, isDirectory: true)
            return ImportSource(title: name, url: url, section: .locations, symbolName: symbol,
                                allowsMove: true, isEjectable: false)
        }
        return ImportSource.Section.allCases.compactMap { section in
            guard let sources = bySection[section], !sources.isEmpty else { return nil }
            return (section, sources)
        }
    }

    /// Whether files under `url` may be moved: local, fixed, writable, not iCloud.
    static func allowsMove(_ url: URL) -> Bool {
        if url.path.contains("/Library/Mobile Documents/") { return false }
        let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsRemovableKey,
                                                       .volumeIsReadOnlyKey, .isWritableKey])
        return (values?.volumeIsLocal ?? true) && !(values?.volumeIsRemovable ?? false)
            && !(values?.volumeIsReadOnly ?? false) && (values?.isWritable ?? true)
    }
}
