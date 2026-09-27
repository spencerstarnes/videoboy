//
//  ShellView.swift — the canonical window shell (SPEC 14, normative).
//
//  Purpose : Toolbar on top, the 5x5 panel grid in the middle, status bar below.
//            This is the arrangement from docs/mockups/layout-v6.html and it does
//            not get redesigned or simplified.
//  Inputs  : none yet; later phases wire panels to the graph.
//  Outputs : the window's content view.
//  Connects: Theme for every measurement; PanelGridView for the grid itself.
//  Extend  : add panels inside PanelGridView. The three-band arrangement here is fixed.
//

import AppKit
import VideoboyCore

/// The window's content: transport toolbar, panel grid, status bar.
final class ShellView: NSView {

    let toolbar = TransportToolbarView()
    let grid = PanelGridView()
    let statusBar: StatusBarView
    /// Whether this shell carries the mode bar (0.4.8). Fixed for the shell's life.
    let hasModeBar: Bool
    /// Where Import and Settings modes are shown: exactly the grid's frame, so the
    /// toolbar (transport, record) and the strip stay put in every mode.
    let modeHost = NSView()

    /// How bright the beat pulse currently is, 0...1.
    private var pulseAmount: Double = 0
    /// How bright the tempo-change flash currently is, 0...1.
    private var flashAmount: Double = 0

    /// The fade timer, held so a second flash replaces the first rather than running
    /// alongside it. Tap tempo calls `flashTempoChange` once per TAP, so without this
    /// four taps leave four 30fps timers running, every one of them decaying the same
    /// value — the fade goes four times too fast and does four times the redrawing.
    /// `RecordButton` already holds its pulse timer for the same reason.
    private var flashTimer: Timer?

    // The timer captures self weakly and stops itself once the view is gone, so this
    // is belt-and-braces rather than a leak fix — but it is what RecordButton does
    // with its own pulse timer, and two timers in the same window should not have two
    // different lifecycles.
    deinit { flashTimer?.invalidate() }

    /// - Parameter modeBar: build with the mode bar; defaults to the flag. Checks build
    ///   both kinds side by side to prove the grid only shrinks by the strip change.
    init(modeBar: Bool = FeatureFlag.modeBar.isOn) {
        hasModeBar = modeBar
        statusBar = StatusBarView(modeBar: modeBar)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.content.cgColor

        for child in [toolbar, grid, statusBar] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Theme.Metrics.toolbarHeight),

            grid.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),

            statusBar.topAnchor.constraint(equalTo: grid.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: modeBar
                ? Theme.Metrics.modeBarHeight : Theme.Metrics.statusBarHeight)
        ])

        // The mode host covers the grid and nothing else; empty and hidden in VJ mode.
        modeHost.translatesAutoresizingMaskIntoConstraints = false
        modeHost.isHidden = true
        modeHost.wantsLayer = true
        modeHost.layer?.backgroundColor = Theme.Color.content.cgColor
        addSubview(modeHost)
        NSLayoutConstraint.activate([
            modeHost.topAnchor.constraint(equalTo: grid.topAnchor),
            modeHost.bottomAnchor.constraint(equalTo: grid.bottomAnchor),
            modeHost.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            modeHost.trailingAnchor.constraint(equalTo: grid.trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ShellView is created in code, never from a nib")
    }

    // MARK: - Beat pulse
    //
    // The window chrome breathes with the tempo. Only the chrome: nothing inside a
    // panel moves, because a preview that pulses is a preview you cannot trust, and
    // the whole point of a monitor is that what you see is what the signal is.

    /// Sets the pulse from the musical phase, 0..<1 through the beat.
    ///
    /// The curve is squared so the brightness snaps on the beat and eases away,
    /// rather than sliding evenly in and out — an even slide reads as a slow
    /// throb with no clear downbeat.
    func setBeatPhase(_ phase: Double) {
        let decay = pow(1.0 - min(max(phase, 0), 1), 2.0)
        let newAmount = decay * Theme.Pulse.beatStrength
        guard abs(newAmount - pulseAmount) > 0.002 else { return }
        pulseAmount = newAmount
        updateChromeTint()
    }

    /// Clears the pulse when the transport stops.
    func clearBeatPulse() {
        guard pulseAmount != 0 else { return }
        pulseAmount = 0
        updateChromeTint()
    }

    /// Flashes the chrome to acknowledge a tempo change, then fades it out.
    ///
    /// Tempo can change from a tap, from beat detection, or by hand, and in two of
    /// those three the operator did not do it directly — so it needs saying.
    func flashTempoChange() {
        flashAmount = 1.0
        updateChromeTint()

        // Fade on a timer rather than a CABasicAnimation: the tint is a computed
        // blend of two sources, and animating the layer colour directly would fight
        // the beat pulse writing to the same property.
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.flashAmount -= Theme.Pulse.flashDecayPerFrame
            if self.flashAmount <= 0 {
                self.flashAmount = 0
                timer.invalidate()
                self.flashTimer = nil
            }
            self.updateChromeTint()
        }
    }

    /// Blends the pulse and the flash into the window background.
    private func updateChromeTint() {
        let base = Theme.Color.content
        var tinted = base

        if pulseAmount > 0 {
            tinted = tinted.blended(
                withFraction: CGFloat(pulseAmount), of: Theme.Color.beatPulse) ?? tinted
        }
        if flashAmount > 0 {
            tinted = tinted.blended(
                withFraction: CGFloat(flashAmount * Theme.Pulse.flashStrength),
                of: Theme.Color.tempoChangeFlash) ?? tinted
        }
        layer?.backgroundColor = tinted.cgColor
        grid.setChromeTint(tinted)
    }
}
