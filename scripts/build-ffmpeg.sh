#!/usr/bin/env bash
#
# build-ffmpeg.sh — build a minimal LGPL FFmpeg for arm64 and stage it in vendor/.
#
# Purpose : Videoboy needs libavformat/libavcodec to demux and decode DV, which
#           AVFoundation dropped at macOS 10.15 (SPEC 5). CLAUDE.md requires an
#           LGPL build with no GPL components, so this configures one explicitly
#           rather than using the Homebrew binary (which is --enable-gpl).
# Inputs  : the FFmpeg source tarball from the Homebrew download cache.
# Outputs : vendor/ffmpeg/{lib,include} — shared dylibs plus headers.
# Licence : LGPL v2.1. --disable-gpl and --disable-nonfree are asserted below and
#           verified after configure; the build fails loudly if either slips.
#           Shared libraries, so the LGPL relinking requirement is satisfied the
#           straightforward way (SPEC 5).
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

VENDOR="$REPO_ROOT/vendor/ffmpeg"
WORK="$REPO_ROOT/build/ffmpeg-src"
WORK_DEPS="$REPO_ROOT/build/ffmpeg-deps.txt"
mkdir -p "$REPO_ROOT/build"

# An existing build skips straight to the install-name pass below, which is cheap
# and idempotent, rather than exiting — see the note there.
SKIP_COMPILE=0
if [ -f "$VENDOR/lib/libavcodec.dylib" ] && [ -z "${FFMPEG_REBUILD:-}" ]; then
  log "vendor/ffmpeg already built (set FFMPEG_REBUILD=1 to force a rebuild)"
  SKIP_COMPILE=1
fi

if [ "$SKIP_COMPILE" -eq 0 ]; then

TARBALL="$(brew --cache --build-from-source ffmpeg 2>/dev/null || true)"
if [ ! -f "$TARBALL" ]; then
  fail "FFmpeg source not in the Homebrew cache. Run: brew fetch --build-from-source ffmpeg"
fi

log "unpacking $(basename "$TARBALL")"
mkdir -p "$WORK"
tar -xf "$TARBALL" -C "$WORK" --strip-components=1

cd "$WORK"

# Only what Videoboy actually decodes and emits. A minimal build keeps the bundle
# small and, more importantly, makes it obvious that no GPL-only component is being
# pulled in.
#
# The mpeg2video/mjpeg encoders, the mpegts muxer and the udp protocol are here for
# the OBS send (SPEC 15): OBS reads an MPEG-TS stream over UDP with its own Media
# Source and needs nothing installed on either side. All four are LGPL — the
# --disable-gpl assertion below still holds and is verified after configure.
log "configuring (LGPL, arm64, DV + MPEG family only)"
./configure \
  --prefix="$VENDOR" \
  --arch=arm64 \
  --disable-gpl \
  --disable-nonfree \
  --disable-version3 \
  --enable-shared \
  --disable-static \
  --disable-programs \
  --disable-doc \
  --disable-everything \
  --enable-avcodec \
  --enable-avformat \
  --enable-avutil \
  --enable-swscale \
  --enable-decoder=dvvideo,mpeg1video,mpeg2video,mpeg4,h264,rawvideo,pcm_s16le \
  --enable-encoder=dvvideo,rawvideo,mpeg2video,mjpeg \
  --enable-demuxer=dv,mov,mpegts,mpegps,m4v,h264,rawvideo \
  --enable-muxer=dv,rawvideo,mpegts,mjpeg \
  --enable-parser=dvbsub,h264,mpeg4video,mpegvideo \
  --enable-protocol=file,udp,pipe \
  --enable-neon \
  --disable-audiotoolbox \
  --disable-videotoolbox \
  --disable-securetransport \
  --disable-iconv \
  --disable-sdl2 \
  --disable-debug \
  > "$REPO_ROOT/build/ffmpeg-configure.log" 2>&1 \
  || { tail -30 "$REPO_ROOT/build/ffmpeg-configure.log"; fail "FFmpeg configure failed"; }

# Licence gate. CLAUDE.md: if a GPL component would be pulled in, STOP and report.
LICENCE="$(grep -E '^(CONFIG_GPL|CONFIG_NONFREE)=' config.h ffbuild/config.mak 2>/dev/null | grep -c 'yes\|=1' || true)"
if [ "$LICENCE" -ne 0 ]; then
  grep -E '^(CONFIG_GPL|CONFIG_NONFREE)' ffbuild/config.mak config.h 2>/dev/null | head
  fail "configure produced a GPL or non-free build — refusing to vendor it"
fi
log "licence check: LGPL, no GPL or non-free components"

log "building (this takes a few minutes)"
make -j"$(sysctl -n hw.ncpu)" > "$REPO_ROOT/build/ffmpeg-build.log" 2>&1 \
  || { tail -30 "$REPO_ROOT/build/ffmpeg-build.log"; fail "FFmpeg build failed"; }

log "installing to vendor/ffmpeg"
make install > /dev/null 2>&1 || fail "FFmpeg install failed"

fi  # SKIP_COMPILE

# The dylibs are loaded from inside the .app bundle, so their install names must be
# rpath-relative. Without this the app would only run while vendor/ stays put.
#
# This runs on every invocation, not only after a fresh build, so a library whose
# install name was left absolute by an interrupted run repairs itself. Errors are
# NOT suppressed: a silent failure here produces an app that works on this machine
# and nowhere else, which is exactly the kind of bug that surfaces far too late.
log "rewriting install names to @rpath"
while IFS= read -r dylib; do
  base="$(basename "$dylib")"
  install_name_tool -id "@rpath/$base" "$dylib"
  # Each library also references its siblings by absolute path; fix those too.
  otool -L "$dylib" | awk 'NR>1 {print $1}' | grep "^$VENDOR/lib/" > "$WORK_DEPS" || true
  while IFS= read -r dependency; do
    [ -z "$dependency" ] && continue
    install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$dylib"
  done < "$WORK_DEPS"
done < <(find "$VENDOR/lib" -name '*.dylib' -type f)
rm -f "$WORK_DEPS"

log "verifying install names and arm64 slices"
while IFS= read -r dylib; do
  base="$(basename "$dylib")"
  id="$(otool -D "$dylib" | tail -1)"
  case "$id" in
    @rpath/*) ;;
    *) fail "$base still has a non-rpath install name: $id" ;;
  esac
  lipo -archs "$dylib" | grep -q arm64 || fail "$base has no arm64 slice"
done < <(find "$VENDOR/lib" -name '*.dylib' -type f)

log "vendored libraries:"
find "$VENDOR/lib" -name '*.dylib' -type f -exec basename {} \; | sort | sed 's/^/  /'
