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

        let restore = Controls.button(
            "Restore All Reminders", target: self, action: #selector(restoreReminders))
        reminderCountLabel = Controls.label(
            reminderSummary(), font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)

        return Controls.column([
            header(.defaults),
            spacer(14),
            field("Clock source", clock),
            field("Subdivision", subdivision),
            field("Tempo", tempo),
            field("Loop mode", loop),
            field("Blend mode", blend),
            field("Play on load", playOnLoad),
            spacer(12),
            field("Reminders", Controls.row([restore, reminderCountLabel!], spacing: 10))
        ], spacing: 8)
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

    // MARK: - Inputs

    func makeInputsPane() -> NSView {
        // What is connected NOW, not a setting. Read from the engine each time the
        // pane is built so it is not a stale snapshot from launch.
        let midiNames = engine.midi.connectedSourceNames
        let midi = midiNames.isEmpty ? ["No MIDI sources"] : midiNames

        var rows: [NSView] = [header(.inputs), spacer(14)]
        rows.append(field("MIDI sources", Controls.column(
            midi.map { Controls.label($0, color: Theme.Color.textSecondary) }, spacing: 2)))

        let captureNames = AVFoundationCaptureSource().enumerateDeviceNames()
        rows.append(field("Capture devices", Controls.column(
            (captureNames.isEmpty ? ["None found"] : captureNames)
                .map { Controls.label($0, color: Theme.Color.textSecondary) }, spacing: 2)))

        rows.append(spacer(10))
        rows.append(Controls.note(
            "Audio input is chosen by the system. Videoboy uses the default input device.",
            width: Self.noteWidth))

        return Controls.column(rows, spacing: 8)
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
}
