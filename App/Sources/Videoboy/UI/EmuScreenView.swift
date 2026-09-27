//
//  EmuScreenView.swift — the emulated machine's screen, INSIDE the asset browser.
//
//  Purpose : Shows what the machine is displaying, in the EMU tab, as part of the
//            window. The emulator's own window is a separate application's and floats;
//            this is the one you look at and it lives where the rest of the app does.
//  Inputs   : frames from an `EmulatorHost`, pulled on a timer.
//  Outputs  : a picture, and a click-through to the real window when someone needs to
//             use the machine directly.
//  Connects : EmuBrowserView, EmulatorController, FSUAEHost.
//  Extend   : anything that needs to DRAW the machine belongs here. Anything that
//             needs to DRIVE it belongs in the translation layer — this view is a
//             monitor, not a control surface.
//
//  ── WHY A PULLED TIMER AND NOT A PUSH ───────────────────────────────────────────
//
//  The capture already writes the newest frame into a slot behind a lock, and the
//  render loop already takes whatever is there without waiting. This view does the
//  same thing at its own rate. Pushing every captured frame into the UI would put the
//  capture queue in the main thread's way sixty times a second to update a picture that
//  is a few hundred points wide — and the rule that outranks everything in this app is
//  that the mix never stutters.
//
//  Fifteen a second. It is a monitor for a titler, not the programme output; the
//  programme path takes the same frames through the graph at full rate.
//

import AppKit
import VideoboyCore

/// A live view of the emulated machine.
final class EmuScreenView: NSView {

    /// Where frames come from. Swapped when a machine starts or stops.
    var host: EmulatorHost? {
        didSet { needsDisplay = true }
    }

    /// Called when the picture is double-clicked, to bring the real machine forward.
    var onOpenMachine: (() -> Void)?

    /// What to say when there is nothing to show.
    var placeholder: String = "No machine running" {
        didSet { needsDisplay = true }
    }

    private let screenLayer = CALayer()
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = Theme.Color.previewEmpty.cgColor
        layer?.cornerRadius = 2
        layer?.masksToBounds = true

        screenLayer.contentsGravity = .resizeAspect
        screenLayer.magnificationFilter = .nearest
        layer?.addSublayer(screenLayer)

