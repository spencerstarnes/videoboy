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
- [x] **Live H.264 datamosh** (owner request, 2026-09-23; `docs/DATAMOSH.md`). Real
      I-frame removal and P-frame bloom on a live VideoToolbox H.264 stream, decoded by
      libavcodec: the "Datamosh · H.264" card on both FX panels (A / B / BOTH), codes
      35B–38B. Runs on every channel and both buses inside the stress budget.
- [x] **Datamosh: graceful exit, more control** (owner request, 2026-09-23). Bloom is
      an amount (share of frames replayed) with its own loop length, so pulling it
      down slows the stream; melt split out of mosh; HEAL is a momentary key (MIDI
      learnable, presses latched so a tap between frames counts) that eases back to
      clean over a heal time in a shape (fade / blocks / wipe / luma) before the
      keyframe; heal on the beat (1/16 … 4 bars); letting go eases out; opacity and
      blend mode over the clean input. Codes 39B–3EB + 01A. `selfqa mosh` 14/14,
      stress holds 29.97 with all six nodes healing on the beat.
- [x] **Datamosh: MOSH key, HEAL on the beat by ⌥⌘** (owner request, 2026-09-24).
      MOSH (3FB) is a hold: full mosh while held whatever the faders say (every frame
      a bloom replay, keyframes and cuts dropped), so it moshes moving footage with
      no cut; let go, back to the faders, easing to clean if they are at zero. It
      shares HEAL's row, so nothing on the card moved. Option-Command-click HEAL arms
      "heal every" (1 beat, or the rate last chosen) and again turns it off; the key
      wears the automated outline while it is on. `selfqa mosh` 23/23.
- [~] Clean Core Text character generator + period preset (SPEC §18.1). Core node done
      and pixel-tested (fill, outline, shadow, kerning/tracking/leading, alignment,
      position/anchor, scale, title-safe clamp, roll/crawl clock-synced, period
      preset via CompositeCodec, NTSC-legal fill warning). NOT YET wired into the
      graph or the UI — no way to reach it from the window, no text-entry surface,
      no font/colour pickers. That wiring is the remaining half.
