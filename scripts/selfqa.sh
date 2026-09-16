#!/usr/bin/env bash
#
# selfqa.sh — run one self-QA check and write its artifacts.
#
# Purpose : The single entry point for Claude's three verification channels
#           (docs/SELF-QA-HARNESS.md). Exits non-zero on fail, zero on pass or
#           blocked — absent hardware must not fail a build.
# Usage   : scripts/selfqa.sh <check>
#           offscreen   — render test patterns and graph output headlessly (no hardware)
#           loopback    — capture the DVC100 and write metrics.json (needs hardware)
#           midi        — virtual CoreMIDI detect/learn round-trip (no hardware)
#           all         — every check that can run here
# Outputs : selfqa/out/<check>/{*.png,metrics.json,result.txt}
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

CHECK="${1:-all}"

run_offscreen() {
  log "self-QA: offscreen render checks"
  cd "$REPO_ROOT/Core"
  swift test --filter 'SelfQA|Offscreen|Render'
}

run_midi() {
  log "self-QA: virtual MIDI detect"
  cd "$REPO_ROOT/Core"
  swift test --filter 'MIDI'
}

run_loopback() {
  log "self-QA: DVC100 loopback (needs hardware + camera permission)"
  [ -d "$APP_BUNDLE" ] || fail "no app at $APP_BUNDLE — run scripts/build.sh first"
  # The capture must run from inside the app bundle: macOS attributes the camera
  # permission to the bundle identifier, not to this shell.
  "$APP_BUNDLE/Contents/MacOS/$APP_NAME" --selfqa loopback
}

case "$CHECK" in
  offscreen) run_offscreen ;;
  midi)      run_midi ;;
  loopback)  run_loopback ;;
  all)       run_offscreen; run_midi; run_loopback ;;
  *)         fail "unknown check '$CHECK' (try: offscreen, midi, loopback, all)" ;;
esac
