//
//  BinHeadingField.swift — a bin's name, which is also how you rename it.
//
//  Purpose : Bins are created empty and named in place, the way Premiere and Resolve
//            do it: the bin appears, its name is selected, you type. Renaming later is
//            a double-click on the same text.
//  Inputs   : double-clicks, and `beginRename()` from whatever just made the bin.
//  Outputs  : `onRenamed`, with the old and new names.
//  Connects : LibraryPanelBody, which owns the bins.
//  Extend   : anything else in the library that has a name people change belongs on
//            this control rather than in another dialogue.
//
//  ── WHY NOT A DIALOGUE ──────────────────────────────────────────────────────────
//
//  Making a bin used to open a modal alert asking for a name. Two problems with that.
//  It puts a decision in front of an action that has no consequences — a bin is a
//  folder, you can rename it in a second — and it means you cannot make three bins
//  without answering three dialogues. Every editing application settled on the same
//  answer decades ago: make the thing, select its name, let the person type or not.
//
//  Editing is OFF except while renaming. An always-editable heading takes the caret on
//  a stray click, and a list of headings that can each swallow a click is a list that
//  feels unsafe to point at.
//

import AppKit

/// A bin's name, editable in place.
final class BinHeadingField: NSTextField {

    /// Called when the name changes. Old name first, so the caller can move the items.
    var onRenamed: ((String, String) -> Void)?

    private var nameBeforeEditing = ""

    init(name: String) {
        super.init(frame: .zero)
        stringValue = name.uppercased()
        nameBeforeEditing = name

        font = Theme.Font.tinyLabel
        textColor = Theme.Color.textTertiary
        isBordered = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Bin · double-click to rename · right-click an item to move it here"
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount >= 2 else {
            super.mouseDown(with: event)
            return
        }
        beginRename()
    }

    /// Puts the name into edit mode with all of it selected, ready to be typed over.
    ///
    /// Selected rather than with a caret at the end: a bin called "Bin 2" that you have
    /// just made is a placeholder, and the useful thing is to replace it, not to append
    /// to it.
    func beginRename() {
        nameBeforeEditing = stringValue
        isEditable = true
        isSelectable = true
        drawsBackground = true
        backgroundColor = Theme.Color.panelFillNested
        textColor = Theme.Color.textPrimary
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    private func endRename() {
        isEditable = false
        isSelectable = false
        drawsBackground = false
        textColor = Theme.Color.textTertiary

        let trimmed = stringValue.trimmingCharacters(in: .whitespaces)
        // An empty name puts the old one back rather than leaving a nameless bin —
        // there is no useful thing a blank heading could mean.
        guard !trimmed.isEmpty else {
            stringValue = nameBeforeEditing
            return
        }
        let new = trimmed.uppercased()
        stringValue = new
        guard new != nameBeforeEditing else { return }
        onRenamed?(nameBeforeEditing, new)
    }
}

extension BinHeadingField: NSTextFieldDelegate {
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
