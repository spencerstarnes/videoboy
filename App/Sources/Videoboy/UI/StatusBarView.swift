//
//  StatusBarView.swift — the status strip under the grid.
//
//  Purpose : SPEC 14.1's status bar: MIDI, OSC, node count, dropped frames and fps,
//            plus the fixed routing reminder on the right.
//  Inputs  : values pushed in by the app each second.
//  Outputs : text.
//  Connects: MIDIInput (device name), RenderLoop (fps and drops), the graph (nodes).
//  Extend  : add a field by adding a label here and a setter for it.
//

import AppKit
import VideoboyCore

/// The bottom status bar.
final class StatusBarView: NSView {

    private let midiLabel = Controls.monoLabel("MIDI: none")
    private let oscLabel = Controls.monoLabel("OSC: off")
    private let nodesLabel = Controls.monoLabel("0 nodes")
    private let rateLabel = Controls.monoLabel("drop 0 · 0.00")

    // MARK: Import progress
    //
    // Shown only while an import calls for it (`ImportProgress.showsStatusBar`: any
    // folder, more than five clips, or anything slow). It sits AFTER the readouts in the
    // row and was hidden until now, so appearing moves nothing to its left, and the
    // routing reminder stays pinned right — no control shifts under a hand.

    /// The whole import segment.
    let importSegment = NSStackView()
    private let importTitle = Controls.monoLabel("IMPORTING", color: Theme.Color.accent)
    /// The file being worked on — changes up to eight times a second while importing.
    private let importName = Controls.monoLabel("")
    /// One chip per folder: its name and clip count; the active one in the accent colour.
    private let importFolders = NSTextField(labelWithString: "")
    private let importCount = Controls.monoLabel("")
    private let importBar = NSProgressIndicator()
    private let importUnreadable = NSButton(title: "", target: nil, action: nil)
    private let importCancel = NSButton(title: "✕", target: nil, action: nil)

    // MARK: Notices
    //
    // A failed load (or any other problem the app must report) used to open a modal
    // NSAlert, which parked the main thread in `runModal` until someone clicked OK —
    // mid-show, a full freeze (BUGHUNT S6). Notices now appear here instead: one line,
    // the detail in its tooltip, gone after a while. Nothing ever waits on it. It sits
    // after the import segment and before the spacer, so appearing moves nothing to
    // its left.

    /// The notice line ("⚠ Could not load x.mov — reason").
    let noticeLabel = Controls.monoLabel("", color: Theme.Color.displayWarning)
    private var noticeHideWork: DispatchWorkItem?
    /// How long a notice stays up before it clears itself.
    static let noticeSeconds: TimeInterval = 12

    /// ✕ pressed.
    var onCancelImport: (() -> Void)?
    /// "N unreadable" pressed.
    var onShowUnreadable: (() -> Void)?

    // MARK: Mode bar (0.4.8, `FeatureFlag.modeBar`)
    //
    // Resolve's page bar, merged into this strip (proposal §4): IMPORT · VJ · SETTINGS
    // between the readouts and the routing reminder. Present only when the flag is on;
    // the strip then grows from 22 to 32 pt and nothing else in the window changes.

    /// The mode switcher, or nil when the flag is off.
    let modeSwitch: NSSegmentedControl?
    /// A segment was clicked.
    var onModeSelected: ((AppMode) -> Void)?

