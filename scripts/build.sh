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
# --disable-build-manifest-caching: App compiles Core as a path dependency, and the
# cached manifest does NOT notice a new file added to Core — the App build then fails
# with "cannot find 'NewType' in scope" while Core itself builds fine. Re-planning
# costs about a second; a new node silently missing from the app costs far more.
swift build -c "$CONFIGURATION" --arch "$VIDEOBOY_ARCH" "${FFMPEG_FLAGS[@]}" --disable-build-manifest-caching
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

# The built-in ISF modules (SPEC 8) — the default effects, as plain .fs files.
# ISFLibrary.builtinFolder looks for them at Contents/Resources/ISF/Builtin.
log "copying built-in ISF modules"
mkdir -p "$APP_BUNDLE/Contents/Resources/ISF"
cp -R "$REPO_ROOT/App/Resources/ISF/Builtin" "$APP_BUNDLE/Contents/Resources/ISF/"

# BeatNet's trained weights and licence (CC BY 4.0), for the beat tracker.
# BeatNetWeights.bundledURL looks for them at Contents/Resources/BeatNet.
log "copying BeatNet weights"
cp -R "$REPO_ROOT/App/Resources/BeatNet" "$APP_BUNDLE/Contents/Resources/"

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
  # NEVER SILENTLY DOWNGRADE. If the signing keychain EXISTS but the identity cannot be
  # seen, this is not "not set up yet" — it is a build that is about to replace a stable
  # signature with an ad-hoc one and void every permission granted to it. That happened:
  # a build run from a context that could not read the keychain re-signed the app
  # ad-hoc, and the Screen Recording grant made minutes earlier stopped matching.
  #
  # The build still proceeds, because a build that refuses to run blocks everything. But
  # it says exactly what it just cost, so nobody has to work it out from a black capture.
  if [ -f "$HOME/Library/Keychains/videoboy-signing.keychain-db" ]; then
    log ""
    log "  ****  WARNING: signing ad-hoc even though a signing keychain EXISTS  ****"
    log "  The identity is not visible from this shell — a locked keychain, or a"
    log "  sandboxed/CI context that cannot read it. This build has just VOIDED"
    log "  Screen Recording and every other permission granted to this app."
    log "  Re-run scripts/build.sh from a normal terminal to restore it."
    log ""
  else
    log "ad-hoc signing — NO stable identity; macOS will re-ask for Screen Recording"
    log "  run scripts/signing-identity.sh once to stop that happening every build"
  fi
  codesign --force --sign - --timestamp=none "$APP_BUNDLE" 2>&1 | sed 's/^/  /' \
    || fail "codesign failed"
fi

log "built $APP_BUNDLE"
