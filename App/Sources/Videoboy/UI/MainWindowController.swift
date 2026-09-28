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
    let engine: Engine

    /// Settings that outlive a patch, handed down from the app delegate so there is
    /// one store rather than one per window.
    let preferences: PreferenceStore

    /// Keeps the views and the engine connected for the window's lifetime.
    /// Exposed so the app delegate can make first-run offers that touch routing.
    private(set) var shellController: ShellController?

    /// Import · VJ · Settings (0.4.8), or nil when the mode bar is off.
    private(set) var modeController: ModeController?

    /// How big to open on first run, measured against the display rather than fixed.
    ///
    /// This was pinned at 1460x912 on every machine. That is not merely conservative
    /// on a large display — it makes the previews small as a matter of ARITHMETIC.
    /// A preview panel's height is derived from its column's width so it comes out
    /// 4:3, and column width is a fraction of the window, so a window that declines
    /// to use the screen produces video windows that cannot be any bigger no matter
    /// what the grid weights say. The instrument should open at the size of the desk
    /// it is sitting on.
    ///
    /// Capped, because past a point more width stops buying picture and starts
    /// buying whitespace — and on a very wide display a window spanning the whole
    /// desktop is worse to work at, not better.
    static func initialSize(for screen: NSScreen?) -> NSSize {
        guard let visible = screen?.visibleFrame else {
            return NSSize(width: 1460, height: 912)
        }
        let width = min(max(visible.width * 0.92, Theme.Breakpoint.minimumWindowWidth), 2600)
        let height = min(max(visible.height * 0.92, Theme.Breakpoint.minimumWindowHeight), 1600)
        return NSSize(width: floor(width), height: floor(height))
    }

    /// Fits a restored frame onto the screen it mostly sits on.
    ///
    /// The autosaved frame is whatever the LAST display arrangement allowed. After a
    /// display is added, removed or rearranged it can come back mostly off-screen —
    /// observed at y=753 with a 998-pt window on a 1080-pt display, title bar reachable
    /// but the instrument below the edge. AppKit only guarantees a sliver stays visible.
    static func keepOnScreen(_ window: NSWindow) {
        let frame = window.frame
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.visibleFrame.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        let best = NSScreen.screens.max { overlap($0) < overlap($1) }
        guard let visible = (best ?? NSScreen.main)?.visibleFrame else { return }
        guard !visible.contains(frame) else { return }
        var fitted = frame
        fitted.size.width = max(min(frame.width, visible.width), window.minSize.width)
        fitted.size.height = max(min(frame.height, visible.height), window.minSize.height)
        fitted.origin.x = min(max(frame.minX, visible.minX), visible.maxX - fitted.width)
        fitted.origin.y = min(max(frame.minY, visible.minY), visible.maxY - fitted.height)
        window.setFrame(fitted, display: false)
        Log.info(.app, "restored window frame was off-screen; fitted to \(visible)")
    }

    /// Builds the window at a size that shows the full wide layout on first run.
    /// - Parameter engine: normally a fresh one; the self-QA passes one whose module
    ///   catalogue points at temporary ISF folders.
    init(preferences: PreferenceStore, engine: Engine = Engine()) {
        self.engine = engine
        self.preferences = preferences
        let initialSize = Self.initialSize(for: NSScreen.main)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Videoboy \(Videoboy.version)"
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

        // Full screen is OFF. The grid is built for a window with a title bar, and in
        // full screen the toolbar goes under the menu bar with no reliable way back
        // with the pointer — you end up trapped in a window you cannot leave.
        //
        // MAXIMISE is a different thing and it stays. With `.fullScreenNone` set the
        // green button is already a zoom button rather than a full-screen one, so
        // disabling it took maximise away as collateral damage rather than by
        // intent — and double-clicking the title bar, which routes to the same zoom,
        // went with it. Zoom keeps the title bar, keeps the pointer, and is
        // reversible by clicking the same button again.
        window.collectionBehavior.insert(.fullScreenNone)
        window.center()
        window.setFrameAutosaveName("VideoboyMainWindow")
        Self.keepOnScreen(window)

        super.init(window: window)
        window.delegate = self

        let shell = ShellView()
        window.contentView = shell
        shellController = ShellController(shell: shell, engine: engine, preferences: preferences)
        if shell.hasModeBar {
            let modes = ModeController(shell: shell, store: preferences, engine: engine)
            modes.onPreviewFillChanged = { [weak self] fill in
                self?.shellController?.setPreviewFill(fill)
            }
            modes.onRunSetupAssistant = { [weak self] in self?.runSetupAssistant() }
            modes.onImport = { [weak self] urls, method, destination, bin, root, optimize in
                self?.shellController?.importFiles(urls, method: method, destination: destination, root: root,
                                                   bin: bin, optimize: optimize)
            }
            modeController = modes
        }
        // The render clock follows the display this window is on, so moving the
        // window between screens retimes it automatically (SPEC 4a).
        engine.start(drivenBy: shell)
        shellController?.rememberLaunchState()
        shellController?.onTemplateURLChanged = { [weak window] url in
            window?.subtitle = url?.lastPathComponent ?? "untitled.vbt"
        }

        Log.info(.app, "main window built at \(Int(initialSize.width))x\(Int(initialSize.height))")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code, never from a nib")
    }

    /// The assistant currently showing, held so the sheet outlives this call.
    private(set) var setupAssistant: SetupAssistant?

    /// Shows the setup assistant as a sheet on this window (proposal §8).
    /// - Parameter then: runs after the assistant closes — first-launch prompts wait
    ///   for it, so no alert lands on top of the sheet (seen in the real app).
    func runSetupAssistant(then: (() -> Void)? = nil) {
        guard let window, setupAssistant == nil else { return }
        let assistant = SetupAssistant(store: preferences)
        assistant.onFinish = { [weak self] openImport in
            self?.setupAssistant = nil
            then?()
            if openImport { self?.modeController?.show(.importMedia) }
        }
        setupAssistant = assistant
        assistant.present(on: window)
    }
}

// MARK: - Zooming

extension MainWindowController: NSWindowDelegate {

    /// What "zoom" means for this window: the whole visible screen.
    ///
    /// AppKit's default standard frame is a best-fit around the content, which for a
    /// grid that will happily fill any size is an arbitrary rectangle rather than
    /// "maximised". Returning the visible frame makes the green button, the Window ▸
    /// Zoom menu item and a double-click on the title bar all do the obvious thing.
    ///
    /// `visibleFrame` rather than `frame`, so the Dock and the menu bar keep their
    /// space — this is maximise, not full screen.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? defaultFrame
    }
}
