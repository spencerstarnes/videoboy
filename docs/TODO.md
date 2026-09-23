# TODO.md

What works, what doesn't, and what's next.

Generated against the control audit: `scripts/selfqa.sh audit` walks the built
window, finds every control, and reports whether it is enabled and wired. Re-run it
after any UI change — it is the authority, not this list's prose.

**Current: 447 controls — 198 live, 249 disabled, 0 enabled-but-unwired.**

"Enabled but unwired" is the dangerous state: a control that looks usable and does
nothing. The audit fails the build if any appear. Everything not built is *disabled*,
which is honest.

---

## Works now — safe to lean on in a session

| Area | What |
|---|---|
| **The wedge** | DV DIF corruptor: 6 modes, amount/mode/rate/seed, on the beat |
| **Playback** | Load a `.dv`, play, loop / ping-pong / one-shot, scrub, step, jump to ends |
| **Mixing** | A→B, C→D, ONE→TWO faders; Cut; Swap; all 13 blend modes |
| **Analog chain** | NTSC composite codec, echo/trails, feedback tunnel — on both buses |
| **Generators** | 12 synthetic sources, assignable to any channel, LFO on phase |
| **Clock** | Tempo, tap, play, subdivision; audio beat detection |
| **Modulation** | M/S/C badges on every FX parameter: MIDI learn, audio taps, LFOs |
| **CRT** | Safe zones, overscan, BFI, test pattern (routed through the graph) |
| **Output** | Borderless window on the HDMI card, mode negotiated and logged |
| **Panels** | Four collapsible groups, Resolve-style, folding to labelled rails |
| **Record** | Arming per feed (A/B/C/D/1/2/P) with transport-locked pulse |

---

## Disabled and labelled — present, inert, waiting on their feature

### Needs real work

- **Record / Stream encoders** (SPEC §15). Arming and the indicators are real; there
  is no `AVAssetWriter` behind them. Pressing record says so.
- **Asset Browser**: tabs, search, import, grid/list. The grid renders from
  `samples/manifest.json`; nothing filters or imports.
- **Library page / search** on both sub-mix libraries.
- **Load Asset / Save** on the FX chains — effect-chain presets.
- **Effect ✕ (remove)** and the per-effect enable switch on unbuilt effects.
- **⇧ Learn** button — MIDI learn works from the M badges; the toolbar button and the
  hold-Shift highlight of mappable controls are not wired.
- **Fader Fade / Auto / Beat** — timed crossfades and cut-on-beat. The scheduler
  exists; the mixer is not subscribed to it.
- ~~**Non-DV playback.**~~ DONE. `AVFClipDecoder` plays anything AVFoundation
  opens; a folder of photographs plays as a beat-locked clip (SPEC §153). The
  MPEG families still route through the bitstream decoder so the wedge keeps a
  packet to damage.

### Deliberately deferred (Phase 4+ backlog)

ISF/FFGL host · Core Image passthrough · Core Text titler · libretro titler
(GPL, out-of-process) · NTSC scopes · SVG/PS1 source · IP in/out · Syphon ·
routing/send panel · MIDI clock and Ableton Link as clock sources.

---

## Known limitations

- **macOS refuses the HDMI card's 720×480 mode** (`isUsableForDesktopGUI` is false).
  The program is scaled into the card's current mode and the negotiated mode is
  logged, never guessed. The analog chain still works — the loopback proves it.
- **The DVC100 is on S-Video, not composite**, on this rig. Recorded in
  `config/devices.json`. The wrong connector returns a valid, perfectly *black*
  picture, which looks exactly like a dead output stage.
- **Only one process can hold the DVC100** — quit `DVC100.app` before the loopback.
- **Sample media is synthetic.** Real DV off tape has artefacts no encoder makes.
- **MX-1 effects** (negative, B&W, mosaic, posterize, mirror, flip, freeze) are built
  and tested but not placed in a chain, so they have no controls.
- **Generator colours** have no colour well.
- **Modulation assignment is on FX parameters only** — the badge columns on the
  faders and shuttles are decorative.

---

## Open questions being worked on

### 1. Data effects are codec-specific, and currently misplaced

The DIF corruptor only means anything for DV: it rewrites DIF blocks before decode.
For an MPEG-family file the equivalent transforms are different (drop P/B frames,
corrupt motion vectors, hold references). For a still image or a generator there is
no compressed bitstream at all and **nothing to offer**.

It is also in the wrong place in the interface. It runs on the *source* — correctly,
since it must happen before decode — but it is shown inside the Sub Mix 1 FX chain,
which implies it is a bus effect, and it only reaches source A.

**Direction:** a separate class of **data effect**, living in its own stack that
opens from the source panel. Closed by default; opening it shrinks the sub-mix FX
stack. Its contents follow the loaded media's codec — DV footage gets DV data
effects, MPEG gets MPEG ones, anything without a compressed bitstream makes the
stack vanish entirely. When footage is loaded that has data effects available, the
closed stack pulses once so the option is noticed.

### 2. Data effects on the bus

The same idea applies after mixing, but a bus does not have a codec — it is a
texture. To corrupt a *mix*, the bus has to be re-encoded first.

**This is feasible.** The vendored LGPL FFmpeg has the DV **encoder** compiled in
(verified), so the path is: mixed texture → read back → encode to DV → corrupt the
DIF bytes → decode → texture. Intra-frame, ~120 KB per frame, no GOP latency.

**Direction:** an **interchange codec** popup per bus — None / DV. Choosing DV
inserts the encode-corrupt-decode stage and populates that bus's data-effect stack
with the DV set. Choosing None removes both. MPEG interchange is the more
interesting one for datamosh and needs the encoder enabling in the FFmpeg build plus
handling of inter-frame latency; it is not done.

