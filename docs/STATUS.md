# STATUS.md

Section-by-section against `docs/SPEC.md`, as of `v0.4.0-benchmark` + current work.

Legend: **✅ done** · **◐ partial** · **○ not started** · **⊘ deliberately deferred**

Counts come from `scripts/selfqa.sh audit` (500 controls: 214 live, 286 disabled,
0 enabled-but-unwired) and `scripts/test.sh` (192 tests green).

---

## The centre of the app

| § | Feature | State |
|---|---|---|
| 5 | **DV demux + decode via libav** | ✅ |
| 5 | **DIF corruptor before decode** — drop/dup/shuffle blocks, DCT zero/flip, sequence swap/hold | ✅ all six, deterministic from a seed |
| 5 | Clock-schedulable, MIDI-mappable corruptors | ✅ |
| 5 | **MPEG bitstream corruptor** — frame drop, motion vectors, reference hold | ○ declared as a family, not written |
| 9 | **CompositeCodec** — NTSC encode→decode, dot crawl, chroma bleed, ringing | ✅ real signal model |
| 9 | 4:1:1 / 4:2:2 subsampling · composite vs S-Video · TBC wobble · head-switching · generation loss | ✅ |
| 3 | Output to the HDMI card, mode negotiated **and logged** | ✅ |
| 3 | Force 480i/480p | ⊘ macOS refuses the mode (`isUsableForDesktopGUI` false) — logged, not guessed |
| 10 | Feedback round-trip latency **measured on the rig** | ✅ 3 frames / 100 ms |

**This is the wedge, and it is done.** The analog loopback is verified end to end
through the DVC100 at 30.000 fps with 0 dropped frames.

---

## By section

### 1 · 1.5 — Stack and code standards
✅ Swift/AppKit/Metal · libav for DV (LGPL, verified) · plain-text templates ·
ad-hoc signed `.app` · file headers, doc comments, param codes, feature flags,
graceful degradation, tests on the fragile bones · `Modules/_Template/` now present.
○ Core Image bridge · OSC.

### 2 — Core architecture
✅ Graph as data · fixed A/B→ONE, C/D→TWO (asserted by a test, not just intended).
○ "Simple mode" toggle (disable C/D/TWO and hide them).

### 3 — Output path
✅ Display enumeration · borderless window · mode negotiation logged · SD project
format. ◐ Display Router is a popup, not the full per-destination router.
○ Decoupled decode/render/present rates are partial — sources are retimed, but
there is no explicit present-rate control.

### 4 — Two clocks
✅ Render clock (display-linked) · transport · subdivisions · **latency compensation**
(scheduled at `T − latency`, unit-tested) · tap tempo · audio beat detection with
adaptive onset threshold and autocorrelation tempo.
○ Manual BPM entry field · MIDI clock in · Ableton Link.

### 6 — Sources
✅ DV stream · test pattern · generators · capture node (built, not routed live).
✅ **AVFoundation path for ordinary video** — `AVFClipDecoder` plays anything
AVFoundation opens; `.mov`, `.mp4`, ProRes, H.264. The MPEG families go through the
bitstream decoder instead so the wedge still has a packet to damage. This was listed
as "the biggest single gap" long after it was closed.
✅ **Photo folder as a beat-locked clip** (SPEC §153) — a folder is one clip, not a
bin of stills: `ImageSequenceDecoder` orders the frames naturally (frame10 does not
sort between frame1 and frame2), the library badges it `SEQ`, and loading one sets
**one frame per quarter note** so it arrives locked to the beat rather than flickering
past at 29.97. The STEP ladder walks either way from there, and loop / ping-pong /
one-shot all work because it is an ordinary clip from there on.
○ Screen capture (`ScreenCaptureKit`) · IP in · SVG · titler.
◐ Clip bin: folders of clips become bins and folders of images become clips; there is
still no tagging, and no drag-to-channel from the grid.

### 6A — Generators
✅ All twelve of the base set · NTSC out-of-gamut check · **transport LFO** with
seven shapes, subdivision or free-run rate, depth, phase, polarity, invert —
evaluated at a future time so beat-synced motion lands on the beat.
○ Colour wells for generator colours.