        toolTip = "What the emulated machine is showing. Double-click to bring the "
            + "machine's own window forward and use it directly."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// 4:3, like everything else that shows a picture in this window.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 150)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screenLayer.frame = bounds
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount >= 2 else { return }
        onOpenMachine?()
    }

    // MARK: - Frames

    /// Starts pulling frames.
    func start() {
        stop()
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.pullFrame()
        }
        // Common modes, so the picture keeps moving while a menu is open or a fader is
        // being dragged — the machine does not stop when the operator is busy.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    /// True once the machine has drawn a real picture. Latched: an Amiga screen that
    /// legitimately goes momentarily flat — a wipe to black, a full-screen colour —
    /// must not throw the panel back to "booting" mid-performance.
    private var hasDrawn = false

    /// When frames first started arriving, so the "has it drawn yet" wait can be given
    /// an upper bound rather than being open-ended.
    private var firstFrameTime: Date?

    /// How long to hold the "booting" label while frames are arriving but scoring below
    /// the picture threshold.
    ///
    /// Longer than a Kickstart-to-Workbench boot, short enough that nobody concludes the
    /// app is broken. Past this, showing the real picture is more honest than waiting.
    private static let blankPictureGrace: TimeInterval = 25

    /// When frames stopped arriving (or never started), so the panel can stop saying
    /// "booting" and start saying what is actually wrong.
    private var noFrameSince: Date?

    /// How long no frames may arrive before the panel explains itself. Comfortably
    /// longer than the capture's own retry window, so a machine that is merely slow to
    /// put a window up is not accused of being broken.
    private static let noFrameGrace: TimeInterval = 20

    /// Called back when the machine first puts a picture up, so the panel can retire
    /// its "booting" wording without polling this view.
    var onPictureAppeared: (() -> Void)?

    func resetPictureState() {
        hasDrawn = false
        firstFrameTime = nil
        noFrameSince = nil
        placeholder = "Booting the machine…"
    }

    private func pullFrame() {
        guard let host, let frame = host.latestFrame() else {
            if screenLayer.contents != nil {
                screenLayer.contents = nil
                needsDisplay = true
            }
            // SAY WHY THERE IS NO PICTURE, once waiting has gone on too long.
            //
            // This panel showed "Booting the machine… (~20s)" for every reason it could
            // fail: still booting, capture never attached, Screen Recording refused, the
            // window not found. Those need completely different things done about them,
            // and the panel gave the operator no way to tell them apart — so "the EMU
            // screen won't load" was the only report anyone could make.
            //
            // The host already knows; it sets `unavailableReason` when the capture gives
            // up. This just stops throwing that away.
            if noFrameSince == nil { noFrameSince = Date() }
            if let noFrameSince, Date().timeIntervalSince(noFrameSince) > Self.noFrameGrace {
                let reason = host?.unavailableReason
                    ?? "No frames are arriving from the machine. If macOS never asked for "
                        + "Screen Recording, the app's permission was voided by the last "
                        + "rebuild — see scripts/signing-identity.sh."
                if placeholder != reason {
                    placeholder = reason
                    Log.warn(.titler, "EMU panel has no picture: \(reason)")
                }
            }
            return
        }
        noFrameSince = nil

        // An emulator window is blank — and on Amiberry, blank WHITE — for the first
        // seconds after launch, well before the Amiga has drawn anything. Showing that
        // is worse than showing nothing: a white rectangle reads as a broken app, which
        // is exactly how it was reported. Hold the "booting" label until there is a
        // picture to replace it with.
        //
        // BUT THE WAIT IS BOUNDED, and that is what was missing. `isPicture` asks for
        // more than 1% local detail, and a Scala page — a flat coloured background with
        // a line of text on it — measures almost exactly 1%. The emu self-QA put the
        // programme output at "1.0% detail", i.e. sitting on the threshold. So this
        // guard could refuse forever: frames arriving perfectly well, capture healthy,
        // and the panel reading "Booting the machine…" for the rest of the night with
        // no way to tell that from a real failure.
        //
        // The threshold is NOT lowered — `PictureVariety`'s header is explicit that
        // doing so is how a blank window comes to read as a working emulator, and it is
        // right. Instead this is the separate signal that header asks for: once frames
        // have been arriving for a while, show what the machine is ACTUALLY displaying,
        // whatever it scores. A flat screen shown honestly is information; "booting"
        // forever is not.
        if !hasDrawn {
            if firstFrameTime == nil { firstFrameTime = Date() }
            let waited = Date().timeIntervalSince(firstFrameTime ?? Date())

            if PictureVariety.isPicture(frame) {
                hasDrawn = true
                onPictureAppeared?()
            } else if waited > Self.blankPictureGrace {
                hasDrawn = true
                onPictureAppeared?()
                Log.warn(.titler, "the machine's picture scores "
                    + String(format: "%.1f%%", PictureVariety.score(of: frame) * 100)
                    + " local detail, below the "
                    + String(format: "%.1f%%", PictureVariety.readyThreshold * 100)
                    + " 'has drawn' threshold, but frames have been arriving for "
                    + String(format: "%.0f", waited) + "s — showing it anyway")
            } else {
                return
            }
        }

        guard let image = frame.makeCGImage() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screenLayer.contents = image
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard screenLayer.contents == nil else { return }
        // The empty state says WHY rather than being a black rectangle, which is the
        // house rule and also the difference between "not started" and "broken".
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.Font.tinyLabel,
            .foregroundColor: Theme.Color.textTertiary
        ]
        let text = placeholder as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }
}
