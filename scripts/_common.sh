#!/usr/bin/env bash
#
# _common.sh — shared setup for every Videoboy script.
#
# Purpose : One place for the repo root, the toolchain selection, and the build
#           layout, so the other scripts stay three lines long and agree with
#           each other.
# Inputs  : none. Sourced, not executed.
# Outputs : REPO_ROOT, BUILD_DIR, APP_BUNDLE, DEVELOPER_DIR and friends.
# Extend  : add a variable here rather than repeating a path in two scripts.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
export VIDEOBOY_REPO_ROOT="$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"
APP_NAME="Videoboy"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
export BUILD_DIR APP_NAME APP_BUNDLE

# This machine has Xcode installed but `xcode-select` pointing at the standalone
# Command Line Tools, which ship no Metal compiler. Selecting the full toolchain
# through DEVELOPER_DIR needs no sudo and leaves the system setting alone.
# See docs/ENVIRONMENT.md.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# arm64 only, per CLAUDE.md. Recorded here so every build agrees.
export VIDEOBOY_ARCH="arm64"

log()  { printf '\033[1;36m[videoboy]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[videoboy] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

require_toolchain() {
  command -v swift >/dev/null 2>&1 || fail "swift not found; install Xcode command line tools"
  if ! xcrun --find metal >/dev/null 2>&1; then
    fail "the Metal compiler is unavailable. Install Xcode, or set DEVELOPER_DIR to it."
  fi
}
