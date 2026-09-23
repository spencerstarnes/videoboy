//
//  ClockSourceMenu.swift — the menu behind the toolbar's CLOCK field.
//
//  Purpose : Choose where the musical clock comes from: its own internal transport,
//            or beat detection listening to System Audio, the audio input, or one
//            running app (Apple Music, Spotify, a browser...).
//  Inputs  : the current clock source; the apps that have audio open right now.
//  Outputs : the chosen `ClockSource`, via the handler.
//  Connects: ShellController presents it from TransportToolbarView's CLOCK field and
//            hands the choice to `Engine.setClockSource`. `AudioAppCatalog` lists
//            the apps.
//  Extend  : a new source is a new item here and a new `AudioCaptureSource` case.
//
//  Why a menu, when the other fields in the cluster cycle on click: CLOCK used to
//  cycle too, through four choices of which two were unbuilt. Clicking past Audio
//  hit "MIDI Clock", which refused, so the field stuck on Audio with no way back.
//  And the list is now open-ended — it names whatever apps are running — which is
//  the case TransportDisplayView's own header says earns a menu. Every choice is one
//  click from any state, including the way back to Internal.
//

import AppKit
import VideoboyCore

enum ClockSourceMenu {

    /// Pops the menu up under `view`.
    static func present(
        current: ClockSource, from view: NSView, handler: @escaping (ClockSource) -> Void
    ) {
        let menu = makeMenu(current: current, handler: handler)
        // Anchored just below the field so the menu does not cover the tempo.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 2), in: view)
    }

    /// Builds the menu without showing it — `present` shows it; the self-QA reads it.
    static func makeMenu(current: ClockSource, handler: @escaping (ClockSource) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(item("Internal Clock", checked: current == .internalTransport) {
            handler(.internalTransport)
        })
        menu.addItem(.separator())

        menu.addItem(header("Detect the beat from"))
        let tapsSupported = AudioCaptureSource.systemAudio.isSupported
        let system = item("System Audio — everything this Mac plays",
                          checked: current == .audio(.systemAudio), indent: 1) {
            handler(.audio(.systemAudio))
        }
        system.isEnabled = tapsSupported
        menu.addItem(system)
        menu.addItem(item("Audio Input — microphone or line in",
                          checked: current == .audio(.inputDevice), indent: 1) {
            handler(.audio(.inputDevice))
        })

        menu.addItem(.separator())
        menu.addItem(header("Detect the beat from one app"))
        if !tapsSupported {
            let note = header("Needs macOS 14.2 or later")
            note.indentationLevel = 1
            menu.addItem(note)
        } else {
            let apps = AudioAppCatalog.apps()
            if apps.isEmpty {
                let note = header("No apps have audio open")
                note.indentationLevel = 1
                menu.addItem(note)
            }
            for app in apps {
                let source = AudioCaptureSource.application(bundleID: app.bundleID, name: app.name)
                // "Playing" is worth saying: it is how you tell which of three open
                // browsers the music is actually in.
                let title = app.isPlaying ? "\(app.name)  ♪ playing" : app.name
                let entry = item(title, checked: isCurrent(current, bundleID: app.bundleID), indent: 1) {
                    handler(.audio(source))
                }
                if let icon = NSRunningApplication.runningApplications(
                    withBundleIdentifier: app.bundleID).first?.icon {
                    icon.size = NSSize(width: 16, height: 16)
                    entry.image = icon
                }
                menu.addItem(entry)
            }
        }

        return menu
    }

    /// Whether the current source is this app, matched by bundle ID — the name in
    /// the current source may be from an earlier launch.
    private static func isCurrent(_ current: ClockSource, bundleID: String) -> Bool {
        if case .audio(.application(let currentID, _)) = current { return currentID == bundleID }
        return false
    }

    private static func item(
        _ title: String, checked: Bool, indent: Int = 0, action: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.fire), keyEquivalent: "")
        let target = ClosureMenuTarget(action: action)
        item.target = target
        // The item owns its target, or ARC releases it before the click arrives.
        item.representedObject = target
        item.state = checked ? .on : .off
        item.indentationLevel = indent
        return item
    }

    private static func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
