# Feature ledger — everything proposed that hasn't fully landed (2026-09-27)

Sources: every message the owner typed in all 34 Claude sessions (304 direct and 217
sent while a task was running), every `.md` in `~/dev/videoboy-perf` and
`~/dev/videoboy`, and git. Statuses were checked against the code, not taken from docs,
because `docs/TODO.md` is badly out of date (audit L8). Where an item could not be
checked it says **unverified**.

State of perf/audit at the time of writing: **20b38b1, version 0.4.10**.

---

## 1. Built but never committed

**None.** Every worktree is clean. The one untracked path is `~/dev/videoboy/.claude/worktrees`,
which is an agent's scratch worktree, not work.

Two branches each hold a commit that git reports as unmerged: `feature/transitions`
(2275821) and `feature/bus-key-detect` (c8bd3bf). Both were merged by hand on 2026-09-23,
which changes a commit's identity. Their content is in perf/audit: the transition key,
the AVE-5 wipe, codes 6AA/6BA and bus-key learn. Nothing is lost.

## 2. Built, but switched off or not reachable in the app

| Feature | Where it stands |
|---|---|
| **Mode bar, Settings mode, setup assistant, Import mode, Copy + Optimize** (0.4.8–0.4.10) | Built and tested; behind `VIDEOBOY_FLAGS=modeBar`, off by default. Needs a person to click through it before it's switched on. |
| **DV bitstream corruptor, bus data stage, NTSC/DV output emulation** | Built; switched OFF by your decision (2026-09-17: "remove until we can reconceptualise… no DV hardware to test"). `VIDEOBOY_FLAGS=bitstreamCorruptor,busDataStage,outputSignalEmulation` brings them back. |
| ~~**Now Playing overlay**~~ — **built later on 2026-09-27 as a generator** (Music + Spotify, three looks, fade on change, `selfqa now-playing`). Was: | The model and templates are in Core (`NowPlaying.swift`); no live adapter. It needs the macOS Automation permission granted at the keyboard. Engine DJ: researched only (`docs/NOW-PLAYING-SOURCES.md`), not built. |
| **Native Core Text titler** (character generator) | Core node built and pixel-tested; nothing in the app reaches it (audit L4: wire it or delete it). |
| ~~**Patch save/load**~~ | **Done later on 2026-09-27:** File ▸ New / Open / Open Recent / Save / Save As, a real Save in the quit prompt, auto-save, `selfqa template`. Still open: the FX panels' single-chain preset keys. |
| **Calibrated feedback latency** | `selfqa calibrate` measures it; nothing applies it (audit L2). |

## 3. Planned in the docs, not built

### Approved phases
- **0.4.11 — any resolution and frame rate:** `ProjectFormat`, SD PAL / HD / square /
  vertical canvases, 23.976–30 fps, a ½-resolution fallback, output framing, and
  stress/soak per canvas (PROPOSAL §6). This is the largest item left.
- **0.5.0 — tags:** tag pools that feed each channel's Up Next, tag pads on MIDI, beat
  shuffle, an energy fader, smart bins, optional Finder tags (PROPOSAL appendix A).

### Left over from what was just built
- Copy + Optimize: the **Custom** preset (codec, GOP, bitrate, keep audio);
  **Re-optimize** stale files after a canvas change; a per-hour disk estimate; pausing
  conversions while output is live.
- A/B ROLL + ADV: on the **Program fader** (the design left this open); a "Then from"
  key on the library row (it lives in Settings for now); making the play key blink
  when ROLL starts a source.
- Import mode: a loop toggle in the viewer.
- Person-in-the-loop: nobody has clicked through the mode bar and Import mode by hand
  yet (docs/BLOCKED.md).

### Audit items still open (AUDIT-2026-09-26)
- **L3** — six emulated-titler faders bypass the registry (the audit check fails on
  purpose).
- **L5** — `ISF/Vidvox/Bloom.fs` is hidden by `Ethereios/bloom.fs`, because their names
  collide when case is ignored.
- **L8** — TODO.md / CLAUDE.md are out of date. **L9** — about a dozen header buttons
  have no title or accessibility label.
- **F7 / F8** — streaming and recording still read back and encode on the main thread;
  listed open, not re-verified.
