//
//  PreferencePanes.swift — the contents of each Preferences pane.
//
//  Purpose : Split from PreferencesWindowController so the window's mechanics (tabs,
//            selection, layout) stay readable separately from the six unrelated
//            settings screens that live inside it.
//  Inputs  : the PreferenceStore and the Engine, through the controller.
//  Outputs : edits written straight through the store.
//  Connects: PreferencesWindowController.
//  Extend  : one `make…Pane()` per pane. Controls for features that are not built
//            yet are present and disabled, never omitted (CLAUDE.md) — a settings
//            window is where people go to find out what an app can do, so a missing
//            row reads as "this app cannot" rather than "not yet".
//

import AppKit
import VideoboyCore

extension PreferencesWindowController {

    // MARK: - Save

    func makeSavePane() -> NSView {
        let pathLabel = Controls.label(
            store.preferences.saveLocation?.path ?? "Not chosen yet",
            color: store.preferences.saveLocation == nil
                ? Theme.Color.textTertiary : Theme.Color.textSecondary
        )
        pathLabel.lineBreakMode = .byTruncatingHead
        savedPathLabel = pathLabel

        let choose = Controls.button("Choose…", target: self, action: #selector(chooseSaveLocation))

        let cadence = Controls.popUp(
            AutoSaveCadence.allCases.map(\.displayName),
            target: self, action: #selector(autoSaveChanged(_:))
        )
        cadence.selectItem(at: AutoSaveCadence.allCases.firstIndex(
            of: store.preferences.autoSave) ?? 0)

        return Controls.column([
            header(.save),
            spacer(14),
            field("Save location", Controls.row([pathLabel, choose], spacing: 8)),
            field("Auto-save", cadence),
            spacer(8),
            Controls.note(
                "Auto-save writes over the current template. It does not make versions — "
                + "use Save As for that.", width: Self.noteWidth)
        ], spacing: 8)
    }

    @objc func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Where should Videoboy save your templates?"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.preferences.saveLocation = url
        savedPathLabel?.stringValue = url.path
        savedPathLabel?.textColor = Theme.Color.textSecondary
        Log.info(.app, "save location set to \(url.path)")
    }

