#!/usr/bin/env bash
#
# make-fixtures.sh — generate the synthetic sample media the tests need.
#
# Purpose : Phase 1 and 2 need a genuine DV bitstream (real DIF blocks, real DCT
#           coefficients) to demux, decode and corrupt. This generates one, plus a
#           couple of ordinary clips, so the repo is self-sufficient.
# Inputs  : the ffmpeg CLI (a build-time developer tool only — it is NOT linked
#           into the app; see docs/THIRD-PARTY.md for the app's own libav).
# Outputs : samples/*.dv, samples/*.mov, samples/manifest.json.
# Note    : These are synthetic stand-ins. Real-world DV off tape has artefacts no
#           encoder reproduces, so the human's own footage is still wanted for
#           aesthetic work — see docs/BLOCKED.md.
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SAMPLES="$REPO_ROOT/samples"
mkdir -p "$SAMPLES"
# Scratch file for the raw RGB bar pattern, removed once ffmpeg has consumed it.
WORK_RGB="$REPO_ROOT/build/bars-rgb24.raw"
mkdir -p "$REPO_ROOT/build"

command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg CLI not found; install it (brew install ffmpeg) to generate fixtures"

# NTSC DV: 720x480, 29.97, 120000 bytes per frame. `-target ntsc-dv` pins all of it.
#
# The bars are generated here rather than taken from ffmpeg's `smptebars` filter so
# that they match `TestPattern.colorBars` exactly — eight equal bars of known colour.
# That is what lets the decode test assert real colour values and so catch a wrong
# channel order or pixel format, which a generic pattern could not.
if [ ! -f "$SAMPLES/bars.dv" ]; then
  log "generating samples/bars.dv (eight-bar pattern matching TestPattern.colorBars, 4s NTSC DV)"
  python3 - > "$WORK_RGB" <<'RGB'
import sys
# Must stay in step with TestPattern.smpteBarColors in Core.
BARS = [(191,191,191),(191,191,0),(0,191,191),(0,191,0),
        (191,0,191),(191,0,0),(0,0,191),(0,0,0)]
WIDTH, HEIGHT = 720, 480
row = bytearray()
for x in range(WIDTH):
    r, g, b = BARS[min(x * len(BARS) // WIDTH, len(BARS) - 1)]
    row += bytes((r, g, b))
sys.stdout.buffer.write(bytes(row) * HEIGHT)
RGB
  ffmpeg -y -loglevel error \
    -f rawvideo -pix_fmt rgb24 -s 720x480 -framerate 30000/1001 -stream_loop 119 -i "$WORK_RGB" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=4" \
    -shortest -target ntsc-dv "$SAMPLES/bars.dv"
  rm -f "$WORK_RGB"
fi

# Moving content matters: a static picture cannot show whether playback advances,
# and cannot distinguish a dropped frame from a held one.
if [ ! -f "$SAMPLES/motion.dv" ]; then
  log "generating samples/motion.dv (moving test source, 6s NTSC DV)"
  ffmpeg -y -loglevel error \
    -f lavfi -i "testsrc2=size=720x480:rate=30000/1001:duration=6" \
    -f lavfi -i "sine=frequency=220:sample_rate=48000:duration=6" \
    -target ntsc-dv "$SAMPLES/motion.dv"
fi

# An ordinary file for the AVFoundation path, which handles everything that is not DV.
if [ ! -f "$SAMPLES/motion.mov" ]; then
  log "generating samples/motion.mov (H.264, 6s)"
  ffmpeg -y -loglevel error \
    -f lavfi -i "testsrc2=size=720x480:rate=30000/1001:duration=6" \
    -c:v libx264 -pix_fmt yuv420p -crf 18 "$SAMPLES/motion.mov"
fi

# An MPEG-2 elementary stream for the MPEG half of the wedge (SPEC 5). Raw ES rather
# than a container: the corruptor works on the bitstream, and a fixture wrapped in
# mpegts would be testing the demuxer instead of what is being tested.
#
# A short GOP with B-frames, because the whole point of MPEG damage is temporal —
# dropping a predicted picture is only interesting when there are predicted pictures.
if [ ! -f "$SAMPLES/motion.m2v" ]; then
  log "generating samples/motion.m2v (MPEG-2 elementary stream, 6s)"
  # Mandelbrot rather than the bar pattern: MPEG damage is displacement of detail
  # along motion vectors, and a picture of large flat colour areas has almost no
  # detail to displace. This zooms continuously and is dense everywhere, so what the
  # effects do is actually visible rather than merely measurable.
  ffmpeg -y -loglevel error \
    -f lavfi -i "mandelbrot=size=720x480:rate=30000/1001" -t 6 \
    -c:v mpeg2video -pix_fmt yuv420p -b:v 6000k -g 12 -bf 2 \
    -f mpeg2video "$SAMPLES/motion.m2v"
fi

# HEVC tagged `hev1` — the S7 regression fixture (BUGHUNT-2026-09-27). AVAssetReader
# refuses to decode this tag though the same stream tagged `hvc1` plays; the app routes
# it through VideoToolbox directly (HEV1Reader). hevc_videotoolbox writes `hev1`
# unless told otherwise; the tag is forced so an ffmpeg default change can't hide it.
if [ ! -f "$SAMPLES/motion-hev1.mov" ]; then
  log "generating samples/motion-hev1.mov (HEVC tagged hev1, 3s — S7 regression)"
  ffmpeg -y -loglevel error \
    -f lavfi -i "testsrc2=size=720x480:rate=30000/1001:duration=3" \
    -c:v hevc_videotoolbox -b:v 4M -tag:v hev1 "$SAMPLES/motion-hev1.mov"
fi

log "writing samples/manifest.json"
python3 - "$SAMPLES" <<'PY'
import json, os, sys

samples_dir = sys.argv[1]
# DV frames are fixed-size, so a byte count is an exact frame count. 120000 bytes
# is one NTSC DV frame at 25 Mbit/s (SPEC 5).
NTSC_DV_FRAME_BYTES = 120000

entries = []
for name in sorted(os.listdir(samples_dir)):
    path = os.path.join(samples_dir, name)
    if name.startswith('.') or not os.path.isfile(path) or name == 'manifest.json':
        continue
    extension = os.path.splitext(name)[1].lower().lstrip('.')
    if extension not in ('dv', 'mov', 'mp4', 'm2v', 'mpg'):
        continue
    size = os.path.getsize(path)
    entry = {
        'file': name,
        'kind': 'dv' if extension == 'dv' else 'standard',
        'bytes': size,
        'origin': 'generated by scripts/make-fixtures.sh (synthetic)',
    }
    if extension == 'dv':
        entry['frameBytes'] = NTSC_DV_FRAME_BYTES
        entry['frameCount'] = size // NTSC_DV_FRAME_BYTES
        entry['standard'] = 'NTSC'
        entry['width'] = 720
        entry['height'] = 480
    entries.append(entry)

manifest = {
    'note': 'Generated by scripts/make-fixtures.sh. Drop real media in samples/ and re-run to include it.',
    'samples': entries,
}
with open(os.path.join(samples_dir, 'manifest.json'), 'w') as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write('\n')
print(f'  {len(entries)} sample(s) indexed')
PY

log "fixtures ready"
