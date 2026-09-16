# BUILD-PLAN.md

Operational plan for Claude Code. Execute phases in order. One phase per work session. Do not skip ahead. Full feature detail is in `docs/SPEC.md` — read the referenced section when you start a phase; don't load the whole file.

**Legend:** `[HEADLESS]` = verify via build/test. `[SELF-VISUAL]` = verify yourself via the self-QA harness (offscreen PNG, DVC100 loopback metrics, or virtual MIDI) — see `docs/SELF-QA-HARNESS.md`. `[HUMAN]` = genuinely needs the person (there are almost none until the clickable-app milestone). `[FLAG]` = ship behind a feature flag.

**Definition of done (every phase):** `scripts/verify.sh` exits 0, `[HEADLESS]` + `[SELF-VISUAL]` acceptance met with saved evidence in `selfqa/out/<phase>/`, docs/checkboxes updated, one commit. Run across phases without pausing for permission; only stop at the clickable-app milestone or a true blocker (`docs/BLOCKED.md`).

**Clickable-app milestone = end of Phase 2.** This is the human's first touch: a launchable `.app` they can open, click, and play a sample through. Everything up to here is autonomous and self-verified.

---

## Phase 0 — Repo, toolchain, headless skeleton
Goal: a project that builds and tests from terminal on the Mac Studio with nothing real in it yet.

- [x] Detect toolchain (`sw_vers`, `xcodebuild -version`, `swift --version`); record versions in `docs/ENVIRONMENT.md`.
- [x] Create the split: `Core/` SwiftPM package + `App/` Xcode target linking it (see SPEC §1.5 folder layout).
- [x] Write `scripts/bootstrap.sh`, `build.sh`, `test.sh`, `run.sh`, `verify.sh`. Idempotent, arm64.
- [x] Add `.claudeignore`, `.claude/settings.json` (deny destructive shell + non-registry network), `.gitignore` (`build/`, vendored binaries, media).
- [x] `Core` exposes a trivial version function with a passing unit test. `App` launches to an empty window.
- [x] Seed `/Docs`: `ARCHITECTURE.md` (graph + two clocks, one diagram), `ADD-A-MODULE.md` (stub), per-folder READMEs.
- [x] **Build the self-QA harness first (your eyes — see `docs/SELF-QA-HARNESS.md`):**
  - Offscreen render: any texture → PNG in `selfqa/out/`.
  - Capture tool: read a UVC/AVCapture device (the DVC100) → PNG frames + `metrics.json` (effective fps, dropped/dup, combing score, signal-present). Behind a protocol with a mock so it builds without hardware.
  - Frame assertions: dimensions, dominant color, signal-present, byte-diff vs a fixture, fps-within-tolerance.
  - Virtual CoreMIDI source helper for detect self-tests.
  - `scripts/selfqa.sh` runs a named check and writes artifacts under `selfqa/out/<name>/`.
  - Prove it: render a known test pattern offscreen, dump PNG, assert its dimensions/colors in a test.

**Acceptance:** `[HEADLESS]` `scripts/verify.sh` exits 0; `scripts/run.sh` opens an empty window; `[SELF-VISUAL]` offscreen PNG of a test pattern is produced and its assertions pass. Commit `phase-0: skeleton + self-qa`.

---

## Phase 1 — The wedge core (headless, no UI)
Goal: the competitive heart, fully unit-tested without hardware. This is the most important phase; spend the most care here. Detail: SPEC §5 (DV/MPEG), §4 (clocks), §13 (param codes), §16 (templates), §2 (graph model).

