//
//  AppDelegate.swift — application lifecycle and the menu bar.
//
//  Purpose : Creates the main window and the menu bar, and logs the environment once
//            at startup so any later bug report has the context attached.
//  Inputs  : none beyond launch.
//  Outputs : a visible main window.
//  Connects: MainWindowController (the canonical shell, SPEC 14).
//  Extend  : menu items go in `buildMenuBar`. Window construction belongs in
//            MainWindowController, not here.
//

import AppKit
import VideoboyCore

/// Owns the application's windows and menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindowController: MainWindowController?
    private var launchWindowController: LaunchWindowController?
    private var preferencesController: PreferencesWindowController?
    /// The View menu (mode items), when the mode bar is on.
    private var viewMenu: NSMenu?

    /// Settings that outlive a patch. Loaded once, here, and handed to whoever needs
    /// them — one store, so a change made in the window is seen everywhere at once.
    let preferences = PreferenceStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The launch screen goes up first and reports each subsystem as it comes up.
        // Startup is not instant — Metal compiles its shaders, the DV codec opens,
        // MIDI enumerates — and showing what is happening turns that pause into
        // information rather than a hang.
        let launch = LaunchWindowController()
        launch.showWindow(nil)
        launchWindowController = launch

        logEnvironment()

        if MetalContext.shared != nil {
            launch.complete(.metal)
            launch.complete(.shaders)
        } else {
            launch.skip(.metal, reason: "unavailable")
            launch.skip(.shaders, reason: "no device")
        }

        // The codec is checked rather than assumed: a missing DV decoder is the kind
        // of thing that should be visible at launch, not when a file fails to open.
        if (try? DVDecoder()) != nil {
            launch.complete(.codecs)
        } else {
            launch.skip(.codecs, reason: "DV decoder missing")
        }

        buildMenuBar()

        let controller = MainWindowController(preferences: preferences)
        launch.complete(.graph)
        // Its own stage: opening the catalog (lock, migration, the weekly backup, then
        // loading every clip) grows with the library, and a pause here must read as
        // "Library catalog", not as a hang between two lit dots (BUGHUNT S1).
        if openCatalog(into: controller) {
            launch.complete(.library)
        } else {
            launch.skip(.library, reason: "not opened")
        }
        launch.complete(.clock)

        if controller.engine.midi.connectedSourceNames.isEmpty {
            launch.skip(.midi, reason: "no devices")
        } else {
            launch.complete(.midi)
        }

        let displays = DisplayRouter.availableDisplays()
        if displays.isEmpty {
            launch.skip(.displays, reason: "none found")
        } else {
            launch.complete(.displays)
        }

        controller.showWindow(nil)
        mainWindowController = controller
        startAutosave()
        controller.modeController?.onModeChanged = { [weak self] mode in self?.markMode(mode) }
        launch.complete(.interface)

        NSApp.activate(ignoringOtherApps: true)
        Log.info(.app, "main window shown")

        // Leave it up just long enough to be read, then fade. Not padding: by this
        // point the app is fully live behind it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.launchWindowController?.dismiss()
            self?.launchWindowController = nil
            // With the mode bar on, first launch gets the setup assistant (a sheet)
            // in place of the save-location alert it replaces (proposal §8).
            if let self, let window = self.mainWindowController, window.modeController != nil,
               !self.preferences.preferences.setupCompleted {
                // The output offer is a modal alert; it waits for the assistant's sheet.
                window.runSetupAssistant { [weak self] in self?.offerDefaultOutputIfNothingIsRouted() }
                return
            }
            if self?.mainWindowController?.modeController == nil {
                self?.remindAboutSaveLocationIfNeeded()
            }
            self?.offerDefaultOutputIfNothingIsRouted()
        }
    }

    /// Asks once where work should be saved, on a launch where nowhere is set.
    ///
    /// After the launch screen has gone, not during it: a modal over a progress
    /// window is a jarring way to meet an app for the first time. Only when there is
    /// genuinely no location — someone who has set one is never asked again whatever
    /// they answered here.
    private func remindAboutSaveLocationIfNeeded() {
        guard preferences.preferences.saveLocation == nil else { return }
        let response = ReminderAlert.show(
            .setSaveLocation,
            store: preferences,
            title: "Where should Videoboy save your work?",
            detail: "Pick a folder for your templates now, or set it later in Settings. "
                + "Until one is chosen you will be asked each time you save.",
            buttons: ["Choose Folder…", "Later"]
        )
        guard response == .primary else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            preferences.preferences.saveLocation = url
            Log.info(.app, "save location set to \(url.path)")
        }
    }

    /// Offers a sensible output when nothing is being sent anywhere.
    ///
    /// A video mixer with no output is not obviously broken — the previews all work,
    /// so it looks fine until you go looking for a picture on the screen that was
    /// supposed to have one. Saying so once, by name, with a button that does it, is
    /// cheaper than letting someone find out during a set.
    private func offerDefaultOutputIfNothingIsRouted() {
        guard let controller = mainWindowController else { return }
        guard controller.shellController?.hasNoOutputs == true else { return }
        guard let display = controller.shellController?.recommendedDisplay() else {
            // Only the main display is attached. There is nothing to recommend, and
            // proposing the display the app is running on would be proposing a window
            // that covers the controls.
            Log.info(.output, "no external display; not offering a default output")
            return
        }

        let response = ReminderAlert.show(
            .noOutputsSelected,
            store: preferences,
            title: "Nothing is being sent out yet",
            detail: "Videoboy suggests \(display.name) — \(display.pixelWidth)×\(display.pixelHeight).\n\n"
                + (display.modeSwitchObstacle.map { "\($0)\n\n" } ?? "")
                + "You can change this any time from the send glyph under any preview.",
            buttons: ["Send Program to \(display.name)", "Not Now"]
        )
        guard response == .primary else { return }
        controller.shellController?.routeProgram(to: display)
    }

    /// Offers to save before quitting.
    ///
    /// Returns `.terminateLater` only while the prompt is up; the answer is given
    /// back to AppKit as soon as it is known. Cancel really cancels — a quit prompt
    /// whose Cancel does not cancel is worse than no prompt.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A show that has a file and auto-save on is saved without asking.
        if preferences.preferences.autoSave != .never, shellController?.currentTemplateURL != nil {
            return saveCurrentTemplate(askingForLocation: false) ? .terminateNow : .terminateCancel
        }
        let response = ReminderAlert.show(
            .saveOnQuit,
            store: preferences,
            title: "Save before quitting?",
            detail: preferences.preferences.saveLocation == nil
                ? "No save location is set, so you will be asked where to put it."
                : "Your work will be saved to \(preferences.preferences.saveLocation?.lastPathComponent ?? "your folder").",
            buttons: ["Save", "Don't Save", "Cancel"],
            style: .warning
        )

        switch response {
        case .notShown, .secondary:
            return .terminateNow
        case .tertiary:
            return .terminateCancel
        case .primary:
            // Save, then quit; a cancelled Save As panel cancels the quit too.
            return saveCurrentTemplate(askingForLocation: false) ? .terminateNow : .terminateCancel
        }
    }

    /// Quitting when the window closes is right for a single-window instrument.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Gives anything holding a file or a socket the chance to finish it properly.
    ///
    /// There was no `applicationWillTerminate` at all, so `OutputRouter.closeAll()` and
    /// `Engine.stop()` had no production caller — `closeAll` was reached only from a
    /// self-QA check. An MPEG-TS stream therefore never got its trailer written: every
    /// stream ended truncated, and because the picture had looked correct right up to
    /// the moment of quitting, nothing about it looked like a bug.
    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.shellController?.shutdown()
        // Every library change is already written; wait for the last of them.
        catalog?.flush()
    }

    // MARK: - The library's catalog

    /// The saved library. Nil when it could not be opened — the library then works
    /// for this session only, and the person has been told so.
    private var catalog: Catalog?

    /// Opens the catalog and hands it to the library, which loads what was saved (or,
    /// the first time, saves what it starts with).
    /// Opens the library catalog and attaches it; false (with a status-strip notice,
    /// never a modal) when it cannot be opened.
    @discardableResult
    private func openCatalog(into controller: MainWindowController) -> Bool {
        let url = preferences.preferences.catalogURL
        do {
            let opened = try Catalog(url: url)
            controller.shellController?.shell.grid.panels.library.attach(opened)
            catalog = opened
            return true
        } catch {
            Log.error(.app, "library catalog not opened: \(error)")
            controller.shellController?.presentNotice(
                "The library could not be opened — clips added now will not be saved",
                "\(error). Close the other copy of Videoboy, or move the catalog, and open this one again.")
            return false
        }
    }

    @objc private func importClips() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose clips or folders. Each folder becomes a bin."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        mainWindowController?.shellController?.importFiles(panel.urls)
    }

    @objc private func exportLibrary() {
        guard let catalog else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Videoboy Library.json"
        panel.message = "A readable copy of the library: every clip, bin and mark."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try catalog.exportJSON(to: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([preferences.preferences.catalogURL])
    }

    /// File: import, and the library's own file.
    private func makeFileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        // The show: New / Open / Save (audit L1 — the patch used to be lost at quit).
        for (title, action, key, shift) in [
            ("New", #selector(newTemplate), "n", false),
            ("Open…", #selector(openTemplate), "o", false)
        ] as [(String, Selector, String, Bool)] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = shift ? [.command, .shift] : .command
            entry.target = self
            menu.addItem(entry)
        }
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(.separator())
        for (title, action, key, shift) in [
            ("Save", #selector(saveTemplate), "s", false),
            ("Save As…", #selector(saveTemplateAs), "s", true)
        ] as [(String, Selector, String, Bool)] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = shift ? [.command, .shift] : .command
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        // ⇧⌘I, Lightroom's import key.
        let importItem = NSMenuItem(title: "Import Clips…", action: #selector(importClips), keyEquivalent: "i")
        importItem.keyEquivalentModifierMask = [.command, .shift]
        importItem.target = self
        menu.addItem(importItem)
        menu.addItem(.separator())
        let export = NSMenuItem(title: "Export Library as JSON…", action: #selector(exportLibrary), keyEquivalent: "")
        export.target = self
        menu.addItem(export)
        let reveal = NSMenuItem(title: "Show Library in Finder", action: #selector(revealLibrary), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        item.submenu = menu
        return item
    }

    // MARK: - Templates (File menu)

    private let recentMenu = NSMenu(title: "Open Recent")
    fileprivate var recentMenuForDelegate: NSMenu { recentMenu }
    private var autosaveTimer: Timer?

    private var shellController: ShellController? { mainWindowController?.shellController }

    @objc private func newTemplate() { shellController?.newTemplate() }

    @objc private func openTemplate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.directoryURL = preferences.preferences.saveLocation
        panel.message = "Open a Videoboy template (.vbt)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(templateAt: url)
    }

    /// Opens a template file (also Open Recent).
    func open(templateAt url: URL) {
        do {
            let document = try TemplateDocument.read(from: url)
            shellController?.openTemplate(document, from: url)
            remember(url)
        } catch {
            shellController?.presentNotice("Could not open \(url.lastPathComponent)", "\(error)")
        }
    }

    @objc private func saveTemplate() { saveCurrentTemplate(askingForLocation: false) }
    @objc private func saveTemplateAs() { saveCurrentTemplate(askingForLocation: true) }

    /// Saves to the current file, or asks where. Returns false if nothing was saved.
    @discardableResult
    private func saveCurrentTemplate(askingForLocation: Bool) -> Bool {
        guard let shell = shellController else { return false }
        var url = askingForLocation ? nil : shell.currentTemplateURL
        if url == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = shell.currentTemplateURL?.lastPathComponent ?? "untitled.vbt"
            panel.directoryURL = preferences.preferences.saveLocation
            panel.message = "Save the show — chains, faders, mappings, clock and channels"
            guard panel.runModal() == .OK, var chosen = panel.url else { return false }
            if chosen.pathExtension.lowercased() != "vbt" { chosen.appendPathExtension("vbt") }
            url = chosen
        }
        guard let url else { return false }
        do {
            try shell.saveTemplate(to: url)
            remember(url)
            return true
        } catch {
            shell.presentNotice("Could not save \(url.lastPathComponent)", "\(error)")
            return false
        }
    }

    private func remember(_ url: URL) {
        var recent = preferences.preferences.recentTemplates.filter { $0 != url.path }
        recent.insert(url.path, at: 0)
        preferences.preferences.recentTemplates = Array(recent.prefix(10))
    }

    @objc fileprivate func recentChosenFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        open(templateAt: URL(fileURLWithPath: path))
    }

    /// Auto-save (Settings ▸ Save): writes over the current template on its cadence.
    /// Only when a template has been saved once — it never invents a file.
    private func startAutosave() {
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, let shell = self.shellController, let url = shell.currentTemplateURL else { return }
            let minutes: Double
            switch self.preferences.preferences.autoSave {
            case .everyFiveMinutes: minutes = 5
            case .everyFifteenMinutes: minutes = 15
            case .never, .onQuitOnly: return
            }
            guard Date().timeIntervalSince(self.lastAutosave) >= minutes * 60 else { return }
            self.lastAutosave = Date()
            // Captured on the main thread (it reads the registry), written on a queue.
            let document = shell.captureTemplate(name: url.deletingPathExtension().lastPathComponent)
            DispatchQueue.global(qos: .utility).async {
                do { try document.write(to: url); Log.info(.template, "auto-saved \(url.lastPathComponent)") }
                catch { Log.error(.template, "auto-save failed: \(error)") }
            }
        }
    }
    private var lastAutosave = Date()

    /// Records what this build is and what it can see, once, at startup.
    private func logEnvironment() {
        Log.info(.app, "Videoboy \(Videoboy.version) starting")
        let flags = FeatureFlags.current.enabled.map(\.rawValue).sorted()
        Log.info(.app, "feature flags on: \(flags.joined(separator: ", "))")

        if MetalContext.shared == nil {
            Log.error(.render, "Metal is unavailable; previews and output will stay blank")
        }
        for display in DisplayRouter.availableDisplays() {
            Log.info(.output, "display '\(display.name)' \(display.modeDescription)\(display.isMain ? " [main]" : "")")
        }
    }

    /// View ▸ Import ⌘1 · VJ ⌘2 · Settings ⌘3 (proposal §4). Menu items rather than
    /// bare key handling, so the modes are discoverable and remappable in System
    /// Settings ▸ Keyboard.
    private func makeViewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = ModeController.makeViewMenu(target: self, action: #selector(modeMenuChosen(_:)))
        viewMenu = menu
        item.submenu = menu
        return item
    }

    @objc func modeMenuChosen(_ sender: NSMenuItem) {
        guard let mode = AppMode(rawValue: sender.tag) else { return }
        mainWindowController?.modeController?.show(mode)
    }

    /// Ticks the current mode in the View menu.
    private func markMode(_ mode: AppMode) {
        for entry in viewMenu?.items ?? [] { entry.state = entry.tag == mode.rawValue ? .on : .off }
    }

    /// Opens the Preferences window, reusing it if it is already open — or, with the
    /// mode bar on, switches to Settings mode (⌘, still works).
    @objc private func showPreferences() {
        if let modes = mainWindowController?.modeController {
            modes.show(.settings)
            return
        }
        guard let engine = mainWindowController?.engine else {
            Log.warn(.app, "no engine yet; cannot open preferences")
            return
        }
        if preferencesController == nil {
            preferencesController = PreferencesWindowController(
                store: preferences, engine: engine)
        }
        // No capture-device callback wired here any more — adding, renaming or
        // removing a source writes straight through `PreferenceStore`, and
        // `ShellController` picked that up itself via `preferences.onChange` the
        // moment it wired the libraries (`refreshConfiguredSources`).
        preferencesController?.onPreviewFillChanged = { [weak self] fill in
            self?.mainWindowController?.shellController?.setPreviewFill(fill)
        }
        preferencesController?.showWindow(nil)
        preferencesController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Builds the menu bar shown in the mockup's system bar: File, Edit, Workspace,
    /// Templates, Window, Help. Items whose features are not built yet are present
    /// but disabled, per CLAUDE.md — never omitted.
    private func buildMenuBar() {
        let mainMenu = NSMenu()

        // Application menu. Its title is taken from the bundle name by AppKit.
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Videoboy", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // Comma, because that is where every Mac user's hand already goes.
        appMenu.addItem(withTitle: "Settings…", action: #selector(showPreferences), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Videoboy", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Videoboy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // The remaining menus mirror the mockup. Their contents arrive with the
        // features they drive; until then they are visibly present and disabled.
        for title in ["File", "Edit", "Workspace", "Templates"] {
            if title == "File" {
                mainMenu.addItem(makeFileMenu())
                continue
            }
            let item = NSMenuItem()
            if title == "Edit" {
                item.submenu = Self.makeEditMenu()
                mainMenu.addItem(item)
                continue
            }
            let submenu = NSMenu(title: title)
            let placeholder = NSMenuItem(title: "Not yet implemented", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)
            item.submenu = submenu
            mainMenu.addItem(item)
        }

        if FeatureFlag.modeBar.isOn { mainMenu.addItem(makeViewMenu()) }

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let firstRun = NSMenuItem(title: "First Run Notes (docs/FIRST-RUN.md)", action: nil, keyEquivalent: "")
        firstRun.isEnabled = false
        helpMenu.addItem(firstRun)
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// The standard Edit menu.
    ///
    /// Every item is sent to the FIRST RESPONDER (no target), which is how ⌘A, ⌘C and
    /// ⌘V reach whatever has the keyboard: a text field, or a library, whose panel
    /// implements copy, paste, delete and select-all for its clips. Without this menu
    /// those keys went nowhere at all — not even in the search field. Static so the
    /// self-QA can install the same menu and press the same keys.
    static func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        func add(_ title: String, _ action: Selector, _ key: String,
                 _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        add("Undo", Selector(("undo:")), "z")
        add("Redo", Selector(("redo:")), "z", [.command, .shift])
        menu.addItem(.separator())
        add("Cut", #selector(NSText.cut(_:)), "x")
        add("Copy", #selector(NSText.copy(_:)), "c")
        add("Paste", #selector(NSText.paste(_:)), "v")
        // No key: ⌘⌫ in a text field means "delete to the start of the line", and a
        // menu key would take it away. The libraries handle ⌘⌫ themselves.
        add("Delete", #selector(NSText.delete(_:)), "")
        add("Select All", #selector(NSText.selectAll(_:)), "a")
        return menu
    }
}

// MARK: - Open Recent

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenuForDelegate else { return }
        menu.removeAllItems()
        let paths = preferences.preferences.recentTemplates.filter { FileManager.default.fileExists(atPath: $0) }
        if paths.isEmpty {
            let empty = NSMenuItem(title: "No Recent Templates", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for path in paths {
            let entry = NSMenuItem(title: URL(fileURLWithPath: path).lastPathComponent,
                                   action: #selector(recentChosenFromMenu(_:)), keyEquivalent: "")
            entry.representedObject = path
            entry.target = self
            entry.toolTip = path
            menu.addItem(entry)
        }
    }
}

