//
//  LaunchWindowController.swift — the startup screen.
//
//  Purpose : Videoboy takes a moment to come up: Metal compiles its shaders, the MPEG-2
//            decoder opens, MIDI enumerates, the graph builds. Showing what is
//            happening turns that pause into information rather than a hang, and it
//            is where the app says whose it is.
//  Inputs   : progress reported by AppDelegate as each subsystem comes up.
//  Outputs   : a borderless window, dismissed when the main window is ready.
//  Connects : AppDelegate.
//  Extend   : add a `LaunchStage` case and report it at the right moment. Do not add
//            artificial delay — if startup gets fast enough that this flashes past,
//            that is a good outcome, not a problem to pad.
//

import AppKit
import VideoboyCore

/// A subsystem coming up at launch.
enum LaunchStage: String, CaseIterable {
    case metal = "Metal render backend"
    case shaders = "Shader library"
    case codecs = "MPEG-2 codec (LGPL FFmpeg)"
    case graph = "Render graph"
    case library = "Library catalog"
    case clock = "Transport and scheduler"
    case midi = "Core MIDI"
    case displays = "Display router"
    case interface = "Interface"

    /// Every stage, in the order they actually happen.
    static var ordered: [LaunchStage] { allCases }
}

/// The launch screen.
final class LaunchWindowController: NSWindowController {

    private var stageRows: [LaunchStage: (dot: NSView, label: NSTextField)] = [:]

    init() {
        let size = NSSize(width: 420, height: 320)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.center()
        window.hasShadow = true

        super.init(window: window)

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.Color.launchBackground.cgColor
        content.layer?.cornerRadius = 12
        content.layer?.borderWidth = Theme.Metrics.hairline
        content.layer?.borderColor = Theme.Color.panelBorder.cgColor
        content.layer?.masksToBounds = true
        window.contentView = content

        let title = NSTextField(labelWithString: "Videoboy")
        title.font = NSFont.systemFont(ofSize: 30, weight: .semibold)
        title.textColor = Theme.Color.textPrimary

        let subtitle = NSTextField(
            labelWithString: "Analog-style video mixing · \(Videoboy.version)")
        subtitle.font = Theme.Font.label
        subtitle.textColor = Theme.Color.textSecondary

        // The stage list. Each row is a dot that lights as its subsystem comes up.
        let stageStack = NSStackView()
        stageStack.orientation = .vertical
        stageStack.alignment = .leading
        stageStack.spacing = 4
        for stage in LaunchStage.ordered {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = Theme.Color.textTertiary.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6)
            ])

            let label = NSTextField(labelWithString: stage.rawValue)
            label.font = Theme.Font.mono
            label.textColor = Theme.Color.textTertiary

            stageStack.addArrangedSubview(Controls.row([dot, label], spacing: 8))
            stageRows[stage] = (dot, label)
        }

        let copyright = NSTextField(labelWithString: "© NewVHS / Spencer Starnes 2026")
        copyright.font = Theme.Font.tinyLabel
        copyright.textColor = Theme.Color.textTertiary

        for view in [title, subtitle, stageStack, copyright] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            stageStack.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 22),
            stageStack.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            copyright.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            copyright.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Marks a stage as up.
    func complete(_ stage: LaunchStage) {
        guard let row = stageRows[stage] else { return }
        row.dot.layer?.backgroundColor = Theme.Color.accent.cgColor
        row.label.textColor = Theme.Color.textSecondary
        // Force the window to redraw now: the main thread is busy launching, so
        // without this the whole list would appear at once, at the end.
        window?.contentView?.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    }

    /// Marks a stage as unavailable — MIDI with no devices, say. Reported rather than
    /// left looking unfinished, because a stage that never lights reads as a hang.
    func skip(_ stage: LaunchStage, reason: String) {
        guard let row = stageRows[stage] else { return }
        row.dot.layer?.backgroundColor = Theme.Color.textTertiary.cgColor
        row.label.stringValue = "\(stage.rawValue) — \(reason)"
        row.label.textColor = Theme.Color.textTertiary
        window?.contentView?.displayIfNeeded()
    }

    /// Fades the launch screen out.
    func dismiss() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
    }
}
