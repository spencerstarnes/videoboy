//
//  SetupPanes.swift — Project, Media and Optimize: the settings the setup assistant
//                     also asks about (proposal §4, §8).
//
//  Purpose : One definition of the canvas / frame-rate / location / optimize choices,
//            shown both as Settings panes and as setup-assistant pages, so the two
//            cannot disagree.
//  Inputs  : the PreferenceStore.
//  Outputs : edits written straight through the store.
//  Connects: PreferencesWindowController (panes), SetupAssistant (pages).
//  Extend  : a canvas or frame rate becomes selectable by enabling it in
//            `SetupChoices` when its phase lands (0.4.11). Optimize presets arrive in
//            0.4.10. Until then they are present and disabled, never omitted.
//

import AppKit
import VideoboyCore

/// The choices both Settings and the setup assistant offer.
enum SetupChoices {
    /// Canvases in proposal §6 order; only SD NTSC is built (any-canvas is 0.4.11).
    static let canvases: [(title: String, available: Bool)] = [
        ("SD NTSC 720×480", true),
        ("SD PAL 720×576", false),
        ("HD 1920×1080", false),
        ("Square 1080×1080", false),
        ("Vertical 1080×1920", false)
    ]
    static let frameRates: [(title: String, available: Bool)] = [
        ("29.97", true), ("30", false), ("25", false), ("24", false), ("23.976", false)
    ]
    /// Why SD NTSC 29.97 is preselected, in one line (proposal §8).
    static let canvasReason = "SD NTSC 29.97 is the reference: the bitstream effects and "
        + "the analog output are built for it. Other canvases arrive in 0.4.11."

    /// A pop-up whose unavailable items are present and disabled. Choosing an item
    /// logs it; only the SD NTSC 29.97 reference is selectable until 0.4.11, so there
    /// is nothing else to store yet.
    static func popUp(_ items: [(title: String, available: Bool)]) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.target = ChoiceLogger.shared
        popUp.action = #selector(ChoiceLogger.chosen(_:))
        popUp.autoenablesItems = false
        for item in items {
            popUp.addItem(withTitle: item.available ? item.title : "\(item.title) — coming")
            popUp.lastItem?.isEnabled = item.available
        }
        popUp.selectItem(at: 0)
        return popUp
    }
}

/// Target for the project pop-ups: records what was chosen.
final class ChoiceLogger: NSObject {
    static let shared = ChoiceLogger()
    @objc func chosen(_ sender: NSPopUpButton) {
        Log.info(.app, "project: \(sender.accessibilityIdentifier()) = \(sender.titleOfSelectedItem ?? "?")")
    }
}

/// A location the person can change: caption, current path, Choose….
///
/// The open panel is user-initiated, so it is allowed to be modal — it is not a
/// notice that can fire by itself mid-show.
final class LocationRow: NSStackView {
    let pathLabel = Controls.label("", color: Theme.Color.textSecondary)
    let chooseButton: NSButton
    private let choose: (URL) -> Void
    private let prompt: String
    private let choosesFiles: Bool

    /// - Parameters:
    ///   - current: shown now.
    ///   - choosesFiles: a file (the catalog) rather than a folder.
    ///   - choose: called with the picked location.
    init(caption: String, current: URL, prompt: String, choosesFiles: Bool = false,
         choose: @escaping (URL) -> Void) {
        self.choose = choose
        self.prompt = prompt
        self.choosesFiles = choosesFiles
        chooseButton = NSButton(title: "Choose…", target: nil, action: nil)
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 10
        let label = Controls.label(caption, color: Theme.Color.textSecondary)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 132).isActive = true
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.stringValue = current.path
        chooseButton.bezelStyle = .rounded
        chooseButton.target = self
        chooseButton.action = #selector(choosePressed)
        chooseButton.setAccessibilityIdentifier("choose-\(caption.lowercased())")
        for view in [label, pathLabel, chooseButton] { addArrangedSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    @objc private func choosePressed() {
        let panel = choosesFiles ? NSSavePanel() : NSOpenPanel()
        if let open = panel as? NSOpenPanel {
            open.canChooseDirectories = true
            open.canChooseFiles = false
            open.canCreateDirectories = true
        } else {
            panel.nameFieldStringValue = URL(fileURLWithPath: pathLabel.stringValue).lastPathComponent
        }
        panel.prompt = "Use This"
        panel.message = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathLabel.stringValue = url.path
        choose(url)
    }
}

extension PreferencesWindowController {

    // MARK: - Project

    func makeProjectPane() -> NSView {
        let canvas = SetupChoices.popUp(SetupChoices.canvases)
        canvas.setAccessibilityIdentifier("project-canvas")
        let rate = SetupChoices.popUp(SetupChoices.frameRates)
        rate.setAccessibilityIdentifier("project-rate")
        let assistant = Controls.button("Run Setup Assistant…", target: self,
                                        action: #selector(runSetupAssistantPressed))
        assistant.setAccessibilityIdentifier("run-setup-assistant")
        return Controls.column([
            header(.project),
            spacer(14),
            field("Canvas", canvas),
            field("Frame rate", rate),
            spacer(8),
            Controls.note(SetupChoices.canvasReason, width: Self.noteWidth),
            spacer(14),
            field("", assistant)
        ], spacing: 8)
    }

    @objc func runSetupAssistantPressed() {
        onRunSetupAssistant?()
    }

    // MARK: - Media

    func makeMediaPane() -> NSView {
        let preferences = store.preferences
        let library = LocationRow(
            caption: "Library", current: preferences.catalogURL,
            prompt: "Where should the library catalog live?", choosesFiles: true
        ) { [weak self] url in
            self?.store.preferences.libraryLocationPath = url.path
            Log.info(.app, "library catalog set to \(url.path) (opens at next launch)")
        }
        let media = LocationRow(
            caption: "Media", current: preferences.mediaLocation,
            prompt: "Where should copied and moved clips go?"
        ) { [weak self] url in self?.store.preferences.mediaLocationPath = url.path }
        let optimized = LocationRow(
            caption: "Optimized media", current: preferences.optimizedMediaLocation,
            prompt: "Where should optimized media be written?"
        ) { [weak self] url in self?.store.preferences.optimizedMediaLocationPath = url.path }
        return Controls.column([
            header(.media),
            spacer(14),
            library, media, optimized,
            spacer(8),
            Controls.note("A new library location is opened at the next launch. Changing a "
                + "location never moves or deletes anything already there.", width: Self.noteWidth)
        ], spacing: 8)
    }

    // MARK: - Optimize

    func makeOptimizePane() -> NSView {
        let useOptimized = Controls.toggle(on: store.preferences.usesOptimizedMedia, target: self,
                                           action: #selector(useOptimizedChanged(_:)))
        let location = LocationRow(
            caption: "Written to", current: store.preferences.optimizedMediaLocation,
            prompt: "Where should optimized media be written?"
        ) { [weak self] url in self?.store.preferences.optimizedMediaLocationPath = url.path }
        return Controls.column([
            header(.optimize),
            spacer(14),
            field("Use optimized media", useOptimized),
            location,
            spacer(8),
            Controls.note("Copy + Optimize (Import mode, COPY) converts each copied clip to "
                + "MPEG-2 GOP 6 on the SD canvas, which the bitstream effects work on. The original stays the library's clip; the optimized file is "
                + "linked to it and played in its place. A missing optimized file falls back to "
                + "the original.", width: Self.noteWidth)
        ], spacing: 8)
    }

    @objc func useOptimizedChanged(_ sender: NSSwitch) {
        store.preferences.usesOptimizedMedia = sender.state == .on
    }
}
