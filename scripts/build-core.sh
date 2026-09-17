#!/usr/bin/env bash
# build-core.sh — compile Core only, without running the tests.
#
# The tightest loop there is: `scripts/test.sh` builds AND runs, which is the right
# default but slow when what you want to know is only "does it still compile". Same
# toolchain and flags as test.sh, so a build that passes here passes there.
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
require_toolchain
require_ffmpeg
cd "$REPO_ROOT/Core"
swift build "${FFMPEG_FLAGS[@]}" "$@"
