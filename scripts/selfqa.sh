#!/usr/bin/env bash
#
# selfqa.sh — run one self-QA check and write its artifacts.
#
# Purpose : The single entry point for Claude's three verification channels
#           (docs/SELF-QA-HARNESS.md). Exits non-zero on fail, zero on pass or
#           blocked — absent hardware must not fail a build.
# Usage   : scripts/selfqa.sh <check>
#           offscreen   — render test patterns and graph output headlessly (no hardware)
#           midi        — virtual CoreMIDI detect/learn round-trip (no hardware)
#           ui          — the window shell at three breakpoints (no hardware)
#           playback    — the live graph: playback, fader, the wedge (no hardware)
#           analog      — the composite codec, echo and feedback chain (no hardware)
#           blend       — every layer blend mode over real pictures (no hardware)
#           displays    — what displays exist and what mode they offer
#           output      — the borderless output window on the HDMI card (needs hardware)
#           loopback    — capture the DVC100 and write metrics.json (needs hardware)
#           stress      — real window, live display link, all 4 channels + every effect
#           calibrate   — measure the physical feedback round trip (needs hardware)
#           all         — every check that can run here
# Outputs : selfqa/out/<check>/{*.png,metrics.json,result.txt}
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

CHECK="${1:-all}"

run_offscreen() {
  log "self-QA: offscreen render checks"
  require_ffmpeg
  cd "$REPO_ROOT/Core"
  swift test "${FFMPEG_FLAGS[@]}" --filter 'SelfQA|Offscreen|Render'
}

run_midi() {
  log "self-QA: virtual MIDI detect"
  require_ffmpeg
  cd "$REPO_ROOT/Core"
  swift test "${FFMPEG_FLAGS[@]}" --filter 'MIDI'
}

run_loopback() {
  log "self-QA: DVC100 loopback (needs hardware + camera permission)"
  [ -d "$APP_BUNDLE" ] || fail "no app at $APP_BUNDLE — run scripts/build.sh first"
  # The capture must run from inside the app bundle: macOS attributes the camera
  # permission to the bundle identifier, not to this shell.
  "$APP_BUNDLE/Contents/MacOS/$APP_NAME" --selfqa loopback
}

# The checks that live inside the app bundle, because they need a bundle identity
# (camera permission) or a real NSApplication (display enumeration, view rendering).
run_app_check() {
  [ -d "$APP_BUNDLE" ] || fail "no app at $APP_BUNDLE — run scripts/build.sh first"
  "$APP_BUNDLE/Contents/MacOS/$APP_NAME" --selfqa "$1"
}

case "$CHECK" in
  offscreen) run_offscreen ;;
  midi)      run_midi ;;
  loopback)  run_loopback ;;
  ui)        run_app_check ui ;;
  playback)  run_app_check playback ;;
  output)    run_app_check output ;;
  displays)  run_app_check displays ;;
  analog)    run_app_check analog ;;
  blend)     run_app_check blend ;;
  calibrate) run_app_check calibrate ;;
  stream)    run_app_check stream ;;
  record)    run_app_check record ;;
  audit)     run_app_check audit ;;
  # Opens a real window on the main display and runs the live display link under full
  # load for ~10 s. Needs a logged-in GUI session, so it is opt-in, not part of `all`.
  stress)    run_app_check stress ;;
  # Opt-in, like loopback: it launches another application and needs Screen Recording.
  # Deliberately NOT in `all` or in verify.sh — a check that fails on a machine with no
  # emulator installed is a check that stops being read.
  emu)       run_app_check emu ;;
  emu-probe) run_app_check emu-probe ;;
  all)
    run_offscreen
    run_midi
    run_app_check ui
    run_app_check playback
    run_app_check analog
    run_app_check blend
    run_app_check stream
    run_app_check record
    run_app_check audit
    run_loopback
    run_app_check calibrate
    ;;
  *) fail "unknown check '$CHECK' (try: offscreen, midi, ui, playback, analog, blend, stream, record, audit, stress, displays, output, loopback, calibrate, emu, emu-probe, all)" ;;
esac
