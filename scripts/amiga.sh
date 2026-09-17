#!/usr/bin/env bash
# amiga.sh — run the Amiga setup/link CLI.
#
# A wrapper so nobody has to remember the toolchain and FFmpeg flags:
#   scripts/amiga.sh setup       find what is installed, write the workspace
#   scripts/amiga.sh launch      start FS-UAE on it
#   scripts/amiga.sh panel fontSize 0.8
#   scripts/amiga.sh status      is the machine answering
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
require_toolchain
require_ffmpeg
cd "$REPO_ROOT/Core"
swift run "${FFMPEG_FLAGS[@]}" videoboy-amiga "$@"
