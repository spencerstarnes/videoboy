# SELF-QA-HARNESS.md

How Claude Code verifies its own output without the human. Build this in Phase 0 before anything else — it is the "eyes" every later phase depends on. Keep it behind protocols so `Core` builds and tests headlessly whether or not hardware is attached.

## Three verification channels

### 1. Offscreen render → PNG (primary; no hardware, no permissions)
Render any point in the graph (a source, a bus, PRIMARY, or an effect's output) to an offscreen `MTLTexture`, read it back, and write a PNG to `selfqa/out/<check>/`. This is the default way to check *content*: is the video playing, did the bitstream corruptor actually change pixels, is the composite/crossfade correct, is the test pattern right.
- Deterministic where possible: seed the corruptor so the same input yields the same output, so a check is repeatable and diffable.
- Fast: no display, no capture device, runs in CI-style loops.

### 2. DVC100 loopback → PNG + metrics (verifies the real output path)
Physical loop: app → HDMI output card → HDMI-to-RCA → DVC100 → macOS as a UVC/AVCapture device. Claude captures the *actual analog-facing signal* — the thing offscreen rendering can't see.
- Capture N seconds, write sample PNG frames + `metrics.json`.
- `metrics.json` must include: `capturedWidth`, `capturedHeight`, `effectiveFps` (from frame timestamps), `droppedFrames`, `duplicateFrames`, `combingScore` (interlace comb detector: measure high-frequency vertical difference between adjacent rows — high = interlaced/combing present), `signalPresent` (non-black variance over threshold), and the app's own `loggedOutputMode` for comparison.
- The DVC100 captures NTSC-rate SD; treat that as the reference. Verifying "SD output is real" = the captured signal is stable at the expected rate, not dropping/duplicating frames wildly, and matches the mode the app logged.
- Behind a `CaptureSource` protocol with a `MockCaptureSource` (returns a canned frame + metrics) so builds/tests pass with no device attached. If the real device is absent at run time, checks that need it report `blocked`, not `fail`.

### 3. Virtual MIDI (verifies control without the physical deck)
Create a virtual CoreMIDI source in a test, send Note/CC messages, and assert shift-to-detect learns them and that mapped params move. No hardware needed. The physical controller is only for the human's later hands-on QA.

## What each phase checks with these
- Phase 1 (headless): offscreen isn't needed for pure byte transforms — assert on buffers directly. Optionally dump a decoded corrupted frame to PNG to eyeball datamosh.
- Phase 2: offscreen PNGs for playback + on-beat corruption; DVC100 loopback for output-mode/fps/combing; virtual MIDI for detect.
- Phase 3: DVC100 loopback for composite look + feedback round-trip timing.

## Layout & conventions
```
selfqa/
  out/<phase-or-check>/     PNGs, metrics.json, a short result.txt (pass/fail/blocked + why)
scripts/selfqa.sh <check>   runs one check, writes artifacts, exits non-zero on fail
config/devices.json         which display is the HDMI card, which device is the DVC100
samples/ + samples/manifest.json   test media (must include a real .dv)
```

## How Claude "sees" the result
- Open the PNGs directly and inspect them (you have vision).
- Read `metrics.json` / `result.txt` for the numeric facts (fps, combing, dimensions) a still can't show.
- On failure: read the artifacts, hypothesize, fix, re-run `scripts/selfqa.sh` — iterate. Only escalate to the human if it's a hardware/permission/sample blocker.

## Honest limits (still human-only, later)
Subjective feel, aesthetic judgment, the physical MIDI deck's ergonomics, and final "does it look right on my CRT" are human QA. The harness gets the app to *provably launches, plays, corrupts on beat, and emits a valid SD signal* — enough for a working first sit-down — not to certify it feels good.