- **H2** — a routine 3-min HD soak as the pre-show check. **H3** — the audit doesn't yet
  actuate pop-ups and segmented controls. **H4** — a stress run with recording and
  streaming on.
- GPU fence stalls: about 8 per 5 minutes, 14–19 ms; cause unknown.

### BUILD-PLAN backlog
- **WeatherStar 3000 / 4000** under EMU (ZIP + SCRAPE, per-field entry, RANDOM). Three
  questions are open: which hardware, the runtime network rule, and the disc images.
- Emulated titler: faders for the genlock key colour/threshold/edge; SPEC's per-entry
  help file and hotkey table; the platform → software → entry browser for other
  emulators; using Amiberry's IPC socket (SEND_KEY, SAVESTATE) in place of the
  guest-side ARexx bridge.
- **Layer Mask** effect card (a mask on the layer composite). *Colour Ctrl* is covered
  by the ISF Colour card.
- **Generator colours** can't be edited (no colour well); Source Controls shows
  sliders only.
- **Physical feedback loop:** the capture isn't routed into `FeedbackNode`.
- **libdvc100 as a capture source,** not just the self-QA loopback.
- Audio-tap / LFO modulation menus beyond the FX parameters (faders and shuttles have
  MIDI learn only).
- Beat detection: a **×2 / ÷2** tempo-level key; finding "one" of the bar and a
  per-rig offset/nudge; MIDI clock and Ableton Link as clock sources (they were
  removed from CLOCK as unbuilt).
- Overscan as a continuous control (it's on/off today).
- Macroblock-level MPEG editing (true motion-vector datamosh on MPEG-2).
- Core Image / AU passthrough; **Syphon** output; SVG/PS1 source; **IP video in/out**
  (IP Camera and DV Deck can be added in Settings ▸ Sources but show greyed; no live
  capture).
- **Macros & AI control** (Settings pane reads "Not built yet").
- A density pass on the FX panels (names truncate at narrow widths).
- Zero-copy AVFoundation frames (`CVMetalTextureCache`).
- Found this session: an under-constrained grid layout (a fader can be 0 pt wide); the
  soak's memory check misreads a sawtooth; the weekly catalog backup runs at launch.
- Render-path items still listed open in TODO.md (C8/C9 audio-thread allocations,
  C15 drawables, C17, C18 `Engine.stop` never called) — **unverified**, because TODO.md
  is stale.

## 4. Mentioned in conversation, never planned or built

| Idea | When | Notes |
|---|---|---|
| **Retro emulation library:** NES, SNES, N64, PSX (MIT/BSD cores) with ROM upload, a TAS-file pane, save states, and code injection / texture glitching | 2026-09-24 | Written down only as a line in `docs/IDEAS-AND-FEATURES.md`. Licensing check needed per core; out-of-process like Amiga. |
| **Custom shader / glitch injection on any source** (CRT, texture manipulation) | 2026-09-24 | Idea only; ISF import covers much of it for effects, not for emulator internals. |
| **Vision model watching the S-Video output** (DVC100) | 2026-09-18 | Asked during the local-model setup; never planned. |
| **iOS / mobile version** | 2026-09-25 | Answered in chat only. |
| **1.0.0 "shippable" plan, public beta, minimum system requirements** | 2026-09-25/26 | Answered in chat only; there is no doc. |

## 5. Asked for, then dropped by you (for the record)

The ISF "app store" / BlenderKit-style browser ("forget that", replaced by the import
pane) · the MX-1 effect set (removed) · the zebra overlay (removed) · the DATA button
in the output bar (removed) · the MIDI BPM clock option (removed, "stuck in AUDIO
mode") · "CUT to ONE" labels (became plain CUT).

## 6. Recently built, from earlier asks (so they aren't re-asked)

A/B ROLL + ADV · Copy + Optimize · Import mode · mode bar and setup assistant · clips
open off the main thread (F9) · the import dropped frame · `hev1` HEVC · no modal on a
failed load · Blender-style drag-across switches (`VBSwitch`) · Source Controls on each
FX panel (the 2026-09-24 generator-parameters plan) · per-app beat detection · DATA
BURN · AVE-5 wipe · transitions · datamosh with MOSH/HEAL · ISF import and generators
· photo folders · library bins and views · recording and streaming · scopes with
OVER/L3 · configured sources.