    @objc func autoSaveChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard AutoSaveCadence.allCases.indices.contains(index) else { return }
        store.preferences.autoSave = AutoSaveCadence.allCases[index]
        Log.info(.app, "auto-save is now \(store.preferences.autoSave.displayName)")
    }

    // MARK: - Defaults

    func makeDefaultsPane() -> NSView {
        let clock = Controls.segmented(
            ["Internal", "Audio"],
            selected: store.preferences.defaultClockSource == "Audio" ? 1 : 0,
            target: self, action: #selector(defaultClockChanged(_:)))

        let subdivisions = Subdivision.allCases.map(\.rawValue)
        let subdivision = Controls.popUp(
            subdivisions, target: self, action: #selector(defaultSubdivisionChanged(_:)))
        subdivision.selectItem(at: subdivisions.firstIndex(
            of: store.preferences.defaultSubdivision) ?? 2)

        let tempo = NSTextField(string: String(format: "%.1f", store.preferences.defaultTempo))
        tempo.translatesAutoresizingMaskIntoConstraints = false
        tempo.font = Theme.Font.mono
        tempo.alignment = .right
        tempo.target = self
        tempo.action = #selector(defaultTempoChanged(_:))
        tempo.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let loopModes = LoopMode.allCases
        let loop = Controls.segmented(
            loopModes.map(\.displayName),
            selected: loopModes.firstIndex(of: store.preferences.defaultLoopMode) ?? 0,
            target: self, action: #selector(defaultLoopModeChanged(_:)))

        let blends = BlendMode.allCases
        let blend = Controls.popUp(
            blends.map(\.displayName), target: self, action: #selector(defaultBlendChanged(_:)))
        blend.selectItem(at: blends.firstIndex(of: store.preferences.defaultBlendMode) ?? 0)

        let playOnLoad = Controls.toggle(
            on: store.preferences.playOnLoad,
            target: self, action: #selector(playOnLoadChanged(_:)))

        // How a picture sits in a window that is not its shape. Four choices, named
        // the way AVFoundation and CSS both name them, so nobody has to guess which
        // one crops and which one letterboxes.
        let fills = PreviewFill.allCases
        let fill = Controls.segmented(
            fills.map(\.displayName),
            selected: fills.firstIndex(of: store.preferences.previewFill) ?? 0,
            target: self, action: #selector(previewFillChanged(_:)))
        for (index, mode) in fills.enumerated() {
            fill.setToolTip(mode.explanation, forSegment: index)
        }

        let restore = Controls.button(
            "Restore All Reminders", target: self, action: #selector(restoreReminders))
        reminderCountLabel = Controls.label(
            reminderSummary(), font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)

        // What ADV loads when a sub-mix's Up Next is empty (docs/specs/ab-roll-adv.md).
        // Set before the show, so it lives here rather than on the tight fader row.
        let fallbacks = ABRollFallback.allCases
        func fallbackPopUp(_ bus: String) -> NSPopUpButton {
            let popUp = Controls.popUp(fallbacks.map(\.displayName), target: self,
                                       action: #selector(advanceFallbackChanged(_:)))
            popUp.identifier = NSUserInterfaceItemIdentifier("fallback|\(bus)")
            popUp.selectItem(at: fallbacks.firstIndex(of: store.preferences.advanceFallback[bus] ?? .inOrder) ?? 1)
            return popUp
        }
        let announce = Controls.toggle(
            on: store.preferences.announcesAdvanceFallback,
            target: self, action: #selector(announceFallbackChanged(_:)))

        return Controls.column([
            header(.defaults),
            spacer(14),
            field("Clock source", clock),
            field("Subdivision", subdivision),
            field("Tempo", tempo),
            field("Loop mode", loop),
            field("Blend mode", blend),
            field("Play on load", playOnLoad),
            field("Picture fill", fill),
            field("Up Next empty, A/B", fallbackPopUp("one")),
            field("Up Next empty, C/D", fallbackPopUp("two")),
            field("Say when ADV improvises", announce),
            spacer(12),
            field("Reminders", Controls.row([restore, reminderCountLabel!], spacing: 10))
        ], spacing: 8)
    }

    @objc func advanceFallbackChanged(_ sender: NSPopUpButton) {
        guard let bus = sender.identifier?.rawValue.split(separator: "|").last.map(String.init),
              ABRollFallback.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        store.preferences.advanceFallback[bus] = ABRollFallback.allCases[sender.indexOfSelectedItem]
        Log.info(.app, "ADV fallback for \(bus): \(ABRollFallback.allCases[sender.indexOfSelectedItem].displayName)")
    }

    @objc func announceFallbackChanged(_ sender: NSSwitch) {
        store.preferences.announcesAdvanceFallback = sender.state == .on
    }

    private func reminderSummary() -> String {
        let count = store.preferences.suppressedReminders.count
        return count == 0 ? "None are hidden" : "\(count) hidden"
    }

    @objc func defaultClockChanged(_ sender: NSSegmentedControl) {
        store.preferences.defaultClockSource = sender.selectedSegment == 1 ? "Audio" : "Internal"
    }

    @objc func defaultSubdivisionChanged(_ sender: NSPopUpButton) {
        store.preferences.defaultSubdivision = sender.titleOfSelectedItem ?? "1/4"
    }

    @objc func defaultTempoChanged(_ sender: NSTextField) {
        // Clamped rather than rejected: someone typing 400 means "as fast as you go",
        // and an error sheet over a preferences field is a heavier answer than the
        // mistake deserves.
        let clamped = min(max(sender.doubleValue, 20), 300)
        store.preferences.defaultTempo = clamped
        sender.stringValue = String(format: "%.1f", clamped)
    }

    @objc func defaultLoopModeChanged(_ sender: NSSegmentedControl) {
        let modes = LoopMode.allCases
        guard modes.indices.contains(sender.selectedSegment) else { return }
        store.preferences.defaultLoopMode = modes[sender.selectedSegment]
    }

    @objc func defaultBlendChanged(_ sender: NSPopUpButton) {
        let blends = BlendMode.allCases
        guard blends.indices.contains(sender.indexOfSelectedItem) else { return }
        store.preferences.defaultBlendMode = blends[sender.indexOfSelectedItem]
    }

    @objc func previewFillChanged(_ sender: NSSegmentedControl) {
        let fills = PreviewFill.allCases
        guard fills.indices.contains(sender.selectedSegment) else { return }
        store.preferences.previewFill = fills[sender.selectedSegment]
        onPreviewFillChanged?(fills[sender.selectedSegment])
    }

    @objc func playOnLoadChanged(_ sender: NSSwitch) {
        store.preferences.playOnLoad = sender.state == .on
    }

    @objc func restoreReminders() {
        store.resetReminders()
        reminderCountLabel?.stringValue = reminderSummary()
    }

    // MARK: - Outputs

    func makeOutputsPane() -> NSView {
        let table = DestinationListView(store: store)
        destinationList = table
        table.translatesAutoresizingMaskIntoConstraints = false
        table.heightAnchor.constraint(equalToConstant: 300).isActive = true

        return Controls.column([
            header(.outputs),
            spacer(10),
            Controls.note(
                "Displays are found as they are plugged in and are always available — "
                + "they are not listed here. This is for the destinations you define.",
                width: Self.noteWidth),
            spacer(6),
            table
        ], spacing: 8)
    }

    // MARK: - Data Burn

    /// FILE / TC text style. One style for every monitor and both sub-mix burns, so
    /// the text a performer reads on a monitor is the text that goes to air.
    func makeDataBurnPane() -> NSView {
        let style = store.preferences.dataBurnStyle

        // Every installed family, plus the saved one if it has since been removed —
        // a missing font should still show what was chosen rather than silently
        // pretending the first family in the list was.
        var families = NSFontManager.shared.availableFontFamilies
        if !families.contains(style.fontFamily) { families.insert(style.fontFamily, at: 0) }
        let font = Controls.popUp(families, target: self, action: #selector(dataBurnFontChanged(_:)))
        font.selectItem(withTitle: style.fontFamily)

        let sizes = DataBurnStyle.pixelSizes
        let size = Controls.popUp(
            sizes.map { "\(Int($0)) px" }, target: self, action: #selector(dataBurnSizeChanged(_:)))
        size.selectItem(at: sizes.firstIndex(of: style.pixelSize)
            ?? sizes.firstIndex(of: DataBurnStyle().pixelSize) ?? 0)

        let bold = Controls.toggle(
            on: style.isBold, target: self, action: #selector(dataBurnBoldChanged(_:)))

        let colour = NSColorWell()
        colour.isBordered = true
        colour.color = NSColor(cgColor: style.colour.cgColor) ?? .white
        colour.target = self
        colour.action = #selector(dataBurnColourChanged(_:))
        colour.translatesAutoresizingMaskIntoConstraints = false
        colour.heightAnchor.constraint(equalToConstant: 18).isActive = true
        colour.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let backings = DataBurnStyle.Backing.allCases
        let backing = Controls.segmented(
            backings.map(\.displayName),
            selected: backings.firstIndex(of: style.backing) ?? 0,
            target: self, action: #selector(dataBurnBackingChanged(_:)))

        // A plain layer, not an NSImageView: it is a picture, not a control, and an
        // image view is an enabled control with no action — what the audit forbids.
        let sample = NSView()
        sample.translatesAutoresizingMaskIntoConstraints = false
        sample.wantsLayer = true
        sample.layer?.backgroundColor = Theme.Color.previewEmpty.cgColor
        sample.layer?.contentsGravity = .center
        sample.widthAnchor.constraint(equalToConstant: 420).isActive = true
        sample.heightAnchor.constraint(equalToConstant: 90).isActive = true
        dataBurnSample = sample
        refreshDataBurnSample()

        return Controls.column([
            header(.dataBurn),
            spacer(14),
            field("Font", font),
            field("Size", size),
            field("Bold", bold),
            field("Colour", colour),
            field("Backing", backing),
            spacer(10),
            field("Sample", sample),
            spacer(8),
            Controls.note(
                "Size is in pixels of a 480-line picture, so the text keeps its place in "
                + "the frame whatever the output resolution. Timecode is drop-frame "
                + "(HH:MM:SS;FF) from each clip's playhead.", width: Self.noteWidth)
        ], spacing: 8)
    }

    /// Draws the sample with the renderer the burn uses, over a picture-grey plate —
    /// not a mock-up that could drift from the real thing.
    func refreshDataBurnSample() {
        guard let sample = dataBurnSample else { return }
        guard let image = DataBurnRenderer.render(
                lines: ["A: night_drive.dv 00:04:44;28", "B:"],
                style: store.preferences.dataBurnStyle,
                frameHeight: Int(DataBurnRenderer.referenceFrameHeight)),
              let cgImage = image.makeCGImage() else {
            sample.layer?.contents = nil
            return
        }
        sample.layer?.contents = cgImage
    }

    private func updateDataBurnStyle(_ change: (inout DataBurnStyle) -> Void) {
        change(&store.preferences.dataBurnStyle)
        refreshDataBurnSample()
    }

    @objc func dataBurnFontChanged(_ sender: NSPopUpButton) {
        guard let family = sender.titleOfSelectedItem else { return }
        updateDataBurnStyle { $0.fontFamily = family }
    }

    @objc func dataBurnSizeChanged(_ sender: NSPopUpButton) {
        let sizes = DataBurnStyle.pixelSizes
        guard sizes.indices.contains(sender.indexOfSelectedItem) else { return }
        updateDataBurnStyle { $0.pixelSize = sizes[sender.indexOfSelectedItem] }
    }

    @objc func dataBurnBoldChanged(_ sender: NSSwitch) {
        updateDataBurnStyle { $0.isBold = sender.state == .on }
    }

    @objc func dataBurnColourChanged(_ sender: NSColorWell) {
        guard let rgb = sender.color.usingColorSpace(.deviceRGB) else { return }
        updateDataBurnStyle {
            $0.colour = TitlerColor(
                red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
                blue: Double(rgb.blueComponent))
        }
    }

    @objc func dataBurnBackingChanged(_ sender: NSSegmentedControl) {
        let backings = DataBurnStyle.Backing.allCases
        guard backings.indices.contains(sender.selectedSegment) else { return }
        updateDataBurnStyle { $0.backing = backings[sender.selectedSegment] }
    }

    // MARK: - Inputs / Sources

    func makeInputsPane() -> NSView {
        // What is connected NOW, not a setting. Read from the engine each time the
        // pane is built so it is not a stale snapshot from launch.
        let midiNames = engine.midi.connectedSourceNames
        let midi = midiNames.isEmpty ? ["No MIDI sources"] : midiNames

        var rows: [NSView] = [header(.inputs), spacer(14)]
        rows.append(field("MIDI sources", Controls.column(
            midi.map { Controls.label($0, color: Theme.Color.textSecondary) }, spacing: 2)))
        rows.append(spacer(10))
        rows.append(Controls.note(
            "Audio input is chosen by the system. Videoboy uses the default input device.",
            width: Self.noteWidth))
        rows.append(spacer(14))

        // Every source the Asset Browser's Sources tab shows comes from here — see
        // `SourceListView`'s header for why + opens a menu rather than a blank row.
        rows.append(Controls.label("Sources", color: Theme.Color.textSecondary))
        let list = SourceListView(store: store, engine: engine)
        sourceList = list
        list.translatesAutoresizingMaskIntoConstraints = false
        list.heightAnchor.constraint(equalToConstant: 220).isActive = true
        rows.append(list)

        return Controls.column(rows, spacing: 8)
    }

    // MARK: - Shaders

    func makeShadersPane() -> NSView {
        let list = makeShaderList()
        shaderList = list
        list.translatesAutoresizingMaskIntoConstraints = false
        list.heightAnchor.constraint(equalToConstant: 360).isActive = true

        return Controls.column([
            header(.shaders),
            spacer(10),
            Controls.note(
                "+ copies .fs files (or whole folders) into Videoboy's own ISF folder, with "
                + "their images, so they stay even if the originals move. − moves an "
                + "imported module to the Trash. You can also drop files on the list.",
                width: Self.noteWidth),
            spacer(6),
            list
        ], spacing: 8)
    }

    // MARK: - Hot keys

    func makeHotKeysPane() -> NSView {
        // The actions worth a key are the ones you reach for without looking. Editing
        // them is not built; the list is real and says what the keys currently do,
        // which is the question people open this pane to answer.
        let actions: [(String, String)] = [
            ("Cut to programme", "Return"),
            ("Tap tempo", "T"),
            ("Play / stop", "Space"),
            ("Arm record", "R"),
            ("Show or hide panels", "1 – 4"),
            ("Hold to map a control", "Shift")
        ]
        var rows: [NSView] = [header(.hotKeys), spacer(14)]
        for (action, key) in actions {
            let keyLabel = Controls.monoLabel(key, color: Theme.Color.textSecondary)
            rows.append(field(action, Controls.row([keyLabel, Controls.spacer()], spacing: 0)))
        }
        rows.append(spacer(12))
        rows.append(Controls.note("Editing these is not built yet.", width: Self.noteWidth))
        return Controls.column(rows, spacing: 6)
    }

    // MARK: - MIDI mapping

    func makeMIDIMappingPane() -> NSView {
        var rows: [NSView] = [header(.midiMapping), spacer(14)]

        let bindings = engine.registry.bindings
        if bindings.isEmpty {
            rows.append(Controls.note(
                "Nothing is mapped. Hold Shift over the main window to light up every "
                + "control that can be, then click one and move a knob.",
                width: Self.noteWidth))
        } else {
            for binding in bindings.sorted(by: { $0.slot < $1.slot }) {
                let target = Controls.label(
                    "\(binding.slot) · \(binding.code.displayName)",
                    color: Theme.Color.textSecondary)
                let source = Controls.monoLabel(
                    binding.source.description, color: Theme.Color.accent)
                rows.append(Controls.row(
                    [source, target, Controls.spacer()], spacing: 12))
            }
            rows.append(spacer(10))
            rows.append(Controls.button(
                "Remove All Mappings", target: self, action: #selector(removeAllMappings)))
        }
        return Controls.column(rows, spacing: 6)
    }

    @objc func removeAllMappings() {
        for binding in engine.registry.bindings {
            engine.registry.unbind(source: binding.source)
        }
        Log.info(.midi, "all MIDI mappings removed from preferences")
        rebuildPane(.midiMapping)
    }

    // MARK: - Shared

    /// How wide explanatory prose is allowed to be before it wraps. Sized to the
    /// detail area so a sentence never widens the window.
    static var noteWidth: CGFloat { 560 }

    /// Fixed vertical space, for separating groups inside a column.
    func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
    // MARK: - EMU

    /// Emulated machines, and the files they need.
    ///
    /// ── WHY THIS PANE IS MOSTLY A LIST OF WHAT IS MISSING ───────────────────────
    ///
    /// Because that is the honest state of emulation on a fresh machine, and because
    /// every one of the missing things has to be supplied by the person rather than
    /// fetched. A libretro core is GPL and runs out of process; a Kickstart ROM is
    /// copyrighted; the software is on a disc they own. This app downloads none of it
    /// and bundles none of it, so the useful thing a settings pane can do is say
    /// exactly what is absent and where to put it.
    func makeEmuPane() -> NSView {
        var rows: [NSView] = [header(.emu), spacer(14)]

        // The emulator itself.
        let installed = FSUAEInstallation.isInstalled()
        rows.append(field("Emulator", Controls.label(
            installed ? "FS-UAE — installed" : "FS-UAE — not installed",
            color: installed ? Theme.Color.textSecondary : Theme.Color.tallyOnAir)))
        if !installed {
            rows.append(Controls.note(FSUAEInstallation.installationHint, width: Self.noteWidth))
        }

        // Firmware. AROS is why this works at all without a Kickstart.
        let kickstarts = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/FS-UAE/Kickstarts")
        let roms = ((try? FileManager.default.contentsOfDirectory(atPath: kickstarts.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".rom") }
        rows.append(field("Kickstart", Controls.label(
            roms.isEmpty ? "None — running on AROS" : roms.joined(separator: ", "),
            color: Theme.Color.textSecondary)))
        rows.append(Controls.note(
            roms.isEmpty
                ? "FS-UAE has a built-in AROS ROM, which is why a machine boots with no "
                    + "Kickstart at all. AROS is a reimplementation, and some 1990s "
                    + "software notices — Scala MM300's graphics device will not load "
                    + "under it. A real Kickstart 3.x fixes that. Put one in "
                    + "Documents/FS-UAE/Kickstarts."
                : "A real Kickstart is in use.",
            width: Self.noteWidth))

        rows.append(spacer(10))

        // Cores, for the platforms that use them.
        let library = CoreLibrary(
            coresDirectory: EmulatorController.workspace.appendingPathComponent("cores"),
            systemDirectory: EmulatorController.workspace.appendingPathComponent("system"))
        let statuses = library.status()
        rows.append(field("Cores", Controls.column(
            statuses.map { status in
                Controls.label(
                    status.summary,
                    color: status.isRunnable ? Theme.Color.textSecondary : Theme.Color.textTertiary)
            }, spacing: 2)))

        rows.append(spacer(10))

        // The box for adding things.
        let addRow = Controls.row([
            Controls.button("Add core…", target: self, action: #selector(addCorePressed)),
            Controls.button("Add ROM…", target: self, action: #selector(addROMPressed)),
            Controls.button("Add disc…", target: self, action: #selector(addDiscPressed)),
            Controls.spacer()
        ], spacing: 6)
        rows.append(field("Add", addRow))
        rows.append(Controls.note(
            "Files are COPIED into Videoboy's own Application Support folder, never "
                + "moved and never uploaded. Discs are referenced where they are. "
                + "Deleting that folder undoes all of it.",
            width: Self.noteWidth))

        rows.append(spacer(10))
        rows.append(field("Workspace", Controls.button(
            "Reveal in Finder", target: self, action: #selector(revealWorkspacePressed))))

        return Controls.column(rows, spacing: 8)
    }

    @objc func addCorePressed() {
        // A libretro core. Named, not fetched — and it runs OUT OF PROCESS, because it
        // is GPL and this app is distributed.
        chooseFile(
            title: "Choose a libretro core",
            extensions: ["dylib", "so"],
            into: "cores")
    }

    @objc func addROMPressed() {
        chooseFile(
            title: "Choose a system ROM",
            extensions: ["rom", "bin", "img"],
            into: "system")
    }

    @objc func addDiscPressed() {
        // Discs are REFERENCED, not copied: they are large, they are the person's
        // media, and a second copy of a 650MB image helps nobody.
        let panel = NSOpenPanel()
        panel.title = "Choose a disc image"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.preferences.emulatorDiscPath = url.path
        Log.info(.titler, "emulator disc set to \(url.lastPathComponent)")
    }

    @objc func revealWorkspacePressed() {
        let workspace = EmulatorController.workspace
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([workspace])
    }

    /// Copies a chosen file into the workspace, and says so.
    private func chooseFile(title: String, extensions: [String], into folder: String) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let directory = EmulatorController.workspace.appendingPathComponent(folder)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            Log.info(.titler, "added \(url.lastPathComponent) to \(folder)/")
        } catch {
            Log.error(.titler, "could not add \(url.lastPathComponent): "
                + error.localizedDescription)
        }
    }

    // MARK: - Macros & AI

    /// Sequences of commands, and letting a model drive them.
    ///
    /// NOT BUILT, and shown as such rather than omitted. It is here now because the
    /// shape it will take is already decided by what exists: the translation layer
    /// turns a 0...1 value into a real command, so a macro is a NAMED LIST OF THOSE,
    /// and a model driving it produces the same values a fader would. Neither needs a
    /// second way into the machine, which is the thing worth getting right early.
    func makeMacrosPane() -> NSView {
        var rows: [NSView] = [header(.macros), spacer(14)]

        rows.append(field("Macros", Controls.label(
            "Not built yet", color: Theme.Color.textTertiary)))
        rows.append(Controls.note(
            "A macro will be a named list of commands — the same commands the EMU "
                + "faders already send. Recording one means capturing what you do; "
                + "playing one back means sending it again, on the beat if you want.",
            width: Self.noteWidth))

        rows.append(spacer(10))
        rows.append(field("AI control", Controls.label(
            "Not built yet", color: Theme.Color.textTertiary)))
        rows.append(Controls.note(
            "The groundwork is done rather than pending: every EMU control takes a "
                + "value from 0 to 1 and declares in words what it does to the "
                + "software. That is already the interface a model would drive, so "
                + "this needs no new path into the machine — which is the part that "
                + "would have been hard to change later.",
            width: Self.noteWidth))

        rows.append(spacer(10))
        rows.append(Controls.note(
            "Nothing here sends anything anywhere. When it is built, any model use "
                + "will be opt-in and will say what it is sending.",
            width: Self.noteWidth))

        return Controls.column(rows, spacing: 8)
    }

}
