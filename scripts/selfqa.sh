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
#           transitions — every crossfader wipe/slide/iris pattern, plus the UI key (no hardware)
#           ave5 — the AVE-5 wipe block: the manual's table, live DV, and the popover in a
#                  real window (keys by hit-test, Shift-learn, MIDI key, pitch bend)
#           displays    — what displays exist and what mode they offer
#           output      — the borderless output window on the HDMI card (needs hardware)
#           loopback    — capture the DVC100 and write metrics.json (needs hardware)
#           stress      — real window, live display link, all 4 channels + every effect
#           soak        — stress for minutes with performer actions; memory, GPU, threads,
#                         fds and slow-tick attribution (VIDEOBOY_SOAK_MINUTES, _CLIPS)
#           decode      — per-file decode cost on the main thread (VIDEOBOY_BENCH_CLIPS)
#           bars        — a 16:9 clip: black bars in the graph, caution stripes in its monitor
#           import      — 1,000 clips dropped mid-show: no stutter, status bar, catalog, ✕
#           modes       — mode bar (0.4.8): strip-only layout change, hitTest, ⌘1–3, live switches
#           import-mode — Import mode (0.4.9): Add/Move/Copy end to end, scratch catalog
#           ab-roll     — A/B ROLL + ADV: four combinations by real keys, BEAT, MIDI, budget
#           fullscreen  — the real window at full-screen size: every scope key, hovered
#                         sources, the Generators tab, photographed
#           push-fade   — clips in A and C, Push on the centre fader, FADE and a sweep:
#                         every frame on the automation curve, previews evenly paced
#           mosh        — the Datamosh card, clicked for real; a cut moshed on the A/B bus
#           calibrate   — measure the physical feedback round trip (needs hardware)
#           shaders     — the Preferences Shaders pane: import copies, − removes, in a real window
#           library     — the three libraries in a real window: icon/list/column, bins,
#                         selection, drag, copy/paste, Select All
#           isf         — ISF modules end to end: Add menu, faders, reorder, MIDI, hot reload, generators
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
  transitions) run_app_check transitions ;;
  ave5)      run_app_check ave5 ;;
  calibrate) run_app_check calibrate ;;
  stream)    run_app_check stream ;;
  record)    run_app_check record ;;
  audit)     run_app_check audit ;;
  shaders)   run_app_check shaders ;;
  library)   run_app_check library ;;
  isf)       run_app_check isf ;;
  # Opens a real window on the main display and runs the live display link under full
  # load for ~10 s. Needs a logged-in GUI session, so it is opt-in, not part of `all`.
  stress)    run_app_check stress ;;
  # stress for minutes, with performer actions, watching memory/GPU/threads/fds.
  # VIDEOBOY_SOAK_MINUTES sets the length (default 10). Opt-in like stress.
  soak)      run_app_check soak ;;
  # Per-file decode cost on the main thread; VIDEOBOY_BENCH_CLIPS adds real footage.
  decode)    run_app_check decode ;;
  # A 16:9 clip (VIDEOBOY_BARS_CLIP): black bars on air, striped in the monitor.
  bars)      run_app_check bars ;;
  # 1,000 clips in 25 folders dropped mid-show: no stutter, status bar, catalog, cancel.
  import)    run_app_check import ;;
  # The mode bar (0.4.8): strip change only, hitTest, ⌘1–3, live mode switches with no
  # dropped frame, Settings mode, setup assistant. Real window; opt-in like stress.
  modes)     VIDEOBOY_FLAGS="${VIDEOBOY_FLAGS:+$VIDEOBOY_FLAGS,}modeBar" run_app_check modes ;;
  # Import mode (0.4.9): Add / Move / Copy end to end on scratch folders and a scratch
  # catalog, badges, greying, DUP, the viewer. Real window; opt-in.
  # A/B ROLL + ADV on the sub-mix faders: the four combinations by real CUT/FADE,
  # BEAT, MIDI, layout, frame budget. Real window; opt-in.
  ab-roll)   run_app_check ab-roll ;;
  import-mode) VIDEOBOY_FLAGS="${VIDEOBOY_FLAGS:+$VIDEOBOY_FLAGS,}modeBar" run_app_check import-mode ;;
  push-fade) run_app_check push-fade ;;
  # The real window at the main screen's full size, all four channels playing, every
  # scope key pressed and photographed. Needs a GUI session; opt-in like stress.
  fullscreen) run_app_check fullscreen ;;
  # The Datamosh card driven through real clicks on a real window; needs a GUI
  # session like stress, so it is opt-in too.
  mosh)      run_app_check mosh ;;
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
    run_app_check transitions
    run_app_check ave5
    run_app_check stream
    run_app_check record
    run_app_check audit
    run_app_check shaders
    run_app_check isf
    run_loopback
    run_app_check calibrate
    ;;
  *) fail "unknown check '$CHECK' (try: offscreen, midi, ui, playback, analog, blend, transitions, ave5, stream, record, audit, shaders, library, isf, stress, soak, decode, bars, import, modes, import-mode, ab-roll, push-fade, fullscreen, mosh, displays, output, loopback, calibrate, emu, emu-probe, all)" ;;
esac
