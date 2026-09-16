#!/usr/bin/env bash
# run.sh — launch the built app.
# Usage: scripts/run.sh [--selfqa <check>] [app args]
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
[ -d "$APP_BUNDLE" ] || fail "no app at $APP_BUNDLE — run scripts/build.sh first"
log "launching $APP_BUNDLE"
# Run the binary directly rather than via `open` so stdout/stderr land in this
# terminal, which is how the subsystem logs are read during a self-debug loop.
exec "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "$@"
