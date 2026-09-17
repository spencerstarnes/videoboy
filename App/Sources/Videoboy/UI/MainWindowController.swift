//
//  MainWindowController.swift — the one window.
//
//  Purpose : Owns the single main window and its content. SPEC 14.4 is explicit that
//            panels are docked, collapsible and never movable, so there is exactly
//            one window controller and no floating-panel machinery anywhere.
//  Inputs  : none yet; later phases hand it a graph to display.
//  Outputs : a visible, resizable window holding the canonical shell.
//  Connects: ShellView (the 5x5 grid), Theme (all geometry and colour).
//  Extend  : content belongs in ShellView and its panels, not here. This file should
//            stay about the window itself.
//

import AppKit
import VideoboyCore

/// Creates and owns the main window.
final class MainWindowController: NSWindowController {

    /// The running instrument this window drives.
    let engine = Engine()

    /// Settings that outlive a patch, handed down from the app delegate so there is
    /// one store rather than one per window.
    let preferences: PreferenceStore

    /// Keeps the views and the engine connected for the window's lifetime.
    /// Exposed so the app delegate can make first-run offers that touch routing.
    private(set) var shellController: ShellController?

    /// Builds the window at a size that shows the full wide layout on first run.
    init(preferences: PreferenceStore) {
        self.preferences = preferences
        let initialSize = NSSize(width: 1460, height: 912)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Videoboy"
        window.subtitle = "untitled.vbt"
        // SPEC 14.4: below this the layout drops to its narrow state rather than
        // clipping, so the window must not be allowed to shrink past it.
        window.minSize = NSSize(
            width: Theme.Breakpoint.minimumWindowWidth,
            height: Theme.Breakpoint.minimumWindowHeight
        )
        window.titlebarAppearsTransparent = false
        window.backgroundColor = Theme.Color.content
        // The instrument is a dark surface regardless of the system setting: the
        // amber/cyan bus identity only reads correctly against dark chrome.
        window.appearance = NSAppearance(named: .darkAqua)

        // Full screen is OFF until the layout is settled. The grid is built for a
        // window with a title bar, and in full screen the toolbar goes under the
        // menu bar and there is no reliable way back with the pointer — you end up
        // trapped in a window you cannot leave. A feature you cannot get out of is
        // worse than one you cannot get into, so both the green button and the menu
        // item are disabled rather than left half-working.
        window.collectionBehavior.insert(.fullScreenNone)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.center()
        window.setFrameAutosaveName("VideoboyMainWindow")

        super.init(window: window)

        let shell = ShellView()
        window.contentView = shell
        shellController = ShellController(shell: shell, engine: engine, preferences: preferences)
        // The render clock follows the display this window is on, so moving the
        // window between screens retimes it automatically (SPEC 4a).
        engine.start(drivenBy: shell)

        Log.info(.app, "main window built at \(Int(initialSize.width))x\(Int(initialSize.height))")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code, never from a nib")
    }
}
