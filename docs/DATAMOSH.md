# DATAMOSH.md — live H.264 datamosh

The **Datamosh · H.264** card, at the bottom of both FX panels. Real datamoshing,
live, on anything: a clip, a camera, a whole bus.

## How to play it

| Fader | Code | What it does |
|---|---|---|
| **mosh** | 35B | 0 = clean. Above 0, keyframes and scene-cut frames never reach the decoder, so the *next* picture's motion is painted onto the *old* picture. Higher = smaller changes count as a cut. |
| **melt** | 39B | 0 = off. Ordinary P-frames are dropped at random (up to about one in three), so the error piles up and the picture melts even without a cut. (This used to be the top half of **mosh**.) |
| **bloom** | 36B | 0 = off. The share of frames that are replays of the loop: 1 = every frame (full stream, live frames held back), 0.5 = every other frame, with live motion in between. **Pulling it down slows the stream** instead of doing nothing until 0. |
| **bloom loop** | 3AB | How many P-frames bloom replays: 1 to 16 (readout in frames). Does nothing unless bloom is up. Short = one push, over and over; long = a wobble. |
| **bitrate** | 38B | Encoder bitrate, 0.4–8 Mb/s (readout in Mb/s). Low = starved: big blocks, heavier smear. High = finer. Labelled "blocks" until 2026-09-28, which read backwards (up is FEWER blocks); renamed rather than flipped so saved shows and mappings keep their meaning. |
| **HOLD** | 3FB | A key, and a **hold** (labelled MOSH until 2026-09-28 — the same name as the fader, doing something else). While it is held the card moshes at full whatever the faders say: every frame is a replay of the loop, and keyframes and cuts are dropped, so moving footage streams at once, no cut needed. Let go and the faders are back in charge: at zero, the mosh eases back to clean over the heal time, in the heal shape. Shift-click to learn a MIDI note (note on = press, note off = release). A tap between frames still moshes for one. |
| **HEAL** | 37B | A key, not a fader. Press it: the clean picture eases back in over the **heal time**, in the **heal shape**, and then one clean keyframe comes through. The screen already shows clean by then, so the reset is invisible and the mosh starts again from the clean picture. Shift-click to learn a MIDI note. A tap between frames still counts. **Option-Command-click** arms it on the beat: it sets **heal every** to 1 beat (or the rate it last had) and the key wears the purple automated outline; Option-Command-click again turns it off. A plain click still heals once, at once. |
| **heal every** | 3BB | Heal on the beat: off, 1/16, 1/8, 1 beat, 2 beats, 1 bar, 2 bars, 4 bars. Transport has to be running. |
| **heal time** | 3CB | 0 = instant (a hard reset, the old behaviour) … 2 s. Default 0.5 s. Also sets how long **letting go** takes (see below). |
| **heal shape** | 3DB | How clean comes back: **fade** (dissolve), **blocks** (16×16 macroblocks at random, like intra refresh), **wipe** (macroblock rows from the top, like a refresh sweep), **luma** (brightest first). |
| **opacity** | 01A | How strongly the mosh lies over its own clean input. 0 = clean, 1 = all mosh. |
| **blend** | 3EB | How it combines with the clean picture: normal, multiply, screen, overlay, lighten, darken, difference, add, subtract, dodge, burn, hard light, soft light. |

**The classic transition:** card on, selector on **BOTH** (the default, the bus copy),
push **mosh** up, then cut or fade A → B. B's motion drags A's picture around until you
heal. On **A** or **B** instead, the card moshes that channel alone, so changing the clip
in that channel moshes one clip into the next.

**Mosh on demand:** hold **HOLD**. Nothing else needs to be up; the key starts the
encoder itself (the first frame or two show the input while it spins up), and letting
go eases back out. With the card already running, the mosh starts on the next frame.

**Getting out gracefully:**
- **Pull the faders down.** With mosh, melt and bloom all at 0, the clean picture eases
  back in over the heal time (in the heal shape) and *then* the encoder is released.
  Push back up during the fade and the mosh comes back from where it was.
