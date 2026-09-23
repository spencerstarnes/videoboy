# DATAMOSH.md — live H.264 datamosh

The **Datamosh · H.264** card, at the bottom of both FX panels. Real datamoshing,
live, on anything: a clip, a camera, a whole bus.

## How to play it

| Fader | Code | What it does |
|---|---|---|
| **mosh** | 35B | 0 = clean. Above 0, keyframes and scene-cut frames never reach the decoder, so the *next* picture's motion is painted onto the *old* picture. Past halfway, ordinary frames drop too and the picture melts even without a cut. **Pull to 0 to heal instantly.** |
| **bloom** | 36B | 0 = off. Above 0, the last 1–8 P-frames replay in a loop (the fader sets the loop length); the same motion keeps pushing, so pixels stream outward. Live frames are held back while it plays. |
| **heal** | 37B | Push past halfway: one clean keyframe comes through (the picture resets), and the mosh carries on from there. Map it to a pad. |
| **blocks** | 38B | Encoder bitrate. Low = starved: big blocks, heavier smear. High = finer. |

**The classic transition:** card on, selector on **BOTH** (the default — the bus copy),
push **mosh** up, then cut or fade A → B. B's motion drags A's picture around until you
heal. On **A** or **B** instead, the card moshes that channel alone, so changing the clip
in that channel moshes one clip into the next.

Every fader takes MIDI learn (Shift-click), LFO, audio and beat sweeps like any other.

## What is actually happening

Nothing here is simulated (compare loopier/datamosh, which fakes it with optical flow).

1. **Encode.** The picture is encoded live to H.264 on the hardware encoder
   (VideoToolbox): no B-frames, keyframes only when asked, BT.601 colour. Every live
   datamosh tool normalises like this first (FFglitch's live mode, the WebCodecs tools):
   one continuous stream, so any frame can follow any other.
2. **Rearrange** (`MoshEngine`). The two classic moves, on whole coded frames:
   *I-frame removal* (mosh) and *P-frame duplication* (bloom). Each slice's `frame_num`
   and picture-order count are rewritten (`H264Syntax`) so the decoder sees one unbroken
   stream and decodes rather than refuses.
3. **Decode** with libavcodec's H.264 decoder: the tolerant decoder moshed files are
   traditionally watched in (VLC, ffplay). Apple's decoder is stricter and is not used.
   It is the LGPL native decoder; no GPL code is involved (x264 is not built).

## Cost (measured 2026-09-23, release build, `selfqa.sh stress`)

All six mosh nodes running (four channels + both buses) on top of the full stress load:
**29.97 fps, 0 dropped, worst tick 19.4 ms** (budget 33.4 ms). About 0.2 ms per node per
tick on the render thread; the codec work runs on each node's own queue.

- At zero (mosh and bloom both 0) a node returns its input and holds no encoder. It
  costs nothing.
- Engaging starts the encoder **off** the render thread; the first frame or two show the
  input while it spins up.
- While active, the output trails the input by about one frame (declared latency).

## Evidence

- `selfqa/out/mosh/`: Core pipeline and node PNGs (clean vs moshed, bloom), timing.
- `selfqa/out/mosh/app/`: the real app, card clicked through the window, a moshed cut.
- `selfqa/out/perf/stress/result.txt`: the load test with all six nodes moshing.

## Files

`Core/Sources/VideoboyCore/Bitstream/H264/` (`H264Syntax`, `MoshEngine`,
`H264LiveEncoder`, `H264MoshDecoder`), `Modules/Effects/DatamoshNode.swift`,
tests in `Core/Tests/VideoboyCoreTests/DatamoshTests.swift`,
the app check `App/Sources/Videoboy/Platform/MoshSelfQA.swift` (`scripts/selfqa.sh mosh`).
