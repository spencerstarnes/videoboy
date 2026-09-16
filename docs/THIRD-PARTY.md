# THIRD-PARTY.md

Everything vendored into the app, with its licence.

## FFmpeg (libavcodec, libavformat, libavutil, libswscale)

| | |
|---|---|
| Version | 9.0.1 |
| Licence | **LGPL v2.1 or later** |
| Linkage | **Shared** (`.dylib`), embedded in `Videoboy.app/Contents/Frameworks/` |
| Architecture | arm64 |
| Built by | `scripts/build-ffmpeg.sh` |
| Source | the FFmpeg 9.0.1 release tarball, obtained through the Homebrew download cache |

### Why it is here

macOS dropped the QuickTime 7 codec path at 10.15, so AVFoundation cannot decode DV
(SPEC 5). DV is the centre of this app, so libavcodec does that decoding.

### How the LGPL obligation is met

- **Configured `--disable-gpl --disable-nonfree --disable-version3`.** The configure
  step prints `License: LGPL version 2.1 or later`, and `scripts/build-ffmpeg.sh`
  fails the build if `CONFIG_GPL` or `CONFIG_NONFREE` is set. No GPL-only component
  (x264, x265, libsmbclient, and the rest) is enabled.
- **Linked dynamically.** The libraries are shared objects loaded from the bundle's
  `Frameworks` directory, so the relinking freedom the LGPL requires is satisfied in
  the straightforward way — a user can replace the dylibs with their own build.
- **Source availability.** The exact source is the published FFmpeg 9.0.1 release,
  and the configure flags used are recorded in `scripts/build-ffmpeg.sh`, which is in
  this repository.
- This file is copied into `Videoboy.app/Contents/Resources/THIRD-PARTY.md` at build
  time, so the shipped app carries its own licence notice.

### What is enabled

Decoders `dvvideo, mpeg1video, mpeg2video, mpeg4, h264, rawvideo, pcm_s16le`;
encoders `dvvideo, rawvideo, mpeg2video, mjpeg`;
demuxers `dv, mov, mpegts, mpegps, m4v, h264, rawvideo`;
muxers `dv, rawvideo, mpegts, mjpeg`;
protocols `file, udp, pipe`.
Everything else is disabled — a smaller surface and an easier licence story.

The `mpeg2video` encoder, the `mpegts` muxer and the `udp` protocol are there for the
OBS send (`MPEGTSStreamer`). All three are LGPL; `--disable-gpl` and
`--disable-nonfree` are still asserted and verified after configure, and the build
fails loudly if either slips.

## The `ffmpeg` command-line tool

`scripts/make-fixtures.sh` calls the Homebrew `ffmpeg` binary to generate the test
media in `samples/`. That binary is a **GPL** build, and it is deliberately **not**
linked into or shipped with the app — it is a developer-machine tool used to produce
test files, in the same category as a text editor. The app itself links only the LGPL
libraries described above.

## Everything else

No other third-party code is vendored. There are no SwiftPM package dependencies
beyond the two local packages (`Core` and `App`).

Later phases add libretro emulator cores, which are **GPL**. Those must run
out-of-process and must never be linked (CLAUDE.md), so they will not appear in this
list as linked components.