### 7 — Control
✅ Core MIDI in · Note/CC · **shift-to-detect learn** from the M badges · param codes
as mapping targets · one normalised ControlEvent bus.
○ 14-bit CC · NRPN · MIDI clock · controller fingerprinting · OSC · the ⇧ Learn
button and hold-Shift highlight.

### 8 — Effects module system (ISF)
○ **Not started.** The single largest remaining piece of scope.

### 9 — Effects
✅ CompositeCodec · echo/trails · MX-1 set (negative, B&W, mosaic, posterize,
mirror, flip, rotate, freeze) — *built and tested but not yet placed in a chain*.
○ Core Image / AU passthrough.

### 10 — Capture + feedback
✅ Internal feedback with frame delay, gain, zoom, rotate, luma key · **measured
round-trip calibration** · DVC100 read out-of-process (GPL, never linked).
◐ Capture as a live source node exists but is not routed into a channel.
○ External feedback through the physical loop is not wired to the node's history input.

### 11 — CRT features
✅ Safe zones · overscan · test pattern as source **and** routed output · BFI ·
crosshatch/grid · software interlacing with field order (built, not routed).

### 12 — Mixing + shuttle
✅ Fixed routing · three crossfaders · Cut · Swap · **all 13 blend modes** with the
fader acting as opacity and pure sources at both ends · every preview · shuttle with
play/loop/ping-pong/one-shot/scrub/step-frame · **step playback** locked to the beat.
○ Auto-fade · cut-on-beat · in/out points · VDMX-style routing highlight.

### 13 — Parameter addressing
✅ **Complete.** Stable codes · mappings target codes not instances · swapping a
module preserves mappings whose codes survive, and dangling ones are kept, not
deleted · serialised in templates.

### 14 — UI
✅ The 5×5 grid · all panels · real AppKit controls · docked, collapsible, never
movable · width-reactive at three breakpoints · **four collapsible panel groups**
folding to rails · one `Theme` token file.
Owner revisions since: custom faders, two-line effect rows, joined panels, record
top-right, per-preview arm indicators, drag-across switches. SPEC §14 updated to
match rather than left in conflict.

### 15 — Routing + recording
◐ Arming per feed (A/B/C/D/1/2/P) with transport-locked pulse.
○ **No encoder** — no `AVAssetWriter`, no discrete recording, no timecode.
○ Routing/send panel · IP out.

### 16 — Templates
✅ Plain-text JSON · round-trip tested · unknown codes preserved, never fatal ·
version field.
○ Not wired to the File menu — no save/load from the interface yet.

### 17 · 18 · 19 — SVG/PS1, titlers, scopes
○ **Not started.** All three are self-contained later phases.

---

## Non-negotiables (§21) — all holding

| Rule | State |
|---|---|
| A/B→ONE, C/D→TWO fixed | ✅ asserted by a test |
| No DMX / external hardware beyond MIDI/OSC/capture/displays | ✅ |
| GPL components out-of-process, never linked | ✅ the `dvc100` tool is spawned, not linked |
| App outputs no audio; audio in is for detection only | ✅ |
| Default SD 4:3 | ✅ |
| DV never through AVFoundation; FFmpeg LGPL | ✅ verified, build fails if GPL creeps in |
| Stable param codes, mappings target codes | ✅ |
| Templates plain text, unknown codes non-fatal | ✅ |
| Latency-compensate the musical clock | ✅ unit-tested |
| Verify each phase on real hardware | ✅ loopback + feedback calibration on the rig |

One outstanding: **"verify a cut-on-beat visibly lands on the beat on the CRT"** —
cut-on-beat is not built, so this cannot be checked yet.

---

## What I would do next, in order

1. **AVFoundation source** for non-DV video. The single biggest gap: right now a
   `.mov` cannot be played at all, which limits any real session.
2. **The source-side data-effect drawer** — codec-aware, collapsing from the source
   panel, pulsing when it becomes available. The model is in; the drawer is not.
   This also takes the DV corruptor out of the Sub Mix FX chain, where it implies it
   is a bus effect and only reaches source A.
3. **Cut-on-beat and auto-fade**, which closes the last non-negotiable.
4. **Recording** — arming already works and says it is not built.
5. **ISF host**, the largest remaining scope item.
