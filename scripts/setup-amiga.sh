#!/usr/bin/env bash
#
# setup-amiga.sh — get the emulated titler from "nothing" to "ready to boot".
#
# Purpose : Finds the pieces, checks them, writes the config the app reads, and says
#           precisely what is still missing. Everything here is either automatic or a
#           one-line instruction — no step is "figure it out".
# Inputs  : an Amiga CD-ROM or disk images anywhere under ~/Desktop or ~/Downloads,
#           a Kickstart ROM in vendor/system, a libretro core in vendor/cores.
# Outputs : config/amiga.json, and a report.
# Connects: CoreLibrary and TitlerLibrary, which read what this writes.
#
# WHAT THIS DELIBERATELY DOES NOT DO: download anything. A libretro core is GPL and
# must be installed by you rather than fetched by the app, and Kickstart ROMs and
# software are copyrighted. This script finds and checks what you already have.
#
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# _common.sh runs under `set -euo pipefail`, which is right for a build script and
# wrong for one whose whole job is to REPORT on things that may be absent. A `find`
# that matches nothing, or a detach of something never mounted, is an expected
# outcome here rather than a failure — so errexit is relaxed and each step checks
# its own result.
set +e

CORES_DIR="$REPO_ROOT/vendor/cores"
SYSTEM_DIR="$REPO_ROOT/vendor/system"
CONFIG="$REPO_ROOT/config/amiga.json"
mkdir -p "$CORES_DIR" "$SYSTEM_DIR" "$REPO_ROOT/config"

missing=0
note() { printf '  %s\n' "$1"; }

log "looking for Amiga media"

# ── 1. Media ────────────────────────────────────────────────────────────────────
# Searched rather than hardcoded: media lands wherever a browser put it, and asking
# someone to move a 620MB file before anything works is a poor first step.
MEDIA=""
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  MEDIA="$candidate"
  break
done < <(find "$HOME/Desktop" "$HOME/Downloads" -maxdepth 3 \
  \( -iname '*.iso' -o -iname '*.adf' -o -iname '*.hdf' \) 2>/dev/null)

if [ -n "$MEDIA" ]; then
  note "media: $(basename "$MEDIA")"
else
  note "NO MEDIA FOUND — put an Amiga .iso, .adf or .hdf in ~/Desktop or ~/Downloads"
  missing=$((missing + 1))
fi

# ── 2. What is on it ────────────────────────────────────────────────────────────
# Mounted read-only and unmounted again; the image is referenced by path and never
# copied into the repo (user-supplied assets are never bundled).
TITLER_FOUND=""
if [ -n "$MEDIA" ] && [[ "$MEDIA" == *.iso ]]; then
  MOUNT=$(hdiutil attach -readonly -nobrowse "$MEDIA" 2>/dev/null | awk -F'\t' 'END{print $NF}' | xargs || true)
  if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then
    for name in Scala ScalaMM Broadcast TVPaint; do
      if find "$MOUNT" -maxdepth 2 -iname "*${name}*" 2>/dev/null | head -1 | grep -q .; then
        TITLER_FOUND="$name"
        break
      fi
    done
    if [ -f "$MOUNT/S/Startup-Sequence" ]; then
      note "the disc is bootable (it has S/Startup-Sequence)"
    fi
    [ -n "$TITLER_FOUND" ] && note "titling software on the disc: $TITLER_FOUND"
    hdiutil detach "$MOUNT" >/dev/null 2>&1
  fi
fi

# ── 3. Kickstart ────────────────────────────────────────────────────────────────
KICKSTART=""
while IFS= read -r rom; do
  [ -n "$rom" ] || continue
  KICKSTART="$rom"
  break
done < <(find "$SYSTEM_DIR" -iname '*.rom' 2>/dev/null)

if [ -n "$KICKSTART" ]; then
  note "kickstart: $(basename "$KICKSTART")"
else
  note "NO KICKSTART — an Amiga cannot boot without one."
  note "  It is copyrighted: use a ROM from an Amiga you own, or Cloanto's Amiga Forever."
  note "  Put it in vendor/system/ (3.0 or 3.1 for an A1200)."
  missing=$((missing + 1))
fi

# ── 4. Core ─────────────────────────────────────────────────────────────────────
CORE=""
for ext in dylib so; do
  if [ -f "$CORES_DIR/puae_libretro.$ext" ]; then
    CORE="$CORES_DIR/puae_libretro.$ext"
    break
  fi
done

if [ -n "$CORE" ]; then
  note "core: $(basename "$CORE")"
else
  note "NO AMIGA CORE — install puae_libretro into vendor/cores/"
  note "  RetroArch's core downloader is the easiest source. It is GPL, so it runs"
  note "  out of process and is never linked into Videoboy."
  missing=$((missing + 1))
fi

# ── 5. Write what was found ─────────────────────────────────────────────────────
cat > "$CONFIG" <<JSON
{
  "_comment": "Written by scripts/setup-amiga.sh. Paths point OUTSIDE the repo on purpose: user-supplied media is referenced, never copied in.",
  "media": $( [ -n "$MEDIA" ] && printf '"%s"' "$MEDIA" || echo null ),
  "titler_on_media": $( [ -n "$TITLER_FOUND" ] && printf '"%s"' "$TITLER_FOUND" || echo null ),
  "kickstart": $( [ -n "$KICKSTART" ] && printf '"%s"' "$KICKSTART" || echo null ),
  "core": $( [ -n "$CORE" ] && printf '"%s"' "$CORE" || echo null ),
  "machine": "amiga1200Vampire"
}
JSON
note "wrote ${CONFIG#$REPO_ROOT/}"

echo
if [ "$missing" -eq 0 ]; then
  log "ready — everything needed to boot is present"
else
  log "$missing thing(s) still needed; see the notes above"
fi
exit 0
