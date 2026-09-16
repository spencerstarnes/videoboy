//
//  PanelView.swift — one panel box: header, optional bus dot, collapsible body.
//
//  Purpose : Every cell of the grid is one of these (SPEC 14.2). Clicking the header
//            collapses the body, and the panel keeps its grid cell so alignment never
//            breaks. Panels never move — there is no drag handling here on purpose.
//  Inputs  : a title, an optional bus identity, an optional mono subtitle, and a body view.
//  Outputs : a rounded, bordered box matching docs/mockups/layout-v6.html.
//  Connects: PanelGridView places these; Theme supplies every measurement.
//  Extend  : put content in the body view you hand it. Do not subclass this to add
//            chrome — if a panel needs different chrome, the mockup has changed.
//

import AppKit
import VideoboyCore

/// Which sub-mix a panel belongs to. Drives the header dot colour, and nothing else:
/// SPEC 14.3 restricts amber/cyan to bus identity.
enum BusIdentity {
    case none
    case one
    case two

    var dotColor: NSColor? {
        switch self {
        case .none: nil
        case .one: Theme.Color.busOne
        case .two: Theme.Color.busTwo
        }
    }
}

/// A titled, collapsible panel box.
final class PanelView: NSView {

    /// Title shown in the header.
    let title: String

    /// Whether the body is hidden. The panel keeps its grid cell either way.
    private(set) var isCollapsed = false

    private let headerButton = NSButton()
    private let chevron = NSTextField(labelWithString: "▾")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let busDot = NSView()
    private let bodyContainer = NSView()
    private var bodyHeightWhenCollapsed: NSLayoutConstraint?

    /// The view filling the panel body.
    private let body: NSView

    /// Which corners stay rounded. A panel butted against a neighbour squares off the
    /// shared edge so the two read as one block (see PanelGridView.GroupEdge).
    var squaredEdges: GroupEdge = [] {
        didSet { applyCornerMask() }
    }

    /// - Parameters:
    ///   - title: header text.
    ///   - bus: bus identity, which colours the header dot.
    ///   - subtitle: right-aligned monospaced text (e.g. `A ▸ B`, `720x480 · 480i`).
    ///   - body: the panel's contents.
    init(title: String, bus: BusIdentity = .none, subtitle: String = "", body: NSView) {
        self.title = title
        self.body = body
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = Theme.Color.panelFill.cgColor
        layer?.borderColor = Theme.Color.panelBorder.cgColor
        layer?.borderWidth = Theme.Metrics.hairline
        layer?.cornerRadius = Theme.Metrics.panelCornerRadius
        layer?.masksToBounds = true
        applyCornerMask()

        buildHeader(bus: bus, subtitle: subtitle)
        buildBody()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelView is created in code, never from a nib")
    }

    /// Rounds only the corners that are not against a neighbour.
    private func applyCornerMask() {
        guard let layer else { return }
        var corners: CACornerMask = [
            .layerMinXMinYCorner, .layerMaxXMinYCorner,
            .layerMinXMaxYCorner, .layerMaxXMaxYCorner
        ]
        // AppKit layers are bottom-left origin, so MinY is the BOTTOM of the panel.
        if squaredEdges.contains(.top) {
            corners.remove(.layerMinXMaxYCorner)
            corners.remove(.layerMaxXMaxYCorner)
        }
        if squaredEdges.contains(.bottom) {
            corners.remove(.layerMinXMinYCorner)
            corners.remove(.layerMaxXMinYCorner)
        }
        if squaredEdges.contains(.leading) {
            corners.remove(.layerMinXMinYCorner)
            corners.remove(.layerMinXMaxYCorner)
        }
        if squaredEdges.contains(.trailing) {
            corners.remove(.layerMaxXMinYCorner)
            corners.remove(.layerMaxXMaxYCorner)
        }
        layer.maskedCorners = corners
    }

    // MARK: - Construction

    private func buildHeader(bus: BusIdentity, subtitle: String) {
        // The whole header is a button so the entire strip is the collapse target,
        // matching the mockup's clickable `.boxh`.
        headerButton.title = ""
        headerButton.isBordered = false
        headerButton.target = self
        headerButton.action = #selector(toggleCollapsed)
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerButton)

        chevron.font = Theme.Font.tinyLabel
        chevron.textColor = Theme.Color.textTertiary

        titleLabel.stringValue = title
        titleLabel.font = Theme.Font.panelTitle
        titleLabel.textColor = Theme.Color.textPrimary

        subtitleLabel.stringValue = subtitle
        subtitleLabel.font = Theme.Font.mono
        subtitleLabel.textColor = Theme.Color.textSecondary
        subtitleLabel.alignment = .right

        busDot.wantsLayer = true
        busDot.layer?.cornerRadius = Theme.Metrics.busDotDiameter / 2
        busDot.layer?.backgroundColor = bus.dotColor?.cgColor
        busDot.isHidden = bus.dotColor == nil

        let row = NSStackView(views: [chevron, busDot, titleLabel, NSView(), subtitleLabel])
        row.orientation = .horizontal
        row.spacing = Theme.Metrics.controlSpacing
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        // The spacer view between title and subtitle pushes the subtitle right.
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(row)

        NSLayoutConstraint.activate([
            headerButton.topAnchor.constraint(equalTo: topAnchor),
            headerButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerButton.heightAnchor.constraint(equalToConstant: Theme.Metrics.panelHeaderHeight),

            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Metrics.panelHeaderPaddingX),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Metrics.panelHeaderPaddingX),
            row.centerYAnchor.constraint(equalTo: headerButton.centerYAnchor),

            busDot.widthAnchor.constraint(equalToConstant: Theme.Metrics.busDotDiameter),
            busDot.heightAnchor.constraint(equalToConstant: Theme.Metrics.busDotDiameter)
        ])
        // Let the title keep its size and the spacer absorb the slack.
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        subtitleLabel.setContentHuggingPriority(.required, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func buildBody() {
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bodyContainer)
        body.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(body)

        NSLayoutConstraint.activate([
            bodyContainer.topAnchor.constraint(equalTo: headerButton.bottomAnchor),
            bodyContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            body.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            body.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor)
        ])
    }

    // MARK: - Collapsing

    @objc private func toggleCollapsed() {
        setCollapsed(!isCollapsed)
    }

    /// Hides or shows the body. The panel's grid cell is unaffected, which is what
    /// keeps every column aligned when one panel is collapsed (SPEC 14.2).
    func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        bodyContainer.isHidden = collapsed
        chevron.stringValue = collapsed ? "▸" : "▾"
        Log.info(.app, "panel '\(title)' \(collapsed ? "collapsed" : "expanded")")
    }
}