- [x] Vendor FFmpeg as an **LGPL** arm64 xcframework (`scripts/bootstrap.sh` fetches/builds it). Record version + license in `docs/THIRD-PARTY.md`. If only GPL is achievable, STOP and report.
- [x] DV path: demux + decode DV via libav → raw frames in memory (no display yet). Test against a sample `.dv` fixture.
- [x] **Bitstream corruptor (the wedge):** operate on compressed packets *before* decode — DIF block drop/dup/shuffle, DCT-coefficient zero/flip, sequence hold/reseed for DV; frame-drop / motion-vector / reference-hold for MPEG. Pure functions over byte buffers. Unit-test each transform on fixtures (deterministic given a seed).
- [x] Musical clock: transport (BPM, phase, PPQN), subdivision scheduler with **lookahead + latency compensation** (schedule at `T − latency`). Unit-test that scheduled events land on target ticks given fake module latencies.
- [x] Param-code registry (§13): stable codes (`11A` etc.), mapping resolves to codes not instances. Unit-test that swapping a module preserves mappings whose codes persist.
- [x] Template read/write (§16): serialize the graph model + mappings to plain-text TOML/JSON and back. Unit-test round-trip equality; unknown keys are non-fatal.
- [x] Render-graph model (nodes + typed edges) as data — no rendering yet.

**Acceptance:** `[HEADLESS]` all of the above green under `swift test`; a fixture DV file can be loaded, corrupted deterministically, and the corrupted bytes still decode. Commit `phase-1: bitstream core`.

---

## Phase 2 — Minimal playable app = CLICKABLE-APP MILESTONE `[FLAG]` per unfinished bit
Goal: the smallest thing that plays, is clickable, and outputs a real SD signal — self-verified end to end. Detail: SPEC §3 (output), §6 (sources), §7 (MIDI detect), §12 (mix), §9 (composite — minimal).

- [x] Metal render loop: decoded/corrupted frames → `MTLTexture` → composite → present.
- [x] Two players (A, B) → one bus → PRIMARY. Crossfade + hard cut. Real clickable UI controls (buttons, a fader) — the human must have something to click.
- [x] **Build the canonical UI shell from the start (SPEC §14 — normative; open `docs/mockups/layout-v6.html` first).** The full 5×5 grid with every panel present, real AppKit controls (§14.3), docked/collapsible/never-movable, width-reactive. Panels whose features aren't built yet render with their controls disabled and a "not yet implemented" state — do NOT omit them, and do NOT build a throwaway simpler shell. Put all radii/padding/gutter values in one `Theme` token file (§14.4). Verify reflow at wide/compact/narrow via offscreen PNGs at three window sizes.
- [x] DV-stream source with the Phase-1 corruptor inline, clock-schedulable, mappable, with on-screen controls.
- [x] Output stage: borderless window on the chosen external display (the HDMI card); enumerate displays; **negotiate and log** the mode (SPEC §3). Default SD 480i/480p; expose the interlace/pulldown choice — never guess silently.
- [x] Core MIDI in + shift-to-detect learn for the mixer + corruptor params.
- [x] App is a proper `.app` bundle, `NSCameraUsageDescription` set, runs unsigned (ad-hoc). No ADP/notarization.

**Acceptance (all self-verified — do NOT wait for the human):**
- `[HEADLESS]` app builds, launches, plays a `samples/` file to an on-screen preview; MIDI-learn maps a virtual-MIDI control in a test.
- `[SELF-VISUAL]` offscreen PNGs confirm playback + beat-synced corruption changing frames on the beat.
- `[SELF-VISUAL]` **DVC100 loopback:** send PRIMARY to the HDMI card, capture via the DVC100, and from `metrics.json` assert (a) a stable SD frame rate within tolerance, no runaway drops, (b) the negotiated/logged output mode matches the captured signal, (c) captured PNG frames show the expected content. Save evidence to `selfqa/out/phase-2/`.

Commit `phase-2: clickable mvp`. **This is where you stop and present to the human** — a launchable app plus the `selfqa/out/phase-2/` evidence of what works. Write a short `docs/FIRST-RUN.md`: how to launch it, what's clickable, what's stubbed, known bugs.

If the DVC100 loopback can't run (no hardware attached / permission not granted), still deliver the clickable app, mark the loopback checks `blocked` in `docs/BLOCKED.md`, and rely on offscreen-PNG evidence — do not block the whole milestone on it.

---

