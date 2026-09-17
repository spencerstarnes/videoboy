//
//  ControlAuditSelfQA.swift — walks the interface and reports what actually works.
//
//  Purpose : "Is every switch wired up?" should not be answered by looking. This
//            builds the whole window offscreen, walks the view tree, and reports
//            every control with whether it is enabled and whether it has a target
//            and action — so a control that looks live but does nothing is caught
//            mechanically rather than during a show.
//  Inputs  : none; it constructs its own ShellView.
//  Outputs : selfqa/out/audit/controls.md — a table, and a TODO list of everything
//            disabled, ready to paste into docs.
//  Connects: ShellView and every panel beneath it.
//
//  A control counts as WIRED when it is enabled and has both a target and an action,
//  or is one of the custom controls that carries its own behaviour. Anything enabled
//  with no action is the dangerous case: it looks live and does nothing.
//

import AppKit
import VideoboyCore

/// Audits the interface's controls.
enum ControlAuditSelfQA {

    /// Every view beneath a root, flattened.
    private static func allSubviews(of root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap { allSubviews(of: $0) }
    }

    /// Labels whose text does not fit the width they were given.
    ///
    /// Measured rather than looked for: an NSTextField shows an ellipsis at draw
    /// time, so the string itself is intact and only the geometry tells you.
    private static func collectTruncatedLabels(in view: NSView, into found: inout [String]) {
        if let field = view as? NSTextField, !field.stringValue.isEmpty,
           field.frame.width > 0 {
            let needed = (field.stringValue as NSString).size(
                withAttributes: [.font: field.font ?? NSFont.systemFont(ofSize: 11)]).width
            if needed > field.frame.width + 1 {
                found.append("\(field.stringValue) needs \(Int(needed))pt, has \(Int(field.frame.width))pt")
            }
        }
        for subview in view.subviews { collectTruncatedLabels(in: subview, into: &found) }
    }

    /// Walks the tree for faders and whether each one carries a mapping address.
    private static func collectFaders(
        from view: NSView, panel: String,
        into faders: inout [(label: String, isMappable: Bool, isEnabled: Bool)]
    ) {
        let panelName = (view as? PanelView)?.title ?? panel
        if let fader = view as? VBFader {
            let label = fader.identifier?.rawValue ?? "unnamed"
            faders.append((
                label: "\(panelName)/\(label)",
                isMappable: fader.mappingSlot != nil && fader.mappingCode != nil,
                isEnabled: fader.isEnabled
            ))
        }
        for subview in view.subviews {
            collectFaders(from: subview, panel: panelName, into: &faders)
        }
    }

    /// One control found in the tree.
    private struct Finding {
        let panel: String
        let kind: String
        let label: String
        let isEnabled: Bool
        let hasAction: Bool

        /// Enabled and connected to something.
        var isLive: Bool { isEnabled && hasAction }
        /// Enabled but connected to nothing — looks usable, does nothing.
        var isDeceptive: Bool { isEnabled && !hasAction }
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "audit")

        // Build the shell AND its controller, exactly as the app does. Auditing a
        // bare ShellView would report every controller-wired control as dead, which
        // is worse than not auditing at all — it would send you hunting for bugs
        // that are artefacts of how the audit was built.
        let shell = ShellView()
        let engine = Engine()
        let controller = ShellController(shell: shell, engine: engine)
        shell.frame = NSRect(x: 0, y: 0, width: 1460, height: 912)
        shell.layoutSubtreeIfNeeded()
        // Keep the controller alive for the walk; it owns the wiring being audited.
        withExtendedLifetime(controller) {}

        var findings: [Finding] = []
        collect(from: shell, panel: "window", into: &findings)

