#!/usr/bin/env bash
#
# bootstrap.sh — one-time (idempotent) setup: sample fixtures and vendored deps.
#
# Purpose : Brings a fresh clone to the point where build.sh and test.sh work.
#           Safe to re-run; it skips anything already in place.
# Inputs  : an installed ffmpeg CLI (for generating DV fixtures only).
# Outputs : samples/manifest.json, generated DV/MOV fixtures, config/devices.json.
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

log "bootstrap: samples"
"$REPO_ROOT/scripts/make-fixtures.sh"

log "bootstrap: device config"
if [ ! -f "$REPO_ROOT/config/devices.json" ]; then
  cp "$REPO_ROOT/config/devices.example.json" "$REPO_ROOT/config/devices.json"
  log "created config/devices.json from the example — fill in real device names"
else
  log "config/devices.json already present"
fi

log "bootstrap: done"
