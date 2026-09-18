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
    private var lastFrameCount = -1

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

    /// Called back when the machine first puts a picture up, so the panel can retire
    /// its "booting" wording without polling this view.
    var onPictureAppeared: (() -> Void)?

    func resetPictureState() {
        hasDrawn = false
        placeholder = "Booting the machine…"
    }

    private func pullFrame() {
        guard let host, let frame = host.latestFrame() else {
            if screenLayer.contents != nil {
                screenLayer.contents = nil
                needsDisplay = true
            }
            return
        }

        // An emulator window is blank — and on Amiberry, blank WHITE — for the first
        // seconds after launch, well before the Amiga has drawn anything. Showing that
        // is worse than showing nothing: a white rectangle reads as a broken app, which
        // is exactly how it was reported. Hold the "booting" label until there is a
        // picture to replace it with.
        if !hasDrawn {
            guard PictureVariety.isPicture(frame) else { return }
            hasDrawn = true
            onPictureAppeared?()
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
