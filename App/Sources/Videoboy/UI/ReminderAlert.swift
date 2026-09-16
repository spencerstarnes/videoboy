//
//  ReminderAlert.swift — a prompt you can turn off for good.
//
//  Purpose : Some things genuinely need saying once — that no save location has been
//            chosen, that there are unsaved changes, that a mapping has been made to
//            something that is not running. Saying them EVERY time turns a useful
//            warning into a thing people click through without reading, which is
//            worse than not warning at all. Each of these carries a "Don't remind me
//            again" box, and the answer is remembered.
//  Inputs  : a ReminderKind, the text, and the PreferenceStore that remembers.
//  Outputs : which button was pressed; the suppression is recorded here so no caller
//            can forget to.
//  Connects: PreferenceStore (which remembers), the Defaults pane (which un-forgets
//            them all), AppDelegate and ShellController (which ask).
//  Extend  : add a case to `ReminderKind` in Core, then call this. Do NOT add a
//            prompt that cannot be switched off — the whole point is that every one
//            of these is escapable.
//

import AppKit
import VideoboyCore

/// Prompts that remember being dismissed.
enum ReminderAlert {

    /// What the person chose.
    enum Response {
        /// The first (default) button.
        case primary
        /// The second button.
        case secondary
        /// The third button, when there is one.
        case tertiary
        /// The prompt was suppressed, so it was never shown.
        case notShown
    }

    /// Shows a reminder unless it has been turned off.
    ///
    /// Returns `.notShown` when it is suppressed, which callers must treat as "carry
    /// on" rather than as a refusal — a suppressed prompt means the person already
    /// decided, not that they said no.
    @discardableResult
    static func show(
        _ kind: ReminderKind,
        store: PreferenceStore,
        title: String,
        detail: String,
        buttons: [String],
        style: NSAlert.Style = .informational
    ) -> Response {
        guard store.shouldRemind(kind) else {
            Log.info(.app, "reminder '\(kind.rawValue)' is suppressed; not shown")
            return .notShown
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = style
        for button in buttons { alert.addButton(withTitle: button) }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't remind me again"

        let response = alert.runModal()

        // Recorded here rather than by each caller: a prompt whose suppression box
        // does nothing is a worse lie than having no box at all.
        if alert.suppressionButton?.state == .on {
            store.suppressReminder(kind)
        }

        switch response {
        case .alertFirstButtonReturn: return .primary
        case .alertSecondButtonReturn: return .secondary
        default: return .tertiary
        }
    }
}
