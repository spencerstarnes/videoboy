//
//  ShadersSelfQA.swift — the Preferences Shaders pane, driven for real.
//
//  Purpose : Proves the ISF import pane does what it promises, in the real
//            Preferences window: + / − are reachable by a click, an import COPIES
//            (so deleting the originals loses nothing), a file that is not ISF is
//            refused with a reason, an imported module is checked for compiling,
//            built-ins cannot be removed, − removes an import, and a module in the
//            shared folder can be copied in.
//  Inputs  : fixture shaders written to a temporary folder; the real built-ins.
//  Outputs : selfqa/out/isf/shaders-pane/{result.txt, pane.png}.
//  Connects: PreferencesWindowController (`makeShaderList` is pointed at temporary
//            folders, so the operator's own ISF library is never touched), and
//            ISFModuleListView, ISFImporter.
//  Extend  : a new pane behaviour is one more step and one more assertion.
//
//  Not covered: the + button's file panel (modal; it only chooses URLs, which then
//  take exactly the path tested here) and a drop from the Finder (cannot be
//  synthesised; it also hands its URLs to the same import call).
//

import AppKit
import VideoboyCore

enum ShadersSelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "isf/shaders-pane")
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("videoboy-shaders-qa-\(UUID().uuidString)", isDirectory: true)
        let user = root.appendingPathComponent("Videoboy ISF", isDirectory: true)
        let shared = root.appendingPathComponent("Shared ISF", isDirectory: true)
        let outside = root.appendingPathComponent("Downloads", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        do {
            for folder in [user, shared, outside] {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try shader("shared one").write(to: shared.appendingPathComponent("Shared Glow.fs"), atomically: true, encoding: .utf8)
            try shader("glow").write(to: outside.appendingPathComponent("Glow.fs"), atomically: true, encoding: .utf8)
            try "void main() { gl_FragColor = vec4(1.0); }"
                .write(to: outside.appendingPathComponent("Not ISF.fs"), atomically: true, encoding: .utf8)
            let pack = outside.appendingPathComponent("Pack", isDirectory: true)
            try fileManager.createDirectory(at: pack, withIntermediateDirectories: true)
            try shader("one").write(to: pack.appendingPathComponent("Pack One.fs"), atomically: true, encoding: .utf8)
            try shader("two").write(to: pack.appendingPathComponent("Pack Two.fs"), atomically: true, encoding: .utf8)
        } catch {
            return check.finish(blockedReason: "could not write fixtures: \(error)")
        }

        var trashed: [String] = []
        let preferences = PreferencesWindowController(
            store: PreferenceStore(fileURL: root.appendingPathComponent("prefs.json")), engine: Engine())
        preferences.makeShaderList = {
            ISFModuleListView(
                folders: [(ISFLibrary.builtinFolder, .builtin), (user, .user), (shared, .shared)],
                importFolder: user,
                trash: { url in
                    trashed.append(url.lastPathComponent)
                    try FileManager.default.removeItem(at: url)
                })
        }
        guard let window = preferences.window, let content = window.contentView else {
            return check.finish(blockedReason: "no Preferences window")
        }
        preferences.showWindow(nil)
        let sizeBefore = window.frame.size

        // The tab: appended LAST, so no existing tab moved.
        let tabs = buttons(in: content).filter { $0.identifier.flatMap { PreferencesWindowController.Pane(rawValue: $0.rawValue) } != nil }
            .sorted { $0.convert(NSPoint.zero, to: nil).y > $1.convert(NSPoint.zero, to: nil).y }
        check.record(AssertionResult(
            name: "the Shaders tab is last in the sidebar, so no tab moved",
            passed: tabs.last?.identifier?.rawValue == "shaders",
            detail: tabs.compactMap { $0.identifier?.rawValue }.joined(separator: ", ")))
        if let tab = tabs.last { click(tab, in: window) }
        pump(0.2)
        guard let list = preferences.shaderList else {
            window.orderOut(nil)
            return check.finish(blockedReason: "clicking the Shaders tab built no list")
        }
        waitFor { !list.entries.isEmpty }
        list.select(name: "Transform")   // a built-in's detail, before any import
        pump(0.1)
        content.layoutSubtreeIfNeeded()

        let names = Set(list.entries.map(\.name))
        check.record(AssertionResult(
            name: "the list shows the built-ins and the shared folder",
            passed: names.isSuperset(of: ["Colour", "Echo", "Transform", "Shared Glow"]),
            detail: list.entries.map { "\($0.name) (\(ISFModuleListView.badge($0.folder)))" }.joined(separator: ", ")))

        // + and − are where a click lands.
        for (label, button) in [("+", list.addButton), ("−", list.removeButton)] {
            let hit = hitTarget(button, in: window)
            check.record(AssertionResult(
                name: "a click on \(label) lands on the button",
                passed: hit === button, detail: hit.map { String(describing: type(of: $0)) } ?? "nothing"))
        }

        // A built-in cannot be removed.
        list.select(name: "Colour")
        pump(0.1)
        check.record(AssertionResult(
            name: "− is disabled on a built-in module",
            passed: !list.removeButton.isEnabled, detail: list.removeButton.toolTip ?? ""))

        // Import: two files and a folder, as the + panel or a drop would hand them over.
        var report: ISFImportReport?
        list.importModules([outside.appendingPathComponent("Glow.fs"),
                            outside.appendingPathComponent("Not ISF.fs"),
                            outside.appendingPathComponent("Pack")]) { report = $0 }
        waitFor { report != nil }
        check.note("import: \(report?.summary ?? "no report")")
        let copied = ISFLibrary.fragmentFiles(in: user).map { $0.lastPathComponent }.sorted()
        check.record(AssertionResult(
            name: "import copies every ISF file into Videoboy's folder",
            passed: copied == ["Glow.fs", "Pack One.fs", "Pack Two.fs"],
            detail: copied.joined(separator: ", ")))
        let sheet = window.attachedSheet
        check.record(AssertionResult(
            name: "a file that is not ISF is refused, and the reason is shown",
            passed: sheet != nil && report?.items.contains { if case .skipped = $0.outcome { true } else { false } } == true,
            detail: sheet == nil ? "no alert" : "alert shown"))
        if let sheet { window.endSheet(sheet) }

        // Deleting the originals loses nothing: the library still has them.
        try? fileManager.removeItem(at: outside)
        var rescanned = false
        list.rescan { rescanned = true }
        waitFor { rescanned }
        let imported = list.entries.filter { $0.folder == .user }.map(\.name).sorted()
        check.record(AssertionResult(
            name: "with the originals deleted, the imported modules are all still there",
            passed: imported == ["Glow", "Pack One", "Pack Two"],
            detail: imported.joined(separator: ", ")))

        // An import is checked for compiling.
        list.select(name: "Glow")
        waitFor(seconds: 10) { list.statusTextForChecks.hasPrefix("Ready") || list.statusTextForChecks.hasPrefix("⚠") }
        check.record(AssertionResult(
            name: "an imported module is compiled and reported ready",
            passed: list.statusTextForChecks.hasPrefix("Ready"), detail: list.statusTextForChecks))

        content.layoutSubtreeIfNeeded()
        check.record(AssertionResult(
            name: "the pane leaves the window its size, even showing a long path",
            passed: window.frame.size == sizeBefore,
            detail: "before \(Int(sizeBefore.width))x\(Int(sizeBefore.height)), now \(Int(window.frame.width))x\(Int(window.frame.height))"))
        if let image = UISelfQA.render(view: content) {
            _ = try? check.writeImage(image, named: "pane.png")
        }

        // − on an import, with a real click.
        check.record(AssertionResult(
            name: "− is enabled on an imported module",
            passed: list.removeButton.isEnabled, detail: ""))
        click(list.removeButton, in: window)
        waitFor { !list.entries.contains { $0.name == "Glow" } }
        check.record(AssertionResult(
            name: "− removes the import from the list and the folder",
            passed: trashed == ["Glow.fs"] && !list.entries.contains { $0.name == "Glow" }
                && !fileManager.fileExists(atPath: user.appendingPathComponent("Glow.fs").path),
            detail: "disposed of: \(trashed)"))

        // A shared module can be kept.
        list.select(name: "Shared Glow")
        pump(0.1)
        let copyButton = buttons(in: list).first { $0.title == "Copy into Videoboy" }
        let offered = copyButton.map { !$0.isHidden } ?? false
        if let copyButton, offered {
            click(copyButton, in: window)
            waitFor { list.entries.first { $0.name == "Shared Glow" }?.folder == .user }
        }
        check.record(AssertionResult(
            name: "a click on Copy into Videoboy keeps a shared module under its own name",
            passed: fileManager.fileExists(atPath: user.appendingPathComponent("Shared Glow.fs").path)
                && list.entries.first { $0.name == "Shared Glow" }?.folder == .user,
            detail: offered ? list.statusLineForChecks : "the Copy button was not offered"))

        // Real-world files, when this machine has them: the owner's VDMX shaders,
        // imported into the TEMPORARY library (the originals are only read). Recorded
        // as notes, not assertions — third-party GLSL is allowed to fail, and what
        // matters here is that the pane says which and why.
        let vdmx = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/VDMX Media/ISF", isDirectory: true)
        if fileManager.fileExists(atPath: vdmx.path) {
            var vdmxReport: ISFImportReport?
            list.importModules([vdmx]) { vdmxReport = $0 }
            waitFor(seconds: 10) { vdmxReport != nil }
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            check.note("VDMX folder: \(vdmxReport?.summary ?? "no report")")
            var ready = 0
            let names = vdmxReport?.importedNames ?? []
            for name in names {
                list.select(name: name)
                waitFor(seconds: 15) {
                    list.statusTextForChecks.hasPrefix("Ready") || list.statusTextForChecks.hasPrefix("⚠")
                }
                if list.statusTextForChecks.hasPrefix("Ready") { ready += 1 }
                check.note("  \(name): \(list.statusTextForChecks)")
            }
            check.note("VDMX shaders ready: \(ready) of \(names.count)")
        }

        window.orderOut(nil)
        return check.finish()
    }

    // MARK: - Helpers

    private static func shader(_ description: String) -> String {
        """
        /*{
            "DESCRIPTION": "\(description)",
            "CATEGORIES": ["Test"],
            "INPUTS": [
                { "NAME": "inputImage", "TYPE": "image" },
                { "NAME": "amount", "TYPE": "float", "MIN": 0.0, "MAX": 1.0, "DEFAULT": 0.5 }
            ]
        }*/
        void main() {
            vec4 colour = IMG_THIS_PIXEL(inputImage);
            gl_FragColor = vec4(mix(colour.rgb, 1.0 - colour.rgb, amount), colour.a);
        }
        """
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func waitFor(seconds: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { pump(0.05) }
    }

    private static func hitTarget(_ view: NSView, in window: NSWindow) -> NSView? {
        guard let content = window.contentView else { return nil }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return content.hitTest(content.convert(point, from: nil))
    }

    /// A real mouse down/up sent through the window, as a click arrives.
    private static func click(_ view: NSView, in window: NSWindow) {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        // Up queued first: buttons track the click in their own loop and take it from there.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton { found.append(button) }
        for subview in view.subviews { found += buttons(in: subview) }
        return found
    }
}
