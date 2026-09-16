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
    let statusBar = StatusBarView()

    /// How bright the beat pulse currently is, 0...1.
    private var pulseAmount: Double = 0
    /// How bright the tempo-change flash currently is, 0...1.
    private var flashAmount: Double = 0

    init() {
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
            statusBar.heightAnchor.constraint(equalToConstant: Theme.Metrics.statusBarHeight)
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
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.flashAmount -= Theme.Pulse.flashDecayPerFrame
            if self.flashAmount <= 0 {
                self.flashAmount = 0
                timer.invalidate()
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