- [~] Emulated titler library (SPEC §18.2). Running for real, not a stub: Amiberry
      drives Scala MM400 on real Kickstart 3.1 (`docs/BLOCKED.md` has the full story),
      all 19 titler controls are wired through the param-code registry and mappable,
      save-state landing is opt-in (fixed 2026-09-19 — it used to silently restore and
      pin whatever layout was captured), and a drag-to-place performance pad positions
      text by pointing rather than fighting two faders. `EmulatedTitlerNode` is a real
      graph source, drag-assignable to any channel exactly like a file or generator,
      and reaches PROGRAM (`selfqa/out/phase-4/emu-capture`, 11/11 PASS). **Genlock key
      added 2026-09-22**: a new `BlendMode.key` case (6xE param family — key colour/
      threshold/edge) keys the emulator's background out per-pixel so live video shows
      through and only the title sits on top, per SPEC's "colour 0 = transparent"
      requirement — previously the only path was manually picking Screen/Add blend
      mode, which had no threshold and only degraded gracefully on pure black.
      Architecture note: this runs Amiberry as its own separate process talking over
      an IPC control socket + captured framebuffer, not the SPEC's literal
      "libretro host + shared memory" — same GPL-isolation outcome (the GPL binary is
      never linked into Videoboy), different mechanism; worth reconciling the SPEC
      text with what was actually built rather than reading this as a deviation.
      Remaining before this is fully `[x]`: the key colour/threshold/edge params have
      no visible fader yet (same status as `.layerOpacity` on the same node — registry/
      MIDI/template-mappable, reachable by shift-to-detect once a fader exists, not
      by one yet) — SPEC's "smack dab on the right screen" per-entry help file and
      hotkey table are not surfaced in the UI; and the library is Scala MM400/MM300
      only, not the platform→software→entry browsable menu SPEC describes (VICE/
      hatariB/other platforms untouched, deliberately — see CLAUDE.md's MVP scope).
- [ ] SVG/PS1 source (§17); IP in/out (§6, §15). **NTSC scopes (§19), discrete A/B/C/D
      recording (§15), the routing/send panel (§6) and the full four-channel mix
      (C/D→TWO, layer compositing) are done.**
- [x] Configured sources (§6, §10) — added 2026-09-22. Settings > Sources is a real
      +/− list (`ConfiguredSource`, `SourceListView`), not the single
      `captureDeviceName` string it replaced. **Camera** (AVFoundation — webcams,
      Continuity Camera, a UVC grabber like the DVC100) and **Window Capture**
      (ScreenCaptureKit, picked from what is actually on screen — same picker macOS
      itself uses) are both real and continuous: `LiveAVFoundationCapture` /
      `WindowCaptureSession` feed a `CaptureSourceNode` per configured source, and
      `ChannelSourceKind.capture(id)` (opened up from a single fixed `.capture` case
      that could not even be routed to a channel — see `Engine.setChannelSource`'s
      prior history) makes any of them assignable to A/B/C/D the same way a clip is:
      double-click the tile in the Asset Browser's **Sources** tab. Sources and Clips
      were one undifferentiated tab before this — clips showed up mixed in with
      hardware placeholders, which is the bug this was written to fix.

      **IP Camera** and **DV Deck** can be added and named (saved, shown greyed in
      Sources with why) but are deliberately NOT live:
      - IP camera decode is real protocol work (RTSP/ONVIF/etc.) and a runtime-network
        decision CLAUDE.md scopes as its own explicit phase — out of scope here.
      - DV deck is a genuinely open hardware question, written down rather than
        guessed at: this is the literal FireWire/IIDC path, NOT the DVC100 (which is
        UVC and goes through Camera above). Whether modern Apple Silicon + current
        macOS has any native FireWire DV capture route at all, without extra
        hardware, is unconfirmed. Settle that before building against it.

      607 tests (597 + 10 new — `ConfiguredSource` round-trip/lenient-decode,
      `CaptureSourceNode.isLive`). `scripts/verify.sh` exits 0, including the full
      self-QA suite with a live app launch.
- [x] Crossfader transitions (MX-1 style) — added 2026-09-23. A pattern key on the
      LEFT of each fader's transport cluster (`VBTransitionButton`, the partner of the
      blend key on the right) picks what shape the move takes: Dissolve (default,
      unchanged), Wipe, Slide, Push, Split (barn door), Interlace (horizontal and
      vertical of each), and Iris. 12 patterns, `Transition` enum, param `61F` (new
      6xF family), one branch in the existing blend shader — still ONE draw per bus,
      no new pass and no new `waitUntilCompleted`. The fader position is the
      transition's progress, so FADE/CUT/bus keys/sweeps/MIDI all drive a wipe
      unchanged; both fader ends stay the pure sources for every pattern, and the
      blend mode colours the arrived area by the same mid-travel triangle as the
      dissolve. Evidence: `TransitionTests` (11) and `scripts/selfqa.sh transitions`
      (`selfqa/out/phase-4/transitions/`: contact sheet at 25/50/75%, UI key driven
      through its own menu item and the picture read back, key fits at all three
      breakpoints). Not yet: soft-edge/border width on wipes, and no registry→key sync
      when `61F` is moved by MIDI (the blend key has the same gap).
