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
    /// True when this display is mirroring another.
    ///
    /// This matters a great deal for output: a mirrored display cannot have its mode
    /// set independently, so SD output is impossible until mirroring is turned off.
    let isMirrored: Bool

    /// The mode string logged and compared against captured metrics.
    /// Refresh rate reads 0 on some adapters, which is reported honestly as `?`.
    var modeDescription: String {
        let rate = refreshRate > 0 ? String(format: "%.2f", refreshRate) : "?"
        return "\(pixelWidth)x\(pixelHeight)@\(rate)"
    }

    /// Why this display cannot be switched to a different mode, or nil if it can.
    ///
    /// Returned as a sentence fit to show a person, because the fix is theirs to make
    /// in System Settings — Videoboy will not rearrange someone's desktop by itself.
    var modeSwitchObstacle: String? {
        if isMirrored {
            return "'\(name)' is mirroring another display. A mirrored display cannot be switched to its own mode, so SD output is not possible until mirroring is turned off for it in System Settings > Displays."
        }
        return nil
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
                isMain: screen == NSScreen.main,
                isMirrored: CGDisplayIsInMirrorSet(displayID) != 0
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

    /// Every mode a display advertises through its EDID.
    ///
    /// SPEC 3: a mode the adapter does not offer cannot be forced, so the first step
    /// is always to find out what it actually offers. The list is logged so the gap
    /// between the project format and the available modes is visible rather than
    /// guessed at.
    static func availableModes(for display: DisplayInfo) -> [CGDisplayMode] {
        // Include modes macOS hides by default: the low-resolution SD modes an HDMI
        // capture card advertises are usually among them.
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(display.displayID, options) as? [CGDisplayMode] else {
            Log.warn(.output, "'\(display.name)' reported no mode list")
            return []
        }
        return modes
    }

    /// The advertised mode closest to a requested one, or nil when nothing matches.
    ///
    /// "Closest" means exact width and height; refresh rate is then preferred but not
    /// required, because an adapter often reports 0 for it.
    static func bestMode(
        for display: DisplayInfo, matching requested: TargetMode
    ) -> CGDisplayMode? {
        let candidates = availableModes(for: display).filter {
            $0.pixelWidth == requested.width && $0.pixelHeight == requested.height
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.min {
            abs($0.refreshRate - requested.fps) < abs($1.refreshRate - requested.fps)
        }
    }

    /// Logs every mode a display offers, and whether the project format is among them.
    static func logAvailableModes(for display: DisplayInfo, requested: TargetMode) {
        let modes = availableModes(for: display)
        Log.info(.output, "'\(display.name)' advertises \(modes.count) mode(s)")
        // Distinct geometries only; a display lists the same size at many rates.
        var seen: Set<String> = []
        for mode in modes {
            let key = "\(mode.pixelWidth)x\(mode.pixelHeight)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let rate = mode.refreshRate > 0 ? String(format: "%.2f", mode.refreshRate) : "?"
            Log.info(.output, "  \(key) @ \(rate)")
        }
        if bestMode(for: display, matching: requested) != nil {
            Log.info(.output, "the requested \(requested.description) IS available on this display")
        } else {
            Log.warn(.output, "the requested \(requested.description) is NOT advertised by '\(display.name)'; it will be scaled into whatever mode the display is in")
        }
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
