//
//  OutputWindowController.swift — the borderless program window on the HDMI card.
//
//  Purpose : SPEC 3. An HDMI adapter is an external display, so sending PRIMARY to
//            the card means putting a borderless, full-screen window on that screen
//            with the program texture in it.
//  Inputs   : a display to present on, and a texture per frame.
//  Outputs  : the actual analog-facing signal, once the HDMI-to-RCA converter has it.
//  Connects : DisplayRouter (which display, and what mode it negotiated), Engine
//             (which hands it PRIMARY each frame), MetalPreviewView (the drawing).
//  Extend   : routing ONE and TWO to their own displays means more instances of this,
//             not more modes inside it.
//

import AppKit
import Metal
import VideoboyCore

/// A borderless window showing one bus on one display.
final class OutputWindowController: NSWindowController {

    /// The display this window is on.
    let display: DisplayInfo
    /// The mode that was actually negotiated, for the settings bar and metrics.json.
    let negotiatedMode: String

    private let outputView: MetalPreviewView

    /// The display's mode before Videoboy changed it, restored on close. Nil when the
    /// mode was left alone.
    private var modeToRestore: CGDisplayMode?

    /// Creates and shows a borderless window filling `display`.
    ///
    /// If the display advertises the requested SD mode, it is switched to it — that
    /// is what puts a true 720x480 signal down the HDMI-to-RCA converter instead of a
    /// scaled desktop mode. If it does not, the existing mode is kept and the
    /// discrepancy is logged, never guessed at (SPEC 3).
    init(display: DisplayInfo, requestedMode: TargetMode, caption: String = "PRIMARY") {
        self.display = display
        self.outputView = MetalPreviewView(caption: "")

        DisplayRouter.logAvailableModes(for: display, requested: requestedMode)
        var workingDisplay = display
        if let target = DisplayRouter.bestMode(for: display, matching: requestedMode) {
            modeToRestore = CGDisplayCopyDisplayMode(display.displayID)
            let result = OutputWindowController.setMode(target, on: display.displayID)
            if result == .success {
                Log.info(.output, "switched '\(display.name)' to \(target.pixelWidth)x\(target.pixelHeight)@\(String(format: "%.2f", target.refreshRate)) for SD output")
                // Re-read the display so the window is sized to the new mode.
                workingDisplay = DisplayRouter.availableDisplays()
                    .first { $0.displayID == display.displayID } ?? display
            } else {
                Log.error(.output, "could not switch '\(display.name)' to \(requestedMode.description): CGError \(result.rawValue); keeping the current mode")
                modeToRestore = nil
            }
        }
        self.negotiatedMode = DisplayRouter.negotiate(display: workingDisplay, requested: requestedMode)

        let window = NSWindow(
            contentRect: workingDisplay.screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: workingDisplay.screen
        )
        window.title = "Videoboy Output"
        // The program feed must cover the whole screen including the menu bar — a
        // capture of this display is a video signal, not a desktop, and a menu bar
        // burned into the top of it is a defect. `.screenSaver` is above the menu
        // bar's level, which is what achieves that.
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // The window must not follow the user between spaces or get tidied away by
        // Mission Control — it is a signal output, not a document.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]
        window.setFrame(workingDisplay.screen.frame, display: true)

        super.init(window: window)

        window.contentView = outputView
        Log.info(.output, "output window on '\(display.name)' at \(negotiatedMode)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OutputWindowController is created in code, never from a nib")
    }

    /// Changes a display's mode through the configuration-transaction API.
    ///
    /// `CGDisplaySetDisplayMode` is the older one-shot call and refuses some modes
    /// with `kCGErrorIllegalArgument` (1001) even when the display advertises them.
    /// Wrapping the change in a begin/configure/complete transaction is the supported
    /// route and accepts the same modes. The change is applied `forSession` so that a
    /// crash or a logout restores the user's own setting rather than stranding their
    /// display in 720x480.
    private static func setMode(_ mode: CGDisplayMode, on displayID: CGDirectDisplayID) -> CGError {
        var configuration: CGDisplayConfigRef?
        let begun = CGBeginDisplayConfiguration(&configuration)
        guard begun == .success, let configuration else {
            Log.error(.output, "CGBeginDisplayConfiguration failed with CGError \(begun.rawValue)")
            return begun
        }
        let configured = CGConfigureDisplayWithDisplayMode(configuration, displayID, mode, nil)
        guard configured == .success else {
            CGCancelDisplayConfiguration(configuration)
            Log.error(.output, "CGConfigureDisplayWithDisplayMode failed with CGError \(configured.rawValue)")
            return configured
        }
        return CGCompleteDisplayConfiguration(configuration, .forSession)
    }

    /// Shows the window without stealing focus from the main window.
    func present() {
        window?.orderFrontRegardless()
    }

    /// Hides the output window and puts the display back the way it was found.
    ///
    /// Restoring matters: the HDMI card is a real display, and leaving a user's
    /// desktop stuck in 720x480 after quitting would be rude.
    func dismiss() {
        window?.orderOut(nil)
        if let modeToRestore {
            let result = OutputWindowController.setMode(modeToRestore, on: display.displayID)
            if result == .success {
                Log.info(.output, "restored '\(display.name)' to its previous mode")
            } else {
                Log.error(.output, "could not restore '\(display.name)': CGError \(result.rawValue)")
            }
            self.modeToRestore = nil
        }
    }

    deinit {
        // A controller released without dismiss() must still not strand the display.
        if modeToRestore != nil {
            Log.warn(.output, "output window released without dismiss(); restoring the display mode")
            if let modeToRestore { _ = OutputWindowController.setMode(modeToRestore, on: display.displayID) }
        }
    }

    /// Hands this frame's program texture to the output view.
    func present(texture: MTLTexture?) {
        outputView.texture = texture
        outputView.present()
    }
}
