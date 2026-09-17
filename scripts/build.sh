#!/usr/bin/env bash
#
# build.sh — build Core, build App, assemble a launchable .app bundle.
#
# Purpose : Produces build/Videoboy.app: a real bundle with an Info.plist (so the
#           camera-permission string exists and the app gets a Dock icon and a menu
#           bar) and an ad-hoc signature (so macOS will run it locally).
# Inputs  : Core/ and App/ SwiftPM packages.
# Outputs : build/Videoboy.app, ready for scripts/run.sh.
# Notes   : The app is built with SwiftPM rather than an .xcodeproj — see
#           docs/ENVIRONMENT.md for why. `xcrun` still comes from Xcode, so the
#           Metal toolchain and the full macOS SDK are the ones in use.
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
require_toolchain
require_ffmpeg

CONFIGURATION="${1:-release}"

log "building Core ($CONFIGURATION, $VIDEOBOY_ARCH)"
cd "$REPO_ROOT/Core"
swift build -c "$CONFIGURATION" --arch "$VIDEOBOY_ARCH" "${FFMPEG_FLAGS[@]}"

log "building App ($CONFIGURATION, $VIDEOBOY_ARCH)"
cd "$REPO_ROOT/App"
swift build -c "$CONFIGURATION" --arch "$VIDEOBOY_ARCH" "${FFMPEG_FLAGS[@]}"
BINARY="$(swift build -c "$CONFIGURATION" --arch "$VIDEOBOY_ARCH" "${FFMPEG_FLAGS[@]}" --show-bin-path)/$APP_NAME"
[ -x "$BINARY" ] || fail "expected an executable at $BINARY"

log "assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$REPO_ROOT/App/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# The LGPL FFmpeg dylibs ship inside the bundle. Shared (not static) linkage is
# what keeps the LGPL relinking obligation simple; see docs/THIRD-PARTY.md.
log "embedding LGPL FFmpeg"
cp -a "$VENDOR_FFMPEG"/lib/*.dylib "$APP_BUNDLE/Contents/Frameworks/"
cp "$REPO_ROOT/docs/THIRD-PARTY.md" "$APP_BUNDLE/Contents/Resources/THIRD-PARTY.md"

# The app icon, drawn rather than checked in — see scripts/make-icon.swift. Generated
# every build so editing the numbers in that file is all it takes to change the icon.
log "drawing the app icon"
ICONSET="$(mktemp -d)/Videoboy.iconset"
if swift "$REPO_ROOT/scripts/make-icon.swift" "$ICONSET" >/dev/null 2>&1 \
   && iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/Videoboy.icns" 2>/dev/null; then
  :
else
  # Never fatal: an app that will not build because its icon would not draw is a
  # worse trade than an app wearing the generic one.
  log "icon could not be drawn; the app will use the default"
fi

# Ad-hoc signature only. CLAUDE.md rules out the Apple Developer Program,
# notarization, and distribution signing; this is what lets the app run locally.
log "ad-hoc signing"
codesign --force --sign - --timestamp=none "$APP_BUNDLE" 2>&1 | sed 's/^/  /' || fail "codesign failed"

log "built $APP_BUNDLE"
