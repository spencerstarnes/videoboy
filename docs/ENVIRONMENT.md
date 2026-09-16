# ENVIRONMENT.md

Toolchain and machine facts this build targets. Detected, not assumed — re-run the
commands below if anything moves.

## Detected (2026-09-16)

| Thing | Value | How to re-check |
|---|---|---|
| macOS | 15.5 (24F74) | `sw_vers` |
| Architecture | arm64 (Apple M1 Max) | `uname -m` |
| Xcode | 16.4 (16F6) | `xcodebuild -version` |
| Swift (Xcode) | 6.1.2 | `xcrun swift --version` |
| Metal compiler | 32023.620 | `xcrun metal --version` |
| GPU | Apple M1 Max, Metal 3 | `system_profiler SPDisplaysDataType` |
| ffmpeg CLI (dev tool only) | 9.0.1 | `ffmpeg -version` |

## The one wrinkle: `xcode-select` points at the Command Line Tools

`/Applications/Xcode.app` is installed, but the active developer directory is
`/Library/Developer/CommandLineTools`, which ships **no Metal compiler** and no
`xcodebuild`. Rather than change a system-wide setting (which needs `sudo`), every
script sets `DEVELOPER_DIR` to the Xcode toolchain. See `scripts/_common.sh`.

If you would rather fix it globally, run once:

```
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

The scripts keep working either way — `DEVELOPER_DIR` is only set when it is unset.

## Why the app is built with SwiftPM, not an `.xcodeproj`

`CLAUDE.md` says the App target is "built with `xcodebuild`". It is built with
`swift build` plus a bundle-assembly step in `scripts/build.sh` instead, for two
reasons:

1. A hand-maintained `.pbxproj` is the least repairable file in a Mac project, and
   SPEC 1.5 asks for the boring, obvious, repairable option.
2. Everything `xcodebuild` would give us here is already in hand: the Xcode
   toolchain (via `DEVELOPER_DIR`), the full macOS SDK, the Metal compiler, and a
   real `.app` bundle with an `Info.plist` and an ad-hoc signature.

Consequence: there is no Xcode project to open. Build and run from the terminal with
`scripts/build.sh` and `scripts/run.sh`. If an Xcode project is wanted later, the
package layout already supports `File ▸ Open` on the `App/` package directory.

## Hardware seen on this machine

| Role | Device | Notes |
|---|---|---|
| Output display (HDMI card) | `MACROSILICON` | Enumerates as an external display, as SPEC 3 expects. Was at 1280x1024 when last enumerated. |
| Main display | `BenQ PD3200U` | 3840x2160 |
| Second display | `BenQ SW271` | 2160x3840, rotated |
| Loopback capture | `DVC100` | Present on USB. See `docs/BLOCKED.md` for its AVFoundation visibility. |

Fill real names into `config/devices.json`; nothing reads them from source.
