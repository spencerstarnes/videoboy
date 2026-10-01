//
//  LockStrip.swift — one side's LOCK key and Setlist name, in the top bar.
//
//  Purpose : The LOCK key (setlist plan §7): push-on/push-off, an open padlock when
//            off and a closed red one while locked, like Record and Hot Punch, and
//            learnable to a MIDI note with Shift-click (6CJ A/B, 6DJ C/D). Beside it,
//            the Setlist on this bank — "No setlist", greyed, until Setlists exist
//            (phase 3); present now so the bar does not move again when they arrive.
//  Inputs  : `setLocked` (from BankLockController, whatever locked it), `blink`.
//  Outputs : `onToggled` when the key is clicked.
//  Connects: TransportToolbarView (places it), BankLockController (drives it).
//  Extend  : the Setlist name and its CUED / "Locked — skipped" messages go in
//            `setlistLabel` (phase 3). Nothing else belongs in the strip.
//

import AppKit
import VideoboyCore

final class LockStrip: NSView {

    let bank: Bank
    /// The key itself, for hit-testing and self-QA.
    let lockButton = NSButton()
    /// The key wrapped for Shift-click MIDI learn.
    let learnableLock: MappableControl
    /// Which Setlist is on this bank. Read-only.
    let setlistLabel = Controls.label("No setlist", font: Theme.Font.tinyLabel,
                                      color: Theme.Color.textTertiary)

    /// The key was clicked; the new state.
    var onToggled: ((Bool) -> Void)?

    var isLocked: Bool { lockButton.state == .on }

    /// The padlock's point size: a little under Hot Punch's, it is read less often.
    private static let glyphSize: CGFloat = 14

    init(bank: Bank) {
        self.bank = bank
        learnableLock = MappableControl(
            content: lockButton, slot: BankLock.slot, code: BankLock.code(for: bank),
            detectFilter: .notesOnly)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        lockButton.setButtonType(.pushOnPushOff)
        lockButton.isBordered = false
        lockButton.imagePosition = .imageLeading
        lockButton.imageScaling = .scaleNone
        lockButton.font = Theme.Font.tinyLabel
        lockButton.target = self
        lockButton.action = #selector(pressed)
        lockButton.toolTip = "LOCK \(bank.displayName): ignore clicks, keys and MIDI on the "
            + "\(bank.displayName) side — sources, FX, sub-mix and pads. Program still takes it."
        lockButton.setAccessibilityLabel("Lock \(bank.displayName)")
        lockButton.setAccessibilityIdentifier("lock-\(bank.rawValue)")
        // A fixed width: the closed padlock is wider than the open one, and a key that
        // grows when pressed would nudge the pads beside it under someone's fingers.
        lockButton.translatesAutoresizingMaskIntoConstraints = false
        lockButton.widthAnchor.constraint(equalToConstant: 60).isActive = true
        setLocked(false)

        setlistLabel.lineBreakMode = .byTruncatingTail
        setlistLabel.translatesAutoresizingMaskIntoConstraints = false
        setlistLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        setlistLabel.alignment = bank == .ab ? .left : .right
        setlistLabel.toolTip = "The Setlist on this side (Setlists are not built yet)"

        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Theme.Color.separator.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rule.widthAnchor.constraint(equalToConstant: Theme.Metrics.hairline),
            rule.heightAnchor.constraint(equalToConstant: 22)
        ])

        // LOCK on the OUTER end, beside the pads: 1 2 3 4 [LOCK │ name] cluster.
        let views: [NSView] = bank == .ab
            ? [learnableLock, rule, setlistLabel]
            : [setlistLabel, rule, learnableLock]
        let row = Controls.row(views, spacing: 7)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Shows the key locked or not — from a click, MIDI or self-QA.
    func setLocked(_ locked: Bool) {
        lockButton.state = locked ? .on : .off
        let symbol = locked ? "lock.fill" : "lock.open"
        lockButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.glyphSize, weight: .semibold))
        let tint = locked ? Theme.Color.recordActive : Theme.Color.textSecondary
        lockButton.contentTintColor = tint
        // The title in the same colour as the padlock, so the whole key reads red.
        lockButton.attributedTitle = NSAttributedString(string: "LOCK", attributes: [
            .font: Theme.Font.tinyLabel, .foregroundColor: tint
        ])
        lockButton.setAccessibilityValue(locked ? "locked" : "unlocked")
    }

    /// Says "that is why nothing happened": the key flashes three times. Restarting
    /// it while it is already flashing is harmless.
    func blink() {
        blinkCount += 1
        guard let layer = learnableLock.layer ?? { learnableLock.wantsLayer = true; return learnableLock.layer }()
        else { return }
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [1, 0.15, 1, 0.15, 1, 0.15, 1]
        flash.duration = 0.6
        layer.add(flash, forKey: "lock-blink")
    }

    /// How many times this key has blinked — self-QA.
    private(set) var blinkCount = 0

    @objc private func pressed() {
        setLocked(lockButton.state == .on)
        onToggled?(isLocked)
    }
}