    /// - Parameter modeBar: show the mode switcher (the flag, unless a check says).
    init(modeBar: Bool = FeatureFlag.modeBar.isOn) {
        if modeBar {
            let control = NSSegmentedControl()
            control.segmentCount = AppMode.allCases.count
            control.trackingMode = .selectOne
            control.segmentStyle = .texturedRounded
            control.controlSize = .regular
            for mode in AppMode.allCases {
                let segment = mode.rawValue - 1
                control.setLabel(mode.title, forSegment: segment)
                control.setImage(NSImage(systemSymbolName: mode.symbolName,
                                         accessibilityDescription: mode.title), forSegment: segment)
                control.setImageScaling(.scaleProportionallyDown, forSegment: segment)
                control.setToolTip("\(mode.title.capitalized) (⌘\(mode.rawValue))", forSegment: segment)
            }
            control.selectedSegment = AppMode.vj.rawValue - 1
            control.setAccessibilityIdentifier("mode-bar")
            modeSwitch = control
        } else {
            modeSwitch = nil
        }
        super.init(frame: .zero)
        modeSwitch?.target = self
        modeSwitch?.action = #selector(modeClicked(_:))

        wantsLayer = true
        layer?.backgroundColor = Theme.Color.bar.cgColor

        // The routing reminder is fixed text: A/B always feed ONE and C/D always
        // feed TWO, and that never remaps (SPEC 2).
        let routing = Controls.label(
            "A/B → A/B Sub Mix · C/D → C/D Sub Mix · both → Program",
            font: Theme.Font.mono, color: Theme.Color.textTertiary
        )

        buildImportSegment()
        noticeLabel.isHidden = true
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noticeLabel.setAccessibilityIdentifier("status-notice")
        var items: [NSView] = [midiLabel, oscLabel, nodesLabel, rateLabel, importSegment, noticeLabel,
                               Controls.spacer()]
        if let modeSwitch { items.append(modeSwitch) }
        items.append(routing)
        let row = Controls.row(items, spacing: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(modeBar: FeatureFlag.modeBar.isOn)
        frame = frameRect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    @objc private func modeClicked(_ sender: NSSegmentedControl) {
        guard let mode = AppMode(rawValue: sender.selectedSegment + 1) else { return }
        onModeSelected?(mode)
    }

    /// Shows which mode is current (the menu or a key may have changed it).
    func setMode(_ mode: AppMode) {
        modeSwitch?.selectedSegment = mode.rawValue - 1
    }

    /// Shows the connected MIDI source, or "none".
    func setMIDIDevice(_ name: String?) {
        midiLabel.stringValue = "MIDI: \(name ?? "none")"
    }

    /// Shows the live node count of the render graph.
    func setNodeCount(_ count: Int) {
        nodesLabel.stringValue = "\(count) nodes"
    }

    private func buildImportSegment() {
        Self.prepareSymbols()
        importSegment.orientation = .horizontal
        importSegment.spacing = 8
        importSegment.isHidden = true
        importSegment.setAccessibilityIdentifier("import-status")
        importName.lineBreakMode = .byTruncatingMiddle
        importName.widthAnchor.constraint(equalToConstant: Theme.Metrics.importNameWidth).isActive = true
        importFolders.font = Theme.Font.mono
        importFolders.lineBreakMode = .byTruncatingTail
        importFolders.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        importBar.style = .bar
        importBar.controlSize = .small
        importBar.isIndeterminate = false
        importBar.minValue = 0
        importBar.widthAnchor.constraint(equalToConstant: Theme.Metrics.importBarWidth).isActive = true
        for button in [importUnreadable, importCancel] {
            button.isBordered = false
            button.font = Theme.Font.mono
            button.target = self
        }
        importUnreadable.contentTintColor = Theme.Color.displayWarning
        importUnreadable.action = #selector(unreadablePressed)
        importUnreadable.isHidden = true
        importUnreadable.setAccessibilityIdentifier("import-unreadable")
        importCancel.action = #selector(cancelPressed)
        importCancel.toolTip = "Stop importing. Clips already added stay in the library."
        importCancel.setAccessibilityIdentifier("import-cancel")
        for view in [importTitle, importName, importFolders, importCount, importBar,
                     importUnreadable, importCancel] as [NSView] {
            importSegment.addArrangedSubview(view)
        }
    }

    @objc private func cancelPressed() { onCancelImport?() }
    @objc private func unreadablePressed() { onShowUnreadable?() }

    /// Shows an import's progress — or hides the segment while the import is too small
    /// to be worth a word.
    func showImport(_ progress: ImportProgress) {
        guard progress.showsStatusBar else { return }
        importSegment.isHidden = false
        let total = max(progress.found, 1)
        switch progress.stage {
        case .transferring:
            importTitle.attributedStringValue = Self.title("square.and.arrow.down", progress.transferLabel, Theme.Color.accent)
            importCount.stringValue = "\(progress.read) / \(progress.found)"
            importBar.stopAnimation(nil)
            importBar.isIndeterminate = false
            importBar.maxValue = Double(total)
            importBar.doubleValue = Double(progress.read)
        case .scanning:
            importTitle.attributedStringValue = Self.title("square.and.arrow.down", "IMPORTING", Theme.Color.accent)
            importCount.stringValue = "\(progress.found) found"
            importBar.isIndeterminate = true
            importBar.startAnimation(nil)
        case .reading:
            importTitle.attributedStringValue = Self.title("square.and.arrow.down", "IMPORTING", Theme.Color.accent)
            importCount.stringValue = "\(progress.read) / \(progress.found)"
            importBar.stopAnimation(nil)
            importBar.isIndeterminate = false
            importBar.maxValue = Double(total)
            importBar.doubleValue = Double(progress.read)
        case .finished, .cancelled:
            importTitle.attributedStringValue = progress.stage == .finished
                ? Self.title("checkmark.circle", "IMPORTED", Theme.Color.accent)
                : Self.title("xmark.circle", "STOPPED", Theme.Color.displayWarning)
            importCount.stringValue = "\(progress.added) added"
            importBar.stopAnimation(nil)
            importBar.isIndeterminate = false
            importBar.maxValue = Double(total)
            importBar.doubleValue = progress.stage == .finished ? Double(total) : Double(progress.read)
        }
        importName.stringValue = progress.current ?? ""
        importFolders.attributedStringValue = Self.folderChips(progress)
        importUnreadable.title = "\(progress.unreadable.count) unreadable"
        importUnreadable.isHidden = progress.unreadable.isEmpty
        importCancel.isHidden = progress.isFinished
    }

    /// Takes the segment away.
    func hideImport() {
        importBar.stopAnimation(nil)
        importSegment.isHidden = true
    }

    /// What the import segment currently says, for self-QA.
    var importTextForChecks: String {
        [importTitle, importName, importFolders, importCount].map(\.stringValue).joined(separator: " | ")
    }

    /// SF Symbol images, made once. Loading them the first time an import showed cost
    /// most of a ~96 ms stall at the start of a big import (measured, 0.4.7); they are
    /// made when the status bar is built instead, before anything is on air.
    private static var symbols: [String: NSImage] = [:]

    private static func symbolImage(_ name: String, _ colour: NSColor?) -> NSImage? {
        let key = name + (colour.map { "|\($0)" } ?? "")
        if let cached = symbols[key] { return cached }
        var image = NSImage(systemSymbolName: name, accessibilityDescription: name)
        if let colour { image = image?.withSymbolConfiguration(.init(paletteColors: [colour])) }
        symbols[key] = image
        return image
    }

    /// Makes every symbol the import segment uses, so its first appearance costs nothing.
    private static func prepareSymbols() {
        _ = symbolImage("square.and.arrow.down", Theme.Color.accent)
        _ = symbolImage("checkmark.circle", Theme.Color.accent)
        _ = symbolImage("xmark.circle", Theme.Color.displayWarning)
        _ = symbolImage("folder.fill", nil)
    }

    /// An SF Symbol and a word, in one colour: the segment's title.
    private static func title(_ symbol: String, _ word: String, _ colour: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let attachment = NSTextAttachment()
        attachment.image = symbolImage(symbol, colour)
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: " \(word)",
                                       attributes: [.font: Theme.Font.mono, .foregroundColor: colour]))
        return text
    }