- [x] AVE-5 wipe transition — added 2026-09-23. A 13th transition, `Transition.ave5`,
      emulating the Panasonic WJ-AVE5's WIPE MODE block from its operating manual
      (WIPE PATTERNS table p.5; controls 5–10, 53, 54; procedure pp.12–13). Five
      pattern keys that COMBINE (A|B, B|A, A/B, B/A, circle → the table's 31 rows),
      MULTI (×4 → ×16 → off), WIPE edge (normal → border → soft), BACK COLOUR (8,
      stepped), ONE-WAY, REVERSE, CUT when no key is lit, and the joystick
      positioner on the three Ⓟ patterns. P-IN-P is drawn disabled (out of scope).
      Core: `AVE5Wipe` (state + press semantics + a CPU twin of the field), params
      `62F–69F` (state) and a new `6xG` family `61G–6AG` (momentary key presses, like
      68A–6BA), and MIDI pitch bend as a control source (a keyboard joystick's X).
      Shader: one more branch in the existing blend draw — no new pass or wait.
      UI: with AVE-5 armed, the fader's transition key draws the lit pattern and
      opens a popover laid out like the hardware block, plus an XY positioner with
      X/Y faders; every key and both faders are Shift-learnable (the popover is
      added to `DetectSession` as an extra root). Evidence: `AVE5WipeTests` (25:
      every key combination × MULTI × edge × REVERSE pure at both ends; shader vs
      CPU twin 0 disagreeing pixels over 192 combinations); `scripts/selfqa.sh
      ave5` (`selfqa/out/phase-4/ave5/`: the manual's table rendered row for row,
      live DV, the popover in a real window driven by hit-test, Shift-learn, a
      learned MIDI key, pitch bend); `selfqa stress` now arms AVE-5 on all three
      faders — worst tick 16.3–16.4 ms vs 16.2 ms baseline. Approximate: the two
      table rows the manual shows as textured photographs (A|B+B|A+circle,
      A/B+B/A+circle). Adding the 13th case shifts where an old `61F` value lands
      from Push Vertical up by one stop (transitions shipped the same day).
- [ ] Optional: expose PRIMARY (and the wedge sources) over Syphon so the app can also feed VDMX/TouchDesigner rigs.

## 0.4.6–0.4.11 — Import, modes, any canvas (owner-approved 2026-09-26)

Plan of record: `docs/PROPOSAL-2026-09-26.md` (decisions table at its top). Each phase is
feature-flagged, passes `verify.sh` + its own self-QA, and must not regress `stress`/`soak`.

- [x] **0.4.6 Phase 0 — decode fixes** (done 2026-09-26; results in `docs/AUDIT-2026-09-26.md`) (audit 09-26 F1–F5, F6, R1–R2): DV memory-mapped;
      AVF decoded at canvas size without the per-pixel loop; reused CPU buffers; per-source
      background prefetch ring (loop wraps and loads off the tick); staggered scopes;
      off-main thumbnails with an LRU cap. Gate: HD soak (`VIDEOBOY_SOAK_CLIPS`) with no tick
      over one frame.
- [x] **0.4.7 Phase 1** — SQLite catalog, background import job, contextual status bar (done 2026-09-26; `selfqa import`, results in `docs/AUDIT-2026-09-26.md`).
- [x] **0.4.8 Phase 2** — mode bar (⌘1 Import · ⌘2 VJ · ⌘3 Settings), Settings mode, setup assistant (2026-09-27, behind `VIDEOBOY_FLAGS=modeBar`; `selfqa modes`; a person's click-through is still wanted — docs/BLOCKED.md).
- [x] **0.4.9 Phase 3** — Import mode (Lightroom model; Add/Move/Copy) (2026-09-27, same flag; `selfqa import-mode`; marks to catalog, J/K/L viewer).
- [x] **0.4.10 Phase 4** — Copy + Optimize, linked optimized media (2026-09-27; `docs/specs/0.4.10-copy-optimize.md`).
      The helper is Videoboy itself (`--optimize`, a child process) using macOS decoders
      and the bundled LGPL DV/MPEG-2 encoders, so no ffmpeg CLI build was needed.
      `selfqa optimize`.
- [ ] **0.4.11 Phase 5** — any resolution and frame rate (`ProjectFormat`).
- [ ] **0.5.0** — tags (proposal appendix A).
- [x] **A/B ROLL + ADV** (designed with the owner 2026-09-24, built 2026-09-27;
      `docs/specs/ab-roll-adv.md`): ROLL rolls the source you take and re-cues the one
      leaving; ADV loads the leaving source's next clip (Up Next, then the library
      fallback in Settings ▸ Defaults). A/B and C/D faders; MIDI-learnable (6CA/6DA).
      `selfqa ab-roll`. Still to do: ROLL/ADV on the program fader; a "Then from" key
      on the library row; blink the linked play key when ROLL starts a source.

## Backlog notes / deferred ideas
(Claude Code: append out-of-scope ideas here instead of building them mid-phase.)

- **Under-constrained grid layout (found 2026-09-27, `selfqa modes`).** About 10–20
  controls (some bus pop-ups, step buttons and crossfader-row faders) land differently in
  identical `ShellView`s built back to back, for example a fader 0 pt vs 216 pt wide.
  A performer could get a zero-width fader. Needs its own look at the priorities and
  hugging of those rows.
- ~~**F9: open clips off the main thread.**~~ Done 2026-09-27: `Engine.loadAsync`;
  eject + reload now takes 6.7 ms worst (was 50 ms). See BUGHUNT.
- **Catalog backup off the launch path** (BUGHUNT S1 follow-up).
- **Soak memory check reads a sawtooth.** Its least-squares slope swung from −2 to
  +6 MB/min between two identical 12-min runs, although the troughs stayed flat. Judge
  leaks by the floor (the lowest sample each 2 min) instead.
- **Import mode viewer:** add a loop toggle (J/K/L, step and I/O are done).
- **Copy + Optimize, still to do:** the Custom preset (codec, GOP, bitrate, keep audio);
  Re-optimize for stale files after a canvas change (0.4.11 makes that possible); a
  per-hour disk estimate in setup; pausing conversions while output is live.
- **`selfqa import-mode` main-thread limit** read 36.7 ms twice, both times on the first
  run after a fresh build. The next 6 runs read 14.0–14.6 ms, including 3 under the
  sampler, which could not catch it again. Probably one-time code loading; not on the
  show path.
- 0.4.8 and 0.4.9 need a person's click-through with `VIDEOBOY_FLAGS=modeBar` before
  their boxes are ticked (see docs/BLOCKED.md).

- **The genlock key's colour/threshold/edge (6xE) have no visible fader.** Added
  2026-09-22 alongside `BlendMode.key` — see the Phase 4+ emulated-titler entry
  above. They are real, registry-backed, mappable params (same shape as every other
  parameter here), but the fixed crossfader-row layout (SPEC §14, normative) has no
  free slot for three more sliders without a real layout change, which is out of
  scope for a single feature. Precedent: `.layerOpacity` (66A) on the same
  `CrossfadeNode` has been in exactly this state — real, mappable, no visible fader —
  since before this session, so this is not a regression, just an existing gap this
  widened by three params. Reachable today only via a saved template or by setting
  the registry value directly (e.g. from a script); not reachable via shift-to-detect
  MIDI-learn, which needs a fader to shift-click. Fixing this for real means either a
  small popover off `VBBlendButton` (shown only when the chosen mode is Key) or
  finding room in the FX panel for a bus-level "Key" card — a UI decision worth its
  own look rather than a rushed addition to a crossfader row that already reads as
  full.
- **Per-entry help file and hotkey table for the emulated titler (SPEC §18.2).** Not
  surfaced anywhere in the UI. The panel's own tooltips cover the app-side controls
  reasonably well; the software-side keys (Scala's own F-keys, RETURN to commit,
  etc.) are undocumented in-app.
- **Colour Ctrl and Layer Mask effect cards.** Both were placeholder cards rendering
  disabled in the FX chains, and were removed from the window so the chains show only
  effects that do something. Kept here because both are still wanted:
  - *Colour Ctrl* — contrast/saturation/brightness on a bus. The param codes already
    exist (`51A`, `52A`, `53A`) and `ColourControlNode` does not.
  - *Layer Mask* — a mask on the layer composite (SPEC 12), so a blend can be
    confined to part of the frame.
  Re-adding either is a node plus a card in `PanelSet`, exactly as the other effects
  do it. Nothing else was removed with them.

- **AVFoundation decode is CPU-side.** `AVFClipDecoder` copies each frame into an
  `ImageBuffer` and uploads it, where a `CVMetalTextureCache` would hand the GPU the
  pixel buffer directly. Correct but not free; worth doing if HD clips drop frames.

- **Integrate libdvc100 as a capture *source*** (SPEC 10, Phase 3), not just as the
  self-QA loopback. It is GPL v2, so it must stay out-of-process — the same rule as
  the libretro cores. The out-of-process shell-out in `DVC100CaptureSource` is the
  pattern to extend.
- **Sources C and D reach PROGRAM.** They load and play into TWO, but the ONE/TWO
  composite path has only been exercised from ONE.
- **Density pass on the FX panels.** Effect names truncate in the outer columns at
  narrow widths (SPEC 14.4 defers density tuning, so this is expected, not a defect).
- **Macroblock-level MPEG editing.** (The classic datamosh look now exists through
  the live H.264 route — frame-level, `docs/DATAMOSH.md`. This note is about editing
  vectors AS vectors, which that route does not do.) The MPEG corruptor (frame-drop,
  motion-vector, reference-hold) is built and tested, but it edits BYTES. libavcodec conceals errors
  well, so the result is a valid picture that is not the right one rather than the
  blocky sliding look of datamoshing. Producing that reliably means parsing
  macroblocks and editing motion vectors as vectors — variable-length codes, a layout
  per picture type, and re-encoding. A decoder's worth of work, deliberately deferred.
- **The PHYSICAL feedback loop.** `FeedbackNode` accepts a captured frame as its
  history (input slot 1) and the round trip is measured, but the live capture is not
  yet routed into that slot. Internal feedback and internal bus sends both work.
- **Modulation assignment beyond MIDI covers the FX chains only.** Shift-to-detect
  now reaches every enabled fader, including the crossfaders and shuttles, but the
  audio-tap and LFO menus are still only on the effect parameters' S and C badges.
- **Core Image / AU passthrough** from SPEC 9 — enumerate the useful CI filters and
  expose the video-rate ones as mappable modules. Not started.
- **Generator colours are not editable.** Each generator has two colours with an
  out-of-gamut check, but no colour well in the UI.
- **Audio aligns the beat, not the bar.** Since 2026-09-23 beat detection drives
  transport phase as well as tempo (`BeatTracker.phaseCorrection`, nudged four times
  a second while locked). Which beat is "one" of the bar is still not guessed, and
  output latency to the screen is not compensated — both would need a per-rig
  offset control (SPEC 4b's "offset/nudge") rather than an algorithm.
- [x] **Every beat-rate key follows one rule** (owner, 2026-09-28: "absolutely 100%
      universal across all uses… always editable… forward and backwards on right
      click"). All 93 VBStepButtons — source STEP keys, CUT/FADE/BEAT tap rates,
      crossfader and effect sweep rates: click faster, right-click/Control-click
      slower, past either end to home (STEP on source keys, 1/1 on rate keys). Rate
      keys never walk to off: that disarmed CUT/FADE and hid the key mid-gesture,
      and stalled sweeps. The CUT/FADE rate keys float outside their panel's bounds
      and NO click could reach them; PanelView now routes to them
      (`FloatingHitTargets`), layout unchanged. `selfqa ui` walks every key with
      real events and hit-tests each visible one.
- [x] **Nested bins; imports keep the folder tree** (owner, 2026-09-28: "importing
      folders of clips removes the folder hierarchy… there's a check box for this,
      it's not working"; owner chose real nested bins over path-named flat bins).
      A bin is its PATH ("2019/Shoot A", `BinPath`) — no schema change; old flat
      bins are top-level bins. Import mode's Copy/Move with "Include subfolders"
      rebuild the tree under the destination and file clips into the same bins
      inside the chosen bin; a dropped folder keeps its whole tree (same-named
      folders no longer merge). Icon/list/column views and the path bar go in and
      up one level; rename/delete carry the bins inside; New Bin is made inside the
      open bin. `selfqa bins` proves it end to end (8/8). Not built: dragging a
      bin INTO another bin (move bins by rename/drop only).
- **Beat detection now listens with BeatNet** (2026-09-27, owner request: "beat
  matching is probably the number one priority"). BeatNet's network (CC BY 4.0) is
  ported to Swift and checked to 2e-3 against PyTorch; its activations replace the
  hand-made onset envelope in the existing tempo/phase tracker. On six real tracks:
  locked as often as before (88%), beats on the right video frame 78% vs 69%.
  `VIDEOBOY_LEGACY_BEAT=1` restores the old tracker. Details, the scores and how to
  re-run them: `docs/BEATNET.md`. Still open: a wrong 3:2 lock in the first seconds
  of some tracks (undone in ~15 s), swung lo-fi (Cereal Killa) poor for both
  trackers, BeatNet's downbeat output not used yet, screen latency uncompensated.
- **Beat detection picks one metrical level and sticks to it.** On drum & bass it may
  lock at 92.8 rather than 185.6, or at a 4:5 relation (148); it then holds that
  level rather than wandering between them. A ×2 / ÷2 control beside the tempo would
  let a performer correct the level in one click. Not built.
- **Overscan is a toggle, not a continuous control.** The 82A parameter exists and the
  preview overlay reads it; the settings bar only offers on/off.
- **WeatherStar 3000 / 4000 under the EMU tab.** Requested 2026-09-18. Run the two
  Weather Channel graphics units as EMU programs beside Scala MM400, fed either by
  real forecast data or by hand.

  Interface as asked for, three stacked controls in the EMU panel:
  1. A **ZIP CODE** field and a **SCRAPE** button — pulls the current forecast from an
     official API and pushes it into the machine. The last successful pull is saved
     and reloaded on launch, so the unit comes up showing something.
  2. An expanding box **below** that, revealing a field per data point (temp, wind,
     conditions, pressure, the city banner, the forecast days) for typing values in
     directly when no network is wanted or when a specific screen is being set up.
  3. A **RANDOM** button that fills those fields with gibberish, for a look rather
     than a forecast.

  Three things to settle before any of it is built:
  - **Which target.** The WS4000 was Amiga-based, so it plausibly runs on the Amiberry
    host that already exists. The WS3000 is earlier and (unconfirmed) not Amiga — if
    so it needs a different core entirely and is a separate piece of work, not a
    second entry in the same menu. Confirm the hardware before estimating either.
  - **Runtime network access.** CLAUDE.md currently forbids network calls at runtime
    except a phase's explicit IP feed. SCRAPE is a runtime network call, so this needs
    that guardrail amended deliberately rather than quietly broken. The NWS/weather.gov
    API is the natural source: official, free, no key, though US-only and lat/lon based,
    so a ZIP-to-coordinate step is needed.
  - **The disc images are copyrighted.** Same rule as the Kickstart ROM and the Scala
    discs: referenced by a path the user supplies, never bundled and never downloaded.

  Manual entry and RANDOM have neither problem and could ship first — they make the
  unit useful with no network and no guardrail change, and they are also what proves
  the data path into the machine works before a scraper is added on top.
- **Amiberry 8 has an IPC control socket, and it changes what the EMU tab can be.**
  Found 2026-09-18 while looking for a way to save state without anyone touching the
  emulator. `/tmp/amiberry.sock`, plain text, tab-delimited, and it answers:

      $ printf 'PING\n' | nc -U /tmp/amiberry.sock
      OK	PONG
      $ printf 'GET_VERSION\n' | nc -U /tmp/amiberry.sock
      OK	version=Amiberry 8.3.0 (2026.08.05)	sdl=SDL 3.4.14

  About a hundred commands. The ones that matter here:

  - `SAVESTATE <statefile> <configfile>` / `LOADSTATE <state>` / `QUICKSAVE [slot]`.
    **Verified working**: writing to a path of our choosing returned `OK` and produced a
    540 KB `.uss` there. This is the whole of the requested save-state feature — the app
    asks, the emulator saves, nobody touches the emulator, and WE choose the filename and
    the directory, so states live in Videoboy's own app data and can be named after the
    program with an incrementing suffix.
  - `SEND_KEY <code> <state>`, `SEND_MOUSE`, `SEND_MOUSE_ABS`. Worth a serious look: the
    titler currently drives the Amiga through a shared drawer and an ARexx listener
    inside the machine, which is the most fragile part of this subsystem. This is a
    direct path that does not depend on anything running guest-side.
  - `TOGGLE_MOUSE_GRAB`, `RELEASE_MOUSE_BUTTONS` — direct control of the grab.
  - `SET_WINDOW_SIZE`, `TOGGLE_FULLSCREEN`, `SET_SCALING` — window control at runtime
    rather than only through the config file.
  - `QUIT` — a clean shutdown instead of SIGTERM.
  - `GET_STATUS`, `PING`, `GET_FPS` — a real health signal for the panel, replacing
    "is the process still running".

  Also `savestate_dir` exists as a config key, so the default location can be set at
  launch as well as per-call.

  Caveat worth checking before leaning on it: the socket path is fixed at
  `/tmp/amiberry.sock` and the binary carries "Default socket in use, using instance",
  so a second Amiberry takes a different path. Anything built on this has to discover
  which socket belongs to the instance we launched rather than assuming.

- **`scripts/selfqa.sh ui` can hang indefinitely on the library-drag check.** Found
  2026-09-23 while verifying an unrelated MIDI-mapping change. The check "a press
  then a drag on a thumbnail starts a drag" in `UISelfQA.swift` drives
  `HoverScrubView`'s real `NSView` drag session with a synthetic `NSEvent`, which
  goes through `NSCoreDragManager _dragUntilMouseUp:` — a blocking loop that waits
  for a genuine system-level mouse-up (`_BlockUntilNextEventMatchingListInModeWithFilter`),
  not an app-level synthetic one. It happened to complete once in an interactive
  foreground run and hung every other time (backgrounded, or after a prior run left
  stray mouse state), for 5+ minutes with 0% CPU, confirmed on unmodified `main` too
  — not a regression from any specific change. `scripts/verify.sh` calls
  `selfqa.sh ui` directly, so it inherits the same risk. Needs either a fake drag
  path that does not touch `NSCoreDragManager`, or dropping down to
  `draggingSession(with:event:source:)`'s testable seams instead of a synthetic
  `mouseDown`. Until fixed, re-run `scripts/selfqa.sh ui` in an interactive
  foreground terminal if it stalls, or `kill -9` the `Videoboy --selfqa` process and
  retry.

- **Library behaves like a Finder window (2026-09-24, perf/audit).** Icon view is an
  `NSCollectionView`, list an `NSOutlineView`, columns two `NSTableView`s, all reading
  one per-panel `LibraryBrowser`. Bins are folders in all three (open, drop onto,
  rename in place, delete → clips return to the top level). Click / ⇧-click / ⌘-click /
  ⌘A / rubber band select; a selection drags as a whole (to sources, bins, the queue,
  the Finder); right-click menus everywhere; ⌘C/⌘V/⌘⌫ through a real Edit menu; a
  generator or configured source drags onto a source panel. Evidence:
  `scripts/selfqa.sh library` (36 assertions + screenshots in `selfqa/out/library/`).
  Not done, deliberately: the library is still not saved between launches; clips added
  from folders show "—" for duration (nothing reads it off the file yet); Import… stays
  disabled; no reordering inside a bin or the up-next queue.

- **The scope row does not fit a sub-mix/PROGRAM panel at the narrow breakpoint.**
  Noted 2026-09-24 with DATA BURN / FILE / TC. At 760pt wide the panels are ~247pt and
  the row (send glyph, WFM RGB HIST VEC FILE TC, OVER L3, DATA BURN) needs ~300pt, so
  OVER and L3 are squeezed. Not a regression: the old seven-key row (with SEND)
  overflowed there too, and at 1000pt as well — it now fits at 1000pt and 1460pt, which
  `selfqa ui` asserts ("every key under … fits"); narrow is logged as a note. A real fix
  is a second row, or moving OVER/L3 behind a right-click, at narrow widths only.

- **Full-screen sweep, 2026-09-25** (`scripts/selfqa.sh fullscreen`: the real window at
  1920x1055, four channels playing, every scope key pressed and photographed, hovered
  sources, every browser tab; evidence in `selfqa/out/ui/fullscreen/`). Fixed that day:
  scopes and FILE/TC placed on the visible picture (they overflowed at Fill/Centre);
  FILE/TC never drew on the monitors (`updateMonitorData` was never called); OVER did
  nothing (opaque scope image) and a corner scope dimmed the whole picture; Centre no
  longer applies to the three composite monitors; the source FIT key moved to the
  panel's title bar; ISF locals with no initializer start at zero (Diagonal Blur drew
  noise); generator stills retry later moments when black. Followed up the same day:
  - Durations: every imported clip is measured in the background (`ClipDecoders`,
    the same decoder choice playback uses; DV from its size) and the column fills in.
  - Source Controls: each line is short enough for the column, the whole story in its
    tooltip; loading or ejecting a clip now refreshes it (it went on saying "empty").
  - Generator thumbnails: 11 of the 18 black ones now show a picture (half-SD render,
    build-up frames, later moments, a private test tone). The 7 that are genuinely
    black at their defaults — Solid Colour, Circle Trails (point starts at the
    corner), Color Organ (no notes on), Etch-a-Sketch, Histogram Viewer (needs a
    picture), Radial Spectrogram, Random Shape (the file divides by RENDERSIZE twice)
    — say "starts black" instead of looking broken. Rendered a sliver per 50 ms so
    launch and hot reload never cost a frame; the whole folder is ready in ~13 s.
  - Still open: at the 1460pt layout the longest Source Controls line ("D · clip —
    speed & scrub on D's panel", 181pt) may truncate; it fits at full screen (231pt).