- **Hit HEAL**, or let **heal every** do it on the beat (Option-Command-click HEAL). A long heal time with **blocks**
  looks like the codec repairing itself.
- **Bring bloom down** to slow a stream before you heal it.
- The card's **switch** is still a hard bypass: off is off, at once.

Every fader takes MIDI learn (Shift-click), LFO, audio and beat sweeps like any other.
The choice faders (heal every, heal shape, blend) step through their choices.

## What others do (researched 2026-09-23)

- **Frame-level datamosh tools** (Avidemux, tomato.py, Datamosher Pro,
  tiberiuiancu/datamoshing): I-frame removal over a range, P-frame duplication
  ("bloom": duplicate N frames), *pulse* (duplicate a group every N frames). Offline,
  file in, file out. Bloom's loop and amount here are the live versions of their
  duplicate count and pulse.
- **FFglitch**: edits motion vectors in the bitstream with scripts. Very expressive,
  but offline or a special live build. It's the next step if this ever needs
  vector-level control (see `BUILD-PLAN.md`, macroblock-level MPEG editing).
- **Datamosh 2 (After Effects)**: Intensity, Acceleration, **Blend** (moshed vs clean),
  Threshold, grey-scale Mosh Maps. The blend-with-clean idea is the **opacity/blend**
  pair here.
- **FFGL Datamosh (Resolume)**: simulated with optical flow, but it has the best live
  vocabulary: Trigger/Hold/Reset, **Auto mode on cuts or beats with a beat divisor**,
  burst length with an ease-out, **Decay** (live image bleeds back as a half-life) and a
  wet/dry Mix. **heal every** and **heal time** are this app's answer to its beat
  divisor and eased exit, on real H.264 rather than a simulation.
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

All six mosh nodes running (four channels + both buses) on top of the full stress load,
each with melt 0.3, bloom 0.5, a blocks heal on every beat and the mosh screened over its
clean input at 0.8, so the layer pass runs on every frame:
**29.97 fps, 0 dropped, worst tick 18.7 ms** (budget 33.4 ms). About 0.2 ms per node per
tick on the render thread; the codec work runs on each node's own queue.

- At zero (mosh, melt and bloom all 0) a node returns its input and holds no encoder. It
  costs nothing.
- Engaging starts the encoder **off** the render thread; the first frame or two show the
  input while it spins up.
- While active, the output trails the input by about one frame (declared latency).
- The layer pass (heal shape, blend, opacity) is one full-screen draw, and only while
  one of them is doing something. A plain full-strength mosh skips it.

## Evidence

- `selfqa/out/mosh/`: Core pipeline and node PNGs (clean vs moshed, bloom), timing.
- `selfqa/out/mosh/app/`: the real app, card clicked through the window, a moshed cut,
  the card itself (`card.png`), a blocks heal half way (`heal-mid-blocks.png`), healed,
  opacity 0.5, the Difference blend.
- `selfqa/out/perf/stress/result.txt`: the load test with all six nodes moshing.

## Files

`Core/Sources/VideoboyCore/Bitstream/H264/` (`H264Syntax`, `MoshEngine`, `MoshHeal`,
`H264LiveEncoder`, `H264MoshDecoder`), the `mosh_layer_fragment` shader in `MetalContext`, `Modules/Effects/DatamoshNode.swift`,
tests in `Core/Tests/VideoboyCoreTests/DatamoshTests.swift`,
the app check `App/Sources/Videoboy/Platform/MoshSelfQA.swift` (`scripts/selfqa.sh mosh`).

## Readouts and tooltips (2026-09-28)

Every control on the card has a tooltip saying what it does. Readouts are in the units a
performer can use: **mosh** and **bloom** say *off* at 0, **melt** shows how many frames it
drops (*1/3* at the top, *rare* below 1 in 99), **bloom** is a percentage, **bloom loop** is
in frames, **bitrate** in Mb/s.
