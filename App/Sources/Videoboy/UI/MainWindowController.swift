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

    /// Builds the window at a size that shows the full wide layout on first run.
    init() {
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
        window.center()
        window.setFrameAutosaveName("VideoboyMainWindow")

        super.init(window: window)

        window.contentView = ShellView()
        Log.info(.app, "main window built at \(Int(initialSize.width))x\(Int(initialSize.height))")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code, never from a nib")
    }
}
