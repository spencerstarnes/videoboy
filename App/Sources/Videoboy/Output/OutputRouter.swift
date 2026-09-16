//
//  OutputRouter.swift — what goes where.
//
//  Purpose : Until now exactly one thing could leave the app: PROGRAM, to one
//            display. A performer wants more than that — a sub-mix on a monitor
//            behind them, all four sources tiled on a confidence screen, a scope on a
//            second display. This owns those routes and the windows that serve them.
//  Inputs  : a bus or preview slot, and a destination.
//  Outputs : borderless windows on the chosen displays, fed each frame.
//  Connects: DisplayRouter (what displays exist), OutputWindowController (one per
//            active display route), PreferenceStore (destinations a person defined),
//            ShellController (which pushes frames each render).
//  Extend  : a new destination KIND is a case on `RoutingDestination` plus a branch
//            in `present`. Anything that cannot actually be served yet must report
//            `isAvailable == false` with a reason, so the popover can show it greyed
//            rather than silently doing nothing when picked.
//

import AppKit
import VideoboyCore

/// Somewhere a source can be sent.
enum RoutingDestination: Hashable {
    /// A display, by its CoreGraphics ID.
    case display(CGDirectDisplayID)
    /// A destination defined in preferences, by its id.
    case configured(String)

    var isDisplay: Bool {
        if case .display = self { return true }
        return false
    }
}

/// What can be sent.
///
/// Not just "a bus": the four-up and the scope send are views ASSEMBLED for output
/// rather than nodes in the graph, and a router that could only carry graph slots
/// would have no way to express them.
enum RoutingSource: Hashable {
    /// A single node's texture, by slot.
    case slot(String)
    /// All four channel previews, tiled.
    case fourUp
    /// The scope image for a bus.
    case scope(String)

    var displayName: String {
        switch self {
        case .slot(let slot): Self.friendlyName(for: slot)
        case .fourUp: "Four-up preview"
        case .scope(let slot): "\(Self.friendlyName(for: slot)) scopes"
        }
    }

    private static func friendlyName(for slot: String) -> String {
        switch slot {
        case GraphTopology.subMixOne: "Sub Mix One"
        case GraphTopology.subMixTwo: "Sub Mix Two"
        case GraphTopology.primary, Engine.busCodecProgramSlot: "Program"
        case GraphTopology.sourceA: "Source A"
        case GraphTopology.sourceB: "Source B"
        case GraphTopology.sourceC: "Source C"
        case GraphTopology.sourceD: "Source D"
        default: slot
        }
    }
}

/// One offerable destination, as the popover shows it.
struct RoutingOption {
    let destination: RoutingDestination
    let name: String
    let detail: String
    /// False for destinations that exist in preferences but cannot be served yet.
    let isAvailable: Bool
    /// Why it cannot be served, shown beside a greyed row.
    let unavailableReason: String?
}

/// Holds the active routes and the windows serving them.
final class OutputRouter {

    private let store: PreferenceStore
    private let metal: MetalContext?

    /// Which source each destination is currently showing.
    private(set) var routes: [RoutingDestination: RoutingSource] = [:]
    /// One window per display currently in use.
    private var windows: [CGDirectDisplayID: OutputWindowController] = [:]
    /// The tiled texture for the four-up, reused so it is not reallocated per frame.
    private var tiledTarget: MTLTexture?

    /// Called when the routes change, so the interface can restate them.
    var onRoutesChanged: (() -> Void)?

    init(store: PreferenceStore, metal: MetalContext?) {
        self.store = store
        self.metal = metal
    }

    // MARK: - What is on offer

