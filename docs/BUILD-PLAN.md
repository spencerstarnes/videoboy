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
- [ ] Optional: expose PRIMARY (and the wedge sources) over Syphon so the app can also feed VDMX/TouchDesigner rigs.

## Backlog notes / deferred ideas
(Claude Code: append out-of-scope ideas here instead of building them mid-phase.)

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
- **Macroblock-level MPEG editing.** The MPEG corruptor (frame-drop, motion-vector,
  reference-hold) is built and tested, but it edits BYTES. libavcodec conceals errors
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
- **Audio does not drive transport phase, only tempo.** SPEC 4c mentions phase; the
  estimator deliberately does not guess where the downbeat is, because guessing it
  badly is worse than leaving it to tap tempo.
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
