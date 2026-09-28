//
//  PreferencesWindowController.swift — the settings window.
//
//  Purpose : Everything that outlives one patch — where work is saved, what a new
//            source defaults to, which destinations exist, which reminders have been
//            turned off, what the hardware is mapped to. A template describes one
//            performance; this describes the instrument.
//  Inputs  : a PreferenceStore (the settings) and an Engine (what is connected right
//            now, which is not a setting and must not be written to the file).
//  Outputs : edits written straight through the store, which saves on every change.
//  Connects: ShellController (which opens it), PreferenceStore, MIDIInput.
//  Extend  : add a `Pane` case and a builder for it. Panes are built lazily on first
//            selection, so a pane that has to ask the system something expensive does
//            not slow the window opening.
//
//  On the layout: thick tabs down the left, settings on the right, as macOS has done
//  since Ventura. No OK/Cancel — changes apply as they are made, which is what every
//  settings window on this platform does and what people expect.
//

import AppKit
import VideoboyCore

/// The Preferences window.
final class PreferencesWindowController: NSWindowController {

    /// The panes, in the order they appear down the left.
    enum Pane: String, CaseIterable {
        case project
        case media
        case optimize
        case save
        case defaults
        case outputs
        case dataBurn
        case inputs
        case hotKeys
        case midiMapping
        case emu
        case macros
        case shaders

        var title: String {
            switch self {
            case .project: "Project"
            case .media: "Media"
            case .optimize: "Optimize"
            case .save: "Save"
            case .defaults: "Defaults"
            case .outputs: "Outputs"
            case .dataBurn: "Data Burn"
            case .inputs: "Sources"
            case .hotKeys: "Hot Keys"
            case .midiMapping: "MIDI Mapping"
            case .emu: "EMU"
            case .macros: "Macros & AI"
            case .shaders: "Shaders"
            }
        }

        var symbolName: String {
            switch self {
            case .project: "rectangle.on.rectangle"
            case .media: "folder"
            case .optimize: "speedometer"
            case .save: "externaldrive"
            case .defaults: "slider.horizontal.3"
            case .outputs: "tv"
            case .dataBurn: "textformat"
            case .inputs: "cable.connector"
            case .hotKeys: "keyboard"
            case .midiMapping: "pianokeys"
            case .emu: "gamecontroller"
            case .macros: "wand.and.stars"
            case .shaders: "camera.filters"
            }
        }

        /// One line under the pane's heading saying what it is for.
        var summary: String {
            switch self {
            case .project: "The canvas and frame rate everything is mixed at."
            case .media: "Where the library, imported clips and optimized media live."
            case .optimize: "What Copy + Optimize turns clips into."
            case .save: "Where your work goes, and how often it gets there by itself."
            case .defaults: "What a new source, bus and session start out as."
            case .outputs: "Where PROGRAM and the buses can be sent."
            case .dataBurn: "How FILE and TC text looks on the monitors, and when DATA BURN "
                + "puts it into a sub-mix."
            case .inputs: "MIDI, and every camera, window, IP camera or deck available "
                + "to a channel."
            case .hotKeys: "Keys for the things you reach for mid-set."
            case .midiMapping: "Every control currently bound to a controller."
            case .emu: "Emulated machines, and the cores, ROMs and discs they need."
            case .macros: "Sequences of commands, and letting a model drive them."
            case .shaders: "ISF shader modules. Importing keeps a copy inside Videoboy."
            }
        }
    }

    let store: PreferenceStore
    unowned let engine: Engine

    // Controls the panes reach back to when their underlying value changes elsewhere.
    // Held here rather than in the extension because only a class can own storage.
    var savedPathLabel: NSTextField?
    var reminderCountLabel: NSTextField?
    var destinationList: DestinationListView?
    var sourceList: SourceListView?
    var shaderList: ISFModuleListView?
    /// The Data Burn pane's sample line, redrawn whenever the style changes.
    var dataBurnSample: NSView?
    /// Builds the Shaders pane's list. Replaced by the self-QA so it scans and imports
    /// into temporary folders, never the operator's own ISF library.
    var makeShaderList: () -> ISFModuleListView = { ISFModuleListView() }

    /// Called when the picture fill changes, so open previews follow immediately
    /// rather than at the next relaunch.
    var onPreviewFillChanged: ((PreviewFill) -> Void)?
    /// MIDI mappings were removed here, so the main window re-reads what is driven.
    var onMappingsChanged: (() -> Void)?
    /// "Run Setup Assistant…" pressed (Project pane).
    var onRunSetupAssistant: (() -> Void)?

    /// Everything the controller draws. The window's content in the Preferences window;
    /// lifted out whole into Settings mode when the mode bar is on (0.4.8).
    let rootView = NSView()

    private var selected: Pane = .save
    private var tabButtons: [Pane: NSButton] = [:]
    private let detail = FlippedView()
    private var builtPanes: [Pane: NSView] = [:]