    /// "▣ Reel B 48  ▣ Reel C 12", the active folder in the accent colour. With more
    /// folders than fit, the ACTIVE folder keeps its chip and count and the rest are
    /// summed — "▣ Reel 07 40  +24 folders" — so it always says which folder is being
    /// read and how many clips are in it.
    private static func folderChips(_ progress: ImportProgress) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let font = Theme.Font.mono
        func chip(_ label: String, active: Bool) {
            let attachment = NSTextAttachment()
            attachment.image = symbolImage("folder.fill", nil)
            let colour = active ? Theme.Color.accent : Theme.Color.textSecondary
            if text.length > 0 { text.append(NSAttributedString(string: "  ")) }
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " \(label)",
                                           attributes: [.font: font, .foregroundColor: colour]))
        }
        if progress.folders.count > Theme.Metrics.importFolderChips {
            if let active = progress.folders.first(where: { $0.name == progress.activeFolder })
                ?? progress.folders.last {
                chip("\(active.name) \(active.count)", active: true)
            }
            text.append(NSAttributedString(
                string: "  +\(progress.folders.count - 1) folders",
                attributes: [.font: font, .foregroundColor: Theme.Color.textTertiary]))
        } else {
            for folder in progress.folders {
                chip("\(folder.name) \(folder.count)", active: folder.name == progress.activeFolder)
            }
        }
        return text
    }

    /// Shows a notice without blocking anything. The detail is the tooltip and is also
    /// logged by the caller. Replaces any earlier notice; clears itself after
    /// `noticeSeconds`.
    /// - Parameter isWarning: false for information (ADV improvised, as told to) —
    ///   red/amber stays for real problems.
    func showNotice(_ title: String, detail: String, isWarning: Bool = true) {
        noticeLabel.stringValue = isWarning ? "⚠ \(title)" : title
        noticeLabel.textColor = isWarning ? Theme.Color.displayWarning : Theme.Color.textSecondary
        noticeLabel.toolTip = detail
        noticeLabel.isHidden = false
        noticeHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.noticeLabel.isHidden = true }
        noticeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeSeconds, execute: work)
    }

    /// The notice on show, or nil — for self-QA.
    var noticeTextForChecks: String? {
        noticeLabel.isHidden ? nil : noticeLabel.stringValue
    }

    /// Shows dropped frames and the measured render rate.
    func setRate(droppedFrames: Int, framesPerSecond: Double) {
        rateLabel.stringValue = String(format: "drop %d · %.2f", droppedFrames, framesPerSecond)
    }
}