## Phase 3 — Analog character + feedback
Detail: SPEC §9 (composite/NTSC), §10 (capture + feedback), §11 (CRT features).
- [x] CompositeCodec (NTSC encode/decode, dot crawl, chroma bleed, TBC wobble) as Metal/ISF passes.
- [x] Echo/trails; capture-in (DVC100/UVC); internal + external feedback with frame-delay and **measured round-trip latency calibration** (§10).
- [x] Safe zones, overscan, test-pattern source/output, BFI/grid seeding.

**Acceptance:** `[HEADLESS]` codec + feedback math unit-tested on fixtures. `[SELF-VISUAL]` DVC100 loopback confirms the composite look and measures the feedback round-trip for calibration; save evidence.

---

## Phase 4+ — Backlog (post-MVP; do not start without explicit go-ahead)
Each is independent and `[FLAG]`-gated. Pull one only when prioritized.
- [x] Generators + transport LFO (SPEC §6A) and audio-reactivity bus (§4c, §13).
- [ ] ISF host (parser → Metal) + FFGL (SPEC §8); CI/AU passthrough. **MX-1 effect set is done.**
- [ ] Clean Core Text character generator + period preset (SPEC §18.1).
- [ ] Emulated titler library — out-of-process GPL libretro host, save-state landing, genlock key (SPEC §18.2).
- [ ] NTSC scopes (§19); SVG/PS1 source (§17); IP in/out (§6, §15); discrete A/B/C/D recording (§15); routing/send panel. **Full four-channel mix (C/D→TWO, layer compositing) is done.**
- [ ] Optional: expose PRIMARY (and the wedge sources) over Syphon so the app can also feed VDMX/TouchDesigner rigs.

## Backlog notes / deferred ideas
(Claude Code: append out-of-scope ideas here instead of building them mid-phase.)

- **Per-channel FX chains.** Sub Mix 1 FX currently drives Source A's corruptor only.
  SPEC 14.2 describes one chain per sub-mix; per-channel chains (SPEC 2's `chFX`) are
  a separate piece of work.
- **AVFoundation source for non-DV formats.** Only `.dv` plays today. Ordinary
  `.mov`/`.mp4` need the AVPlayerItemVideoOutput path from SPEC 1.
- **Integrate libdvc100 as a capture *source*** (SPEC 10, Phase 3), not just as the
  self-QA loopback. It is GPL v2, so it must stay out-of-process — the same rule as
  the libretro cores. The out-of-process shell-out in `DVC100CaptureSource` is the
  pattern to extend.
- **Sources C and D reach PROGRAM.** They load and play into TWO, but the ONE/TWO
  composite path has only been exercised from ONE.
- **Density pass on the FX panels.** Effect names truncate in the outer columns at
  narrow widths (SPEC 14.4 defers density tuning, so this is expected, not a defect).
- **MPEG bitstream corruptor.** SPEC 5 wants frame-drop / motion-vector / reference-hold
  alongside the DV DIF corruptor, sharing infrastructure but a separate module.
- **External feedback through the physical loop.** `FeedbackNode` accepts a captured
  frame as its history (input slot 1) and the round trip is measured, but the capture
  is not yet routed into that slot live. Internal feedback works.
- **Modulation assignment beyond MIDI covers the FX chains only.** Shift-to-detect
  now reaches every enabled fader, including the crossfaders and shuttles, but the
  audio-tap and LFO menus are still only on the effect parameters' S and C badges.
- **Core Image / AU passthrough** from SPEC 9 — enumerate the useful CI filters and
  expose the video-rate ones as mappable modules. Not started.
- **MX-1 effects are not in a chain yet.** `MX1EffectNode` exists and is tested, but
  it is not instantiated in the engine's graph, so there is no UI for it.
- **Generator colours are not editable.** Each generator has two colours with an
  out-of-gamut check, but no colour well in the UI.
- **Audio does not drive transport phase, only tempo.** SPEC 4c mentions phase; the
  estimator deliberately does not guess where the downbeat is, because guessing it
  badly is worse than leaving it to tap tempo.
- **Overscan is a toggle, not a continuous control.** The 82A parameter exists and the
  preview overlay reads it; the settings bar only offers on/off.