    init(store: PreferenceStore, engine: Engine) {
        self.store = store
        self.engine = engine

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Videoboy Preferences"
        window.isReleasedWhenClosed = false
        // Same appearance as the main window. Every colour in Theme is defined
        // against a dark background — left in the system appearance this window
        // renders white-on-white and is simply unreadable.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.Color.content
        window.center()
        window.contentView = rootView
        super.init(window: window)
        buildLayout()
        select(.save)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    // MARK: - Layout

    private func buildLayout() {
        let content = rootView
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.Color.content.cgColor

        let sidebar = FlippedView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = Theme.Color.panelFillNested.cgColor

        var previous: NSView?
        for pane in Pane.allCases {
            let button = makeTabButton(for: pane)
            sidebar.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
                button.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
                button.heightAnchor.constraint(equalToConstant: 34),
                button.topAnchor.constraint(
                    equalTo: previous?.bottomAnchor ?? sidebar.topAnchor,
                    constant: previous == nil ? 14 : 2)
            ])
            previous = button
            tabButtons[pane] = button
        }

        detail.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)
        content.addSubview(detail)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 186),

            detail.topAnchor.constraint(equalTo: content.topAnchor),
            detail.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
    }

    private func makeTabButton(for pane: Pane) -> NSButton {
        let button = NSButton(title: "  " + pane.title, target: self, action: #selector(tabClicked(_:)))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .inline
        button.isBordered = false
        button.alignment = .left
        button.font = Theme.Font.label
        button.image = NSImage(
            systemSymbolName: pane.symbolName, accessibilityDescription: pane.title)
        button.imagePosition = .imageLeading
        button.identifier = NSUserInterfaceItemIdentifier(pane.rawValue)
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        return button
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let pane = Pane(rawValue: raw) else { return }
        select(pane)
    }

    /// Shows a pane, building it the first time it is asked for.
    func select(_ pane: Pane) {
        selected = pane
        for (candidate, button) in tabButtons {
            let isSelected = candidate == pane
            button.layer?.backgroundColor = isSelected
                ? Theme.Color.accent.withAlphaComponent(0.85).cgColor
                : NSColor.clear.cgColor
            button.contentTintColor = isSelected ? .white : Theme.Color.textSecondary
        }

        detail.subviews.forEach { $0.removeFromSuperview() }
        let view = builtPanes[pane] ?? makePane(pane)
        builtPanes[pane] = view
        view.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: detail.topAnchor, constant: 18),
            view.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 20),
            view.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -20),
            view.bottomAnchor.constraint(lessThanOrEqualTo: detail.bottomAnchor, constant: -18)
        ])
    }

    /// Lifts the settings out of the window so Settings mode can show them (the window
    /// is then never shown). Call once.
    func detachRootViewForEmbedding() -> NSView {
        window?.contentView = NSView()
        rootView.removeFromSuperview()
        return rootView
    }

    /// Which pane is showing, for self-QA.
    var selectedPaneForChecks: Pane { selected }
    /// The tab buttons, for self-QA.
    var tabButtonsForChecks: [Pane: NSButton] { tabButtons }

    /// Throws away a built pane so it is made afresh next time it is shown.
    ///
    /// Used when a pane's content is a list of something that has just changed. The
    /// alternative is every pane maintaining a live binding to what it displays,
    /// which is a lot of machinery for a window that is open for a few seconds.
    func rebuildPane(_ pane: Pane) {
        builtPanes[pane] = nil
        if selected == pane { select(pane) }
    }

    /// The heading every pane opens with.
    func header(_ pane: Pane) -> NSView {
        let title = Controls.label(pane.title, font: Theme.Font.panelTitle,
                                   color: Theme.Color.textPrimary)
        let summary = Controls.label(pane.summary, font: Theme.Font.tinyLabel,
                                     color: Theme.Color.textTertiary)
        return Controls.column([title, summary], spacing: 3)
    }

    /// A labelled row: caption on the left at a fixed width, control on the right.
    func field(_ caption: String, _ control: NSView) -> NSView {
        let label = Controls.label(caption, color: Theme.Color.textSecondary)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 132).isActive = true
        return Controls.row([label, control, Controls.spacer()], spacing: 10)
    }

    func makePane(_ pane: Pane) -> NSView {
        switch pane {
        case .project: makeProjectPane()
        case .media: makeMediaPane()
        case .optimize: makeOptimizePane()
        case .save: makeSavePane()
        case .defaults: makeDefaultsPane()
        case .outputs: makeOutputsPane()
        case .dataBurn: makeDataBurnPane()
        case .inputs: makeInputsPane()
        case .hotKeys: makeHotKeysPane()
        case .midiMapping: makeMIDIMappingPane()
        case .emu: makeEmuPane()
        case .macros: makeMacrosPane()
        case .shaders: makeShadersPane()
        }
    }
}
