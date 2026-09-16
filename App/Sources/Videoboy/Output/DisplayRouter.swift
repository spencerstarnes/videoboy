//
//  DisplayRouter.swift — which display gets which feed, and what mode it negotiated.
//
//  Purpose : SPEC 3. An HDMI adapter appears to macOS as an external display, so
//            "send PRIMARY to the card" means "put a borderless window on that
//            screen". This enumerates displays, picks the configured one, and —
//            critically — reports the mode that was actually negotiated rather than
//            the one that was asked for.
//  Inputs  : config/devices.json (via Core's DeviceConfig) for the preferred display.
//  Outputs : `DisplayInfo` values, and the `negotiatedMode` string that gets logged,
//            shown in the settings bar, and compared against captured metrics.
//  Connects: OutputWindowController (which presents on the chosen screen), and the
//            loopback self-QA check (which compares logged mode to measured signal).
//  Extend  : mode *selection* (forcing 480i via CGDisplaySetDisplayMode) is not done
//            here yet — see the note on `negotiate`.
//

import AppKit
import CoreGraphics
import VideoboyCore

/// One connected display, as both AppKit and CoreGraphics see it.
struct DisplayInfo {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let name: String
    /// Pixel dimensions of the current mode, not the AppKit point size.
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isMain: Bool

    /// The mode string logged and compared against captured metrics.
    /// Refresh rate reads 0 on some adapters, which is reported honestly as `?`.
    var modeDescription: String {
        let rate = refreshRate > 0 ? String(format: "%.2f", refreshRate) : "?"
        return "\(pixelWidth)x\(pixelHeight)@\(rate)"
    }
}

/// Enumerates displays and resolves the configured output target.
enum DisplayRouter {

    /// Every currently active display.
    static func availableDisplays() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                Log.warn(.output, "a screen reported no display ID and was skipped")
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let mode = CGDisplayCopyDisplayMode(displayID)
            return DisplayInfo(
                screen: screen,
                displayID: displayID,
                name: screen.localizedName,
                pixelWidth: mode?.pixelWidth ?? Int(CGDisplayPixelsWide(displayID)),
                pixelHeight: mode?.pixelHeight ?? Int(CGDisplayPixelsHigh(displayID)),
                refreshRate: mode?.refreshRate ?? 0,
                isMain: screen == NSScreen.main
            )
        }
    }

    /// Picks the output display: the one whose name matches config, else the
    /// configured fallback index, else the first non-main screen, else the main one.
    ///
    /// Falling back to the main screen is deliberate — it means the app always has
    /// somewhere to put output, and the human sees output on their desktop rather
    /// than nothing at all.
    static func preferredOutputDisplay(config: DeviceConfig) -> DisplayInfo? {
        let displays = availableDisplays()
        guard !displays.isEmpty else {
            Log.error(.output, "no displays found at all")
            return nil
        }

        if let configuredName = config.outputDisplay?.name,
           let match = displays.first(where: {
               $0.name.localizedCaseInsensitiveContains(configuredName)
           }) {
            Log.info(.output, "output display matched by name: '\(match.name)' \(match.modeDescription)")
            return match
        }

        if let index = config.outputDisplay?.fallbackIndex, index >= 0, index < displays.count {
            let match = displays[index]
            Log.warn(.output, "no display name matched; using fallback index \(index): '\(match.name)'")
            return match
        }

        if let external = displays.first(where: { !$0.isMain }) {
            Log.warn(.output, "no configured display; using first external: '\(external.name)'")
            return external
        }

        Log.warn(.output, "only the main display is available; output will appear on it")
        return displays.first
    }

    /// Reports what was asked for, what was obtained, and how the gap is handled.
    ///
    /// SPEC 3 is emphatic that the mode must never be guessed silently. Videoboy does
    /// not currently change the display's mode: an HDMI adapter advertises its modes
    /// through EDID and a mode it will not accept cannot be forced, so the app takes
    /// the mode the display is already in, renders the project format (720x480)
    /// into it, and states the discrepancy plainly.
    static func negotiate(display: DisplayInfo, requested: TargetMode) -> String {
        let obtained = display.modeDescription
        let requestedDescription = requested.description

        if display.pixelWidth == requested.width && display.pixelHeight == requested.height {
            Log.info(.output, "output mode: requested \(requestedDescription), display is at \(obtained) — matched")
        } else {
            Log.warn(.output, """
                output mode: requested \(requestedDescription) but '\(display.name)' is at \(obtained). \
                Videoboy does not force display modes; the \(requested.width)x\(requested.height) program is \
                scaled to fill this display, and the downstream HDMI-to-RCA converter handles interlacing. \
                Set the display to \(requestedDescription) in System Settings for a 1:1 signal.
                """)
        }
        return obtained
    }
}