**Cost to be measured before this ships:** a readback plus encode plus decode per
frame, per bus. If it will not hold 29.97 it is not worth having, and the honest
answer may be that it runs on PROGRAM only.

---

# Everything outstanding — as of 2026-09-18

Written after the overnight render-path audit (`docs/AUDIT-2026-09-18.md`) and a
session of fixes. Ordered by what unblocks what, not by severity.

## Blocked on a human — nothing else in this file matters until the first one is done

1. **Run `scripts/signing-identity.sh`.** Once, ever. Until then the build is ad-hoc
   signed, every rebuild mints a new cdhash, and macOS TCC — which pins each grant to
   a code-signing requirement — silently revokes Screen Recording, Camera and
   Microphone. Read back out of `TCC.db`, the requirement is literally
   `cdhash H"..."`. This is why emulator capture "randomly" stops working and why
   re-granting only helps until the next build. `build.sh` says which branch it took.
   Creating a keychain is a system change an agent cannot make.
2. **Report what the EMU panel now says.** It surfaces the host's own
   `unavailableReason` instead of showing "Booting the machine…" for all four ways it
   can fail. That sentence decides whether the remaining EMU problem is permission,
   capture attach, window matching, or something else.

## Render-path bugs still open

Nine of the audit's eighteen confirmed findings are fixed. These remain:

| | Severity | What | Bites at |
|---|---|---|---|
| C6 | High | `MPEGTSStreamer.send` — MPEG-2 encode + blocking socket write on the render thread | Immediately when a stream route opens |
| C8/C9 | Medium | `AudioInput.consume` allocates and does `O(n)` work on the AUDIO thread; `stop()` races an in-flight tap block | Audio clock on; any clock-source switch |
| C12/C14 | Medium | BGRA→RGBA→BGRA, then a third swizzle in `FrameRecorder` | Continuous — ~4 ms/frame of a 33.4 ms budget |
| C15 | Medium | Eight `nextDrawable()` per frame on main; one blocked call stalls up to a second | Drawable pressure |
| C17 | Low | Evaluation order and edge lookups re-derived with fresh allocations every frame | Continuous, small |
| C18 | Low | `Engine.stop()` / `OutputRouter.closeAll()` never called; display link retains the engine | Quit — streams never get a trailer |

**C12/C14 should be one change**: a BGRA-native `ImageBuffer` path, ideally alongside
a `CVMetalTextureCache`. Doing them separately means touching the same three call
sites twice. It is also the change most likely to introduce a colour-channel bug, so
it wants the scope checks and `PictureVariety` re-run afterwards, not just `swift test`.

Suspected, each needing a runtime confirmation the audit could not make:

- **S1** graph reconfiguration is safe only because everything happens to be on main,
  and nothing says so. One `DispatchQueue.global` in a UI handler makes it a data race.
- **S2** a feedback send from an *upstream* slot may not get its one-frame delay.
- **S3** `ObjectKey` hashes a captured `ObjectIdentifier` while holding the control
  weakly — a reused address can alias a dead control.
- **S4** `armedSweeps` holds faders STRONGLY; the tuple label reads like the weak
  pattern beside it and is not.
- **S5** `beatSubdivision` still only changes a label. `buildSchedule` hardcodes
  `.quarter` for all seven subscriptions, so the DIV field means nothing.

## Asked for, not built

- **WeatherStar 3000 / 4000** — see the backlog entry in `BUILD-PLAN.md`. Settle the
  three questions first: whether WS3000 is Amiga at all (WS4000 was), that SCRAPE is a
  runtime network call CLAUDE.md forbids, and that the disc images are copyrighted.
  Manual entry and RANDOM have neither problem and should ship first — they also prove
  the data path into the machine before a scraper is stacked on top.
- **A/B/BOTH on every effect — asked three times.** Not landed because it is
  architectural: one instance per channel, 20 full-frame passes instead of 10. Check
  the budget first — the per-channel benchmark already reads 21.08 ms plus 10.54 ms of
  bus chains against 33.4 ms, which is far tighter than the 11.4 ms in CLAUDE.md.
- ~~**Per-app audio beat detection**~~ — built 2026-09-23: CLOCK ▸ System Audio /
  Audio Input / one app, on Core Audio process taps.
- **Now-playing / Engine DJ** — blocked on an Automation permission granted at the
  keyboard, and on hardware.

## Half-built — present, inert, honest about it

`scripts/selfqa.sh audit` is the authority: **0 enabled-but-unwired**, which is the
dangerous state. These are disabled and labelled, waiting on their feature:

- Record / stream **encoders** — arming and indicators are real, no `AVAssetWriter`
- Asset browser **import, tagging, drag-to-channel**
- **⇧ Learn** button and the hold-Shift highlight (learn works from the M badges)
- Fader **Fade / Auto / Beat** — the scheduler exists, the mixer is not subscribed
- **Capture as a live source** — node built, never routed into a channel
- **Physical feedback loop** — round trip measured, capture not routed to the node
- **Templates** — round-trip tested, not wired to the File menu
- **Character generator** — Core node done and pixel-tested, no way to reach it

## Not started — later phases

ISF host + FFGL · SVG/PS1 source · IP in/out · libretro out-of-process host · Core
Image / AU passthrough · NTSC scopes · discrete A/B/C/D recording · optional Syphon.

## Keeping this file honest

This document claimed "only `.dv` plays — the biggest single gap" and "photo folder:
what is missing is folder import" for a long time after both were built. Anyone
reading it to choose work was sent at solved problems. CLAUDE.md rule 6 makes updating
the touched docs part of done; that rule is the only thing preventing a recurrence.