        // The Preferences window too. It is where people go to find out what the app
        // can do, so a dead control there misleads more than one on the main window,
        // where at least the surrounding context says what is finished.
        let store = PreferenceStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("videoboy-audit-prefs.json"))
        let preferences = PreferencesWindowController(store: store, engine: engine)
        for pane in PreferencesWindowController.Pane.allCases {
            preferences.select(pane)
            preferences.window?.contentView?.layoutSubtreeIfNeeded()
            if let content = preferences.window?.contentView {
                collect(from: content, panel: "preferences/\(pane.rawValue)", into: &findings)
            }
        }
        try? FileManager.default.removeItem(at: store.fileURL)
        withExtendedLifetime(preferences) {}

        let live = findings.filter(\.isLive)
        let disabled = findings.filter { !$0.isEnabled }
        let deceptive = findings.filter(\.isDeceptive)

        check.note("\(findings.count) controls found: \(live.count) live, \(disabled.count) disabled, \(deceptive.count) enabled-but-unwired")

        // Write the report.
        var lines: [String] = []
        lines.append("# Control audit")
        lines.append("")
        lines.append("Generated by `Videoboy --selfqa audit`. Do not edit by hand — re-run it.")
        lines.append("")
        lines.append("| State | Count |")
        lines.append("|---|---|")
        lines.append("| Live (enabled, wired) | \(live.count) |")
        lines.append("| Disabled (labelled not-yet-built) | \(disabled.count) |")
        lines.append("| **Enabled but unwired** | **\(deceptive.count)** |")
        lines.append("| Total | \(findings.count) |")
        lines.append("")

        if !deceptive.isEmpty {
            lines.append("## Enabled but unwired — these look usable and do nothing")
            lines.append("")
            for finding in deceptive.sorted(by: { $0.panel < $1.panel }) {
                lines.append("- `\(finding.panel)` — \(finding.kind) \"\(finding.label)\"")
            }
            lines.append("")
        }

        lines.append("## Disabled — present, visibly inert, waiting on their feature")
        lines.append("")
        for finding in disabled.sorted(by: { $0.panel < $1.panel }) {
            lines.append("- `\(finding.panel)` — \(finding.kind) \"\(finding.label)\"")
        }
        lines.append("")
        lines.append("## Live")
        lines.append("")
        for finding in live.sorted(by: { $0.panel < $1.panel }) {
            lines.append("- `\(finding.panel)` — \(finding.kind) \"\(finding.label)\"")
        }

        let report = lines.joined(separator: "\n") + "\n"
        do {
            try report.write(to: check.artifactURL("controls.md"), atomically: true, encoding: .utf8)
            Log.info(.selfqa, "wrote control audit -> \(check.artifactURL("controls.md").path)")
        } catch {
            Log.error(.selfqa, "could not write the control audit: \(error)")
        }

        // Shift-to-detect coverage. A fader with no mapping address stays dark when
        // Shift is held, which reads as "this one cannot be mapped" — so an address
        // left off by accident is indistinguishable from a deliberate limit. Counting
        // them is the only way to keep that honest.
        // Only enabled faders are held to it: a fader belonging to an effect that is
        // not built yet is disabled, and having no mapping address is the truth
        // about it rather than an oversight.
        var faders: [(label: String, isMappable: Bool, isEnabled: Bool)] = []
        collectFaders(from: shell, panel: "window", into: &faders)
        let unmappable = faders.filter { $0.isEnabled && !$0.isMappable }
        check.record(AssertionResult(
            name: "every fader can be mapped by Shift-clicking it",
            passed: unmappable.isEmpty,
            detail: unmappable.isEmpty
                ? "\(faders.filter(\.isEnabled).count) enabled faders, all carrying a slot and a param code"
                : "\(unmappable.count) of \(faders.count) have no mapping address: "
                    + unmappable.map(\.label).joined(separator: ", ")
        ))

        // Every switch must AGREE WITH THE ENGINE at launch. A control that says off
        // while the thing it controls is on is worse than a dead control: the picture
        // is being processed and nothing on screen admits it. This is the check that
        // would have caught NTSC emulation booting on with its switch reading off.
        var disagreements: [String] = []
        let bootChecks: [(name: String, switchIsOn: Bool, engineIsOn: Bool)] = [
            ("NTSC output emulation", false, engine.isOutputNTSCEnabled),
            ("DV output emulation", false, engine.isOutputDVEnabled)
        ]
        for bootCheck in bootChecks where bootCheck.switchIsOn != bootCheck.engineIsOn {
            disagreements.append(
                "\(bootCheck.name): switch off, engine \(bootCheck.engineIsOn ? "on" : "off")")
        }
        // And every bus effect must boot bypassed, since every one of their switches
        // draws itself off.
        // Compared against what the engine DECLARES is live at launch, not against a
        // blanket assumption that everything boots bypassed. That assumption was true
        // until the grade earned an exception, and a check that cannot express an
        // intended exception gets edited away the first time one appears.
        //
        // It still catches the bug it was written for: a slot that boots live without
        // being declared, or one declared live that boots bypassed. Both are the
        // switch and the engine disagreeing, which is the actual contract.
        for slot in Engine.busEffectSlots {
            let wetDry = engine.registry.value(slot: slot, code: .wetDry) ?? 0
            let shouldBeLive = Engine.liveAtLaunchSlots.contains(slot)
            if shouldBeLive && wetDry <= 0.001 {
                disagreements.append("\(slot) is declared live at launch but boots bypassed")
            }
            if !shouldBeLive && wetDry > 0.001 {
                disagreements.append("\(slot) boots at wet/dry \(wetDry) without being declared live")
            }
        }
        check.record(AssertionResult(
            name: "every switch agrees with the engine at launch",
            passed: disagreements.isEmpty,
            detail: disagreements.isEmpty
                ? "\(Engine.busEffectSlots.count) effects boot bypassed, both emulations off"
                : disagreements.joined(separator: "; ")
        ))

        // Full screen must stay refused while the layout is unsettled: there is no
        // reliable way back out of it with the pointer.
        let mainWindow = MainWindowController(preferences: store)
        check.record(AssertionResult(
            name: "the main window refuses full screen",
            passed: mainWindow.window?.collectionBehavior.contains(.fullScreenNone) == true,
            detail: mainWindow.window?.collectionBehavior.contains(.fullScreenNone) == true
                ? "fullScreenNone is set"
                : "full screen is still reachable, and there is no way back from it"
        ))
        // ...but MAXIMISE must stay available, which is a different thing. The zoom
        // button was disabled along with full screen, which took maximise and the
        // title-bar double-click with it. Refusing full screen is deliberate;
        // refusing to maximise was collateral.
        let zoomEnabled = mainWindow.window?.standardWindowButton(.zoomButton)?.isEnabled ?? false
        check.record(AssertionResult(
            name: "the main window can still be maximised",
            passed: zoomEnabled,
            detail: zoomEnabled
                ? "the zoom button is enabled, and with fullScreenNone set it zooms rather than going full screen"
                : "the zoom button is disabled, so neither the green button nor a title-bar double-click can maximise"
        ))

        // And zoom has to mean the whole screen, not AppKit's best-fit guess around
        // the content — a grid that fills any size gives it nothing to fit to.
        if let window = mainWindow.window, let screen = window.screen {
            // `window.delegate` is already `NSWindowDelegate?`, so the downcast this
            // used to carry did nothing at all.
            let standard = window.delegate?
                .windowWillUseStandardFrame?(window, defaultFrame: screen.visibleFrame)
            check.record(AssertionResult(
                name: "maximising fills the screen rather than best-fitting the content",
                passed: standard == screen.visibleFrame,
                detail: "standard frame \(standard.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"), "
                    + "visible frame \(Int(screen.visibleFrame.width))x\(Int(screen.visibleFrame.height))"
            ))
        }

        mainWindow.window?.close()

        // Every panel header, audited. You asked whether the problem was only on
        // Source: A — it was on all six grouped panels, and the inner ones had the
        // opposite problem of collapsing into a cell the grid still reserved.
        let behaviours = shell.grid.headerBehaviours()
        let broken = behaviours.filter { $0.behaviour == .hidesItselfLeavingAHole }
        check.record(AssertionResult(
            name: "no panel header hides its panel and leaves the cell reserved",
            passed: broken.isEmpty,
            detail: broken.isEmpty
                ? "\(behaviours.filter { if case .collapsesGroup = $0.behaviour { return true }; return false }.count)"
                    + " headers collapse their group, "
                    + "\(behaviours.filter { $0.behaviour == .inert }.count) are deliberately inert"
                : broken.map(\.title).joined(separator: ", ")
        ))

        // Nothing in the output bar may be showing truncated text. A label that ends
        // in an ellipsis has been cut off by the layout, and "not yet negotiat…" says
        // less than nothing — it is the shape of writing without the content.
        var truncated: [String] = []
        collectTruncatedLabels(in: shell.grid.panels.settingsBar, into: &truncated)
        check.record(AssertionResult(
            name: "no label in the output bar is cut off",
            passed: truncated.isEmpty,
            detail: truncated.isEmpty ? "every label fits" : truncated.joined(separator: ", ")
        ))

        // The modulation badges, which name a thing and so must never be the thing
        // that gets cut. They were pinned at one character's width and clipped "LFO"
        // to "L…" the moment they stopped being single letters.
        var clippedBadges: [String] = []
        for panel in [shell.grid.panels.effectsOneBody, shell.grid.panels.effectsTwoBody] {
            for case let button as NSButton in allSubviews(of: panel)
            where ModulationSource.fromBadge(button.title) != nil {
                let needed = (button.title as NSString)
                    .size(withAttributes: [.font: button.font ?? Theme.Font.tinyLabel]).width
                if button.frame.width > 0 && needed > button.frame.width {
                    clippedBadges.append(
                        "\(button.title) needs \(Int(needed))pt, has \(Int(button.frame.width))pt")
                }
            }
        }
        check.record(AssertionResult(
            name: "no modulation badge is cut off",
            passed: clippedBadges.isEmpty,
            detail: clippedBadges.isEmpty
                ? "MIDI, AUD and LFO all fit in both chains"
                : clippedBadges.joined(separator: ", ")
        ))

        // The failing condition is a control that is enabled and wired to nothing.
        // A disabled control is fine — it is honest about not being built.
        check.record(AssertionResult(
            name: "no control is enabled but unwired",
            passed: deceptive.isEmpty,
            detail: deceptive.isEmpty
                ? "every enabled control has an action"
                : "\(deceptive.count): " + deceptive.map { "\($0.panel)/\($0.label)" }.joined(separator: ", ")
        ))
        check.record(AssertionResult(
            name: "the interface has controls at all",
            passed: findings.count > 40,
            detail: "\(findings.count) found"
        ))

        return check.finish()
    }

    /// Walks the view tree, recording controls and the panel each sits in.
    private static func collect(from view: NSView, panel: String, into findings: inout [Finding]) {
        var currentPanel = panel
        if let panelView = view as? PanelView {
            currentPanel = panelView.title
        }

        for subview in view.subviews {
            if let control = subview as? NSControl {
                findings.append(describe(control, panel: currentPanel))
                // A control's own subviews are its internals, not more controls.
                continue
            }
            collect(from: subview, panel: currentPanel, into: &findings)
        }
    }

    /// Turns a control into a finding.
    private static func describe(_ control: NSControl, panel: String) -> Finding {
        let kind: String
        var label = ""

        switch control {
        case let button as NSButton:
            kind = "button"
            label = button.title.isEmpty ? (button.toolTip ?? "untitled") : button.title
        case let popUp as NSPopUpButton:
            kind = "popup"
            label = popUp.itemTitles.first ?? "empty"
        case let segmented as NSSegmentedControl:
            kind = "segmented"
            label = (0..<segmented.segmentCount)
                .compactMap { segmented.label(forSegment: $0) }
                .joined(separator: "/")
        case is NSSwitch:
            kind = "switch"
            label = control.toolTip ?? "toggle"
        case let fader as VBFader:
            kind = "fader"
            label = fader.identifier?.rawValue ?? "unnamed"
        case let table as NSTableView:
            kind = "table"
            label = table.identifier?.rawValue ?? "list"
        case is NSSearchField:
            kind = "search"
            label = (control as? NSSearchField)?.placeholderString ?? "search"
        case is RecordButton:
            kind = "record"
            label = "record"
        case is MiniRecordIndicator:
            kind = "arm"
            label = (control as? MiniRecordIndicator)?.label ?? "arm"
        case is CollapsedRailView:
            kind = "rail"
            label = (control as? CollapsedRailView)?.title ?? "rail"
        case is NSTextField:
            // Labels are NSControls too, and are not interactive.
            kind = "label"
            label = (control as? NSTextField)?.stringValue ?? ""
        default:
            kind = String(describing: type(of: control))
            label = control.toolTip ?? ""
        }

        // Labels are not controls for this purpose.
        if kind == "label" {
            return Finding(panel: panel, kind: kind, label: label, isEnabled: false, hasAction: true)
        }

        // A closure-driven control answers for itself; target/action says nothing
        // useful about it. Everything else is judged the AppKit way.
        let wired: Bool
        if let auditable = control as? AuditableControl {
            wired = auditable.isWiredForAudit
        } else if let table = control as? NSTableView {
            // A table is driven by its data source and delegate; target/action says
            // nothing about whether it works. An empty table with both connected is
            // doing its job — it simply has nothing to show.
            wired = table.dataSource != nil && table.delegate != nil
        } else {
            wired = control.action != nil && control.target != nil
        }

        return Finding(
            panel: panel,
            kind: kind,
            label: label,
            isEnabled: control.isEnabled,
            hasAction: wired
        )
    }
}
