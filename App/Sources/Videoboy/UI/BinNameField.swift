//
//  BinNameField.swift — a bin's name under its folder icon, which is also how you
//  rename it.
//
//  Purpose : Bins are created and named in place, the way the Finder does it: the
//            folder appears, its name is selected, you type. Renaming later is the
//            same: choose Rename from the right-click menu, or double-click the name
//            of a bin that is already selected.
//  Inputs   : `beginRename()`, and clicks on the name.
//  Outputs  : `onRenamed`, with the old and new names.
//  Connects : LibraryFolderView, which owns one.
//  Extend   : anything else in the library that has a name people change belongs on
//             this control rather than in another dialogue.
//
//  ── WHY NOT A DIALOGUE ──────────────────────────────────────────────────────────
//
//  Making a bin used to open a modal alert asking for a name. It put a decision in
//  front of an action with no consequences, and made three bins cost three dialogues.
//
//  Editing is OFF except while renaming. An always-editable name takes the caret on a
//  stray click, and a grid whose captions each swallow a click feels unsafe to point at.
//

import AppKit

/// A bin's name, editable in place.
final class BinNameField: NSTextField {

    /// Called when the name changes. Old name first, so the caller can move the items.
    var onRenamed: ((String, String) -> Void)?

    /// Drawn on an accent pill, as a selected icon's name is in the Finder.
    var isHighlightedForSelection = false {
        didSet { if !isEditable { applyRestingLook() } }
    }

    private var nameBeforeEditing = ""

    init() {
        super.init(frame: .zero)
        font = Theme.Font.tinyLabel
        alignment = .center
        isBordered = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        focusRingType = .none
        lineBreakMode = .byTruncatingMiddle
        cell?.usesSingleLineMode = true
        wantsLayer = true
        layer?.cornerRadius = 3
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        delegate = self
        applyRestingLook()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Shows a name, unless it is being edited — a library change arriving mid-rename
    /// must not throw away what is being typed.
    func setName(_ name: String) {
        guard !isEditable else { return }
        stringValue = name
        nameBeforeEditing = name
    }

    /// While not editing, a press belongs to the folder cell underneath (select, open,
    /// drag), exactly as a press on a clip's caption does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isEditable ? super.hitTest(point) : nil
    }

    /// Puts the name into edit mode with all of it selected, ready to be typed over.
    func beginRename() {
        guard window != nil else { return }
        nameBeforeEditing = stringValue
        isEditable = true
        isSelectable = true
        drawsBackground = true
        backgroundColor = Theme.Color.panelFillOpaque
        textColor = Theme.Color.textPrimary
        layer?.backgroundColor = nil
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    /// True while the name is being typed.
    var isRenaming: Bool { isEditable }

    private func endRename() {
        isEditable = false
        isSelectable = false
        drawsBackground = false
        applyRestingLook()

        let trimmed = stringValue.trimmingCharacters(in: .whitespaces)
        // An empty name puts the old one back rather than leaving a nameless bin.
        guard !trimmed.isEmpty else {
            stringValue = nameBeforeEditing
            return
        }
        stringValue = trimmed
        guard trimmed != nameBeforeEditing else { return }
        let old = nameBeforeEditing
        nameBeforeEditing = trimmed
        onRenamed?(old, trimmed)
    }

    private func applyRestingLook() {
        textColor = isHighlightedForSelection ? .white : Theme.Color.textSecondary
        layer?.backgroundColor = isHighlightedForSelection ? Theme.Color.accent.cgColor : nil
    }
}

extension BinNameField: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        endRename()
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        // Escape abandons the rename. Without it the only way out of an edit you did
        // not mean to start is to type the old name back from memory.
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            stringValue = nameBeforeEditing
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}
