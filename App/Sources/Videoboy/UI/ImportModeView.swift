//
//  ImportModeView.swift — Import mode (proposal §5).
//
//  Purpose : The Lightroom-model import window. In 0.4.8 it is the frame only:
//            the three columns with their real controls present and disabled, and a
//            line saying what arrives in 0.4.9 — never an empty page.
//  Inputs  : none yet.
//  Outputs : none yet.
//  Connects: ModeController (shown in the grid's place).
//  Extend  : 0.4.9 fills the sources sidebar, media grid, viewer and Add/Move/Copy.
//

import AppKit
import VideoboyCore

/// Import mode's view.
final class ImportModeView: NSView {

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.content.cgColor

        let title = Controls.label("Import", font: Theme.Font.panelTitle, color: Theme.Color.textPrimary)
        let method = Controls.segmented(["ADD", "MOVE", "COPY"], selected: 0, enabled: false)
        let importButton = Controls.button("Import", enabled: false)
        let note = Controls.note(
            "Import mode arrives in 0.4.9: sources, a media grid with hover-scrub, a viewer, "
            + "and Add / Move / Copy. Until then use File ▸ Import Clips… (⇧⌘I) or drop "
            + "files on the library.", width: 420)
        let column = Controls.column([title, method, importButton, note], spacing: 12)
        column.alignment = .centerX
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityIdentifier("import-mode")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }
}
