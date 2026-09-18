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

# SIGNING, AND WHY IT IS NOT AD-HOC ANY MORE.
#
# An ad-hoc signature gives the bundle a new cdhash on every build. macOS TCC pins each
# permission grant to a code-signing requirement, and for an ad-hoc binary that
# requirement is literally `cdhash H"..."` — verified by reading the requirement back
# out of TCC.db. So every rebuild silently revoked Screen Recording, and the emulator
# capture went black with nothing on screen saying why. Re-granting fixed it until the
# next build, which is what made it look intermittent.
#
# A stable self-signed certificate makes the requirement certificate-based instead, so
# the grant survives rebuilds. Still local-only: not the Apple Developer Program, not
# notarization, not distribution signing, all of which CLAUDE.md rules out.
#
# `scripts/signing-identity.sh` creates it on first run. If it is unavailable — it has
# not been run yet, or the keychain is locked — this FALLS BACK to ad-hoc rather than
# failing the build, because an app that builds and needs its permission re-granted
# beats an app that does not build at all. The log line says which one happened, so a
# black capture is traceable to this rather than mysterious.
# Invoked through bash rather than executed directly: the script lost its exec bit
# once in a git round-trip, and the only symptom was this falling back to ad-hoc
# signing forever with nobody able to see why.
if IDENTITY="$(bash "$REPO_ROOT/scripts/signing-identity.sh" 2>/dev/null)" && [ -n "$IDENTITY" ]; then
  log "signing as '$IDENTITY' (stable — permissions survive rebuilds)"
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP_BUNDLE" 2>&1 | sed 's/^/  /' \
    || fail "codesign failed"
else
  log "ad-hoc signing — NO stable identity; macOS will re-ask for Screen Recording"
  log "  run scripts/signing-identity.sh once to stop that happening every build"
  codesign --force --sign - --timestamp=none "$APP_BUNDLE" 2>&1 | sed 's/^/  /' \
    || fail "codesign failed"
fi

log "built $APP_BUNDLE"
