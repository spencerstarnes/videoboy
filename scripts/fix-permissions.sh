#!/usr/bin/env bash
# fix-permissions.sh — make macOS ask again about Screen Recording.
#
# WHY THIS IS NEEDED. Videoboy is ad-hoc signed, per CLAUDE.md — no Apple Developer
# Program. macOS ties Screen Recording to the exact build it was granted to, so every
# rebuild invalidates the grant. The switch stays ON in System Settings and the capture
# is denied anyway, which reads exactly like a permission you refused and never touched.
#
# Resetting the entry makes macOS forget, so the next launch asks again.
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

BUNDLE_ID="com.spencerstarnes.videoboy"

log "current state"
if [ -d "$APP_BUNDLE" ]; then
  codesign -dv "$APP_BUNDLE" 2>&1 | grep -E "^Identifier|^Signature" || true
fi

log "resetting Screen Recording for $BUNDLE_ID"
tccutil reset ScreenCapture "$BUNDLE_ID" || {
  echo "  tccutil refused. Do it by hand:"
  echo "    System Settings > Privacy & Security > Screen Recording"
  echo "    turn Videoboy OFF, then ON again."
  exit 1
}

log "done — next launch will ask again"
echo
echo "If macOS does not prompt, quit Videoboy completely first: the permission is"
echo "checked when the capture starts, and a process that is already running keeps"
echo "whatever answer it had."