    /// Every destination, displays first.
    ///
    /// Displays are discovered rather than stored: one that has been unplugged must
    /// not linger in the list as somewhere you can send a picture.
    func availableOptions(excludingDisplay excluded: CGDirectDisplayID? = nil) -> [RoutingOption] {
        var options: [RoutingOption] = []

        for display in DisplayRouter.availableDisplays() where display.displayID != excluded {
            options.append(RoutingOption(
                destination: .display(display.displayID),
                name: display.name,
                detail: "\(display.pixelWidth)×\(display.pixelHeight)"
                    + (display.isMain ? " · main" : ""),
                // The main display is where the app itself is. Covering it with a
                // borderless output window would leave no way back to the controls.
                isAvailable: !display.isMain,
                unavailableReason: display.isMain
                    ? "This is the display Videoboy is running on." : nil
            ))
        }

        for destination in store.preferences.destinations {
            options.append(RoutingOption(
                destination: .configured(destination.id),
                name: destination.name,
                detail: destination.kind.displayName
                    + (destination.target.isEmpty ? "" : " · \(destination.target)"),
                isAvailable: false,
                unavailableReason: Self.reasonNotBuilt(destination.kind)
            ))
        }

        return options
    }

    /// Why a configured destination kind cannot be served yet.
    ///
    /// Every one of these is honest about a specific missing piece rather than a
    /// blanket "not implemented" — a person deciding whether to wait for it needs to
    /// know which thing is missing.
    private static func reasonNotBuilt(_ kind: OutputDestination.Kind) -> String {
        switch kind {
        case .obs: "OBS streaming is not built yet."
        case .window: "Sending to another app's window is not built yet."
        case .feedbackSend: "Feedback sends are not wired to the feedback node's external input yet."
        case .captureCard: "Capture-card output needs the card's own SDK."
        case .ipStream: "IP output is not built yet."
        case .generator: "Generators are sources, not destinations."
        }
    }

    // MARK: - Routing

    /// Sends a source to a destination, replacing whatever that destination showed.
    ///
    /// A destination carries one picture at a time, which is what a screen is. A
    /// source can go to several destinations at once, which is what a send is.
    func route(_ source: RoutingSource, to destination: RoutingDestination) {
        guard case .display(let displayID) = destination else {
            Log.warn(.render, "destination is not a display; nothing to present to yet")
            return
        }
        guard let display = DisplayRouter.availableDisplays().first(where: { $0.displayID == displayID })
        else {
            Log.error(.render, "display \(displayID) has gone away; not routing to it")
            return
        }

        routes[destination] = source

        if windows[displayID] == nil {
            let controller = OutputWindowController(
                display: display,
                requestedMode: .standardDefinition,
                caption: source.displayName
            )
            controller.present()
            windows[displayID] = controller
        }
        Log.info(.render, "routed \(source.displayName) to \(display.name)")
        onRoutesChanged?()
    }

    /// Stops sending to a destination and closes its window.
    func clear(_ destination: RoutingDestination) {
        routes.removeValue(forKey: destination)
        if case .display(let displayID) = destination {
            windows[displayID]?.dismiss()
            windows.removeValue(forKey: displayID)
        }
        Log.info(.render, "cleared a route")
        onRoutesChanged?()
    }

    /// Which destinations a source is currently going to.
    func destinations(showing source: RoutingSource) -> [RoutingDestination] {
        routes.filter { $0.value == source }.map(\.key)
    }

    /// True when anything at all is being sent out.
    var hasRoutes: Bool { !routes.isEmpty }

    // MARK: - Per-frame

    /// Pushes this frame to every routed window.
    ///
    /// - Parameter texture: given a source, the texture for it. A closure rather than
    ///   a dictionary because assembling the four-up costs work that should only
    ///   happen when something is actually routed to it.
    func present(textureFor: (RoutingSource) -> MTLTexture?) {
        for (destination, source) in routes {
            guard case .display(let displayID) = destination,
                  let window = windows[displayID] else { continue }
            window.present(texture: textureFor(source))
        }
    }

    /// Tiles four textures for a four-up send.
    func tiled(_ textures: [MTLTexture?]) -> MTLTexture? {
        guard let metal else { return nil }
        let (width, height) = DVStandard.ntsc.size
        if tiledTarget == nil {
            tiledTarget = metal.makeRenderTarget(
                width: width, height: height, label: "four-up")
        }
        guard let tiledTarget else { return nil }
        guard metal.tile(textures, into: tiledTarget, label: "four-up") else { return nil }
        return tiledTarget
    }

    /// Closes every output window, for quitting.
    func closeAll() {
        for window in windows.values { window.dismiss() }
        windows.removeAll()
        routes.removeAll()
    }
}
