#!/usr/bin/env bash
#
# warnings.sh — every compiler warning, from a build that actually recompiles.
#
# Purpose : scripts/lint.sh checks `swift build` output for warnings, but an
#           incremental build does not recompile files it considers unchanged, so it
#           reports "clean" while real warnings sit in the code. That is not
#           hypothetical: the overnight session's Phase 1 baseline recorded ONE
#           warning, and a build from scratch found several — including a
#           pointer-lifetime bug in the titler that was genuine undefined behaviour.
# Inputs  : none.
# Outputs : the distinct warnings, with counts, and a non-zero exit if there are any
#           beyond the known-benign ones.
# Connects: scripts/lint.sh (the fast check this backstops), scripts/verify.sh.
# Extend  : add a genuinely benign warning to KNOWN_BENIGN with a comment saying why.
#           Do not add one just to make this pass.
#
# Slow on purpose — it cleans first. Run it before a release or after a session of
# changes, not on every save.
#
source "$(dirname "${BASH_SOURCE[0]}")/../_common.sh"
require_toolchain
require_ffmpeg

# A README living in a source directory on purpose, so SwiftPM cannot classify it.
KNOWN_BENIGN='unhandled resource|found 1 file\(s\) which are unhandled'

log "warnings: cleaning so every file is recompiled"
cd "$REPO_ROOT/Core"
swift package clean >/dev/null 2>&1

log "warnings: building Core from scratch"
swift build "${FFMPEG_FLAGS[@]}" 2>&1 \
  | grep -E '^/.*warning:' \
  | sed "s|$REPO_ROOT/||" \
  | sort -u > /tmp/videoboy-warnings.txt

count=$(wc -l < /tmp/videoboy-warnings.txt | tr -d ' ')
real=$(grep -vcE "$KNOWN_BENIGN" /tmp/videoboy-warnings.txt || true)

if [ "$count" -gt 0 ]; then
  echo
  cat /tmp/videoboy-warnings.txt
  echo
fi

log "warnings: $count distinct ($real after known-benign)"
if [ "${real:-0}" -gt 0 ]; then
  fail "warnings: $real warning(s) need attention"
fi
log "warnings: clean"
