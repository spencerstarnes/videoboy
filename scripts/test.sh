#!/usr/bin/env bash
# test.sh — fast loop: run the Core unit tests headlessly.
# Usage: scripts/test.sh [extra swift-test args]
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
require_toolchain
require_ffmpeg
log "swift test (Core)"
cd "$REPO_ROOT/Core"
swift test "${FFMPEG_FLAGS[@]}" "$@"
