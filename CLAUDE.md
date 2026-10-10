# CLAUDE.md

Auto-loaded every session. Keep this short. Operational detail lives in `@docs/BUILD-PLAN.md`; full feature reference is `docs/SPEC.md` (read the relevant section when a phase needs it — do not load it wholesale).

## What this is
**Videoboy** — a native macOS app for live analog-style video mixing (product/bundle name: Videoboy). The competitive core ("the wedge") is **musical, playable manipulation of compressed video bitstreams** (MPEG-family; the DV path was removed 2026-09-28) output cleanly to SD (480i) for an analog chain. Everything else is supporting cast. This is NOT a general VJ tool and must not grow into one.

**Canvas (amended 2026-09-26, owner-approved — `docs/PROPOSAL-2026-09-26.md`):** the project canvas is selectable — SD NTSC 720×480, SD PAL 720×576, HD 1920×1080, square 1080×1080, vertical 1080×1920; 23.976–30 fps. **SD NTSC 29.97 is the default and the reference canvas.** The wedge and a clean SD analog output stay first-class and are never degraded to serve another canvas. The import/modes/optimize/catalog work in that proposal is in scope, in its phase order (Phase 0 = decode fixes, 0.4.6).

## Current focus
The clickable-app milestone is done and the human is actively performing with and testing the app. Work on what they ask, verify it yourself with the self-QA harness before reporting, and keep the scope guard: the bitstream wedge + clean SD output come first. When unsure whether something is in scope, it isn't. (Autonomous build-plan runs still follow the workflow rules below.)

Do **not** pursue Apple Developer Program, notarization, or distribution signing. Run the app **locally, unsigned** (ad-hoc `codesign --sign -` is fine). The app is a proper `.app` bundle with `NSCameraUsageDescription` set (required or camera access crashes).

## Environment (Mac Studio, Apple Silicon)
- Target arm64 only. Do not add x86 assumptions or Rosetta steps.
- Detect, don't hardcode: run `sw_vers`, `swift --version` and target what's installed. Metal is the render backend.
- `xcode-select` points at the Command Line Tools, which lack Metal and mismatch the SDK. The scripts set `DEVELOPER_DIR` to Xcode.app — **always build through them.** A bare `swift build`/`swift script.swift` fails; prefix `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Editor (SourceKit) errors like "SDK is not supported by the compiler" are this, not real.
- Third-party deps: SwiftPM only. Any vendored binary (FFmpeg xcframework, libretro cores) must contain an arm64 slice.

## Architecture (keep this shape)
- `Core/` — a SwiftPM package holding all non-UI logic: bitstream engine, clock/scheduler, param-code registry, template read/write, render-graph model. **Must build and pass `swift test` headlessly.** This is where the wedge lives and where most work happens.
- `App/` — a thin AppKit + Metal target that links `Core`, owns windows/output/UI. A SwiftPM package (not an .xcodeproj — see `docs/ENVIRONMENT.md`), built by `scripts/build.sh`.
- `UI/` — the canonical window shell from SPEC §14 (normative). Build the full 5×5 panel grid with real AppKit controls; unfinished features render disabled, never omitted. All radii/padding/gutters live in one `Theme` token file.
- One extension point only: the render-graph `Node` protocol (see `docs/SPEC.md` §2, §1.5). Adding a source/effect/output = implement it + drop a manifest. No parallel plugin systems.

## Commands (create these scripts in Phase 0, then always use them)
- `scripts/test.sh` → `swift test` on `Core` (fast loop; run after every change to Core).
- `scripts/build.sh [debug|release]` → build `Core`, then the app, arm64, into `build/`. Default **release**; a debug build is ~10× slower on the frame path and must never be left in `build/` for the human, nor used for any timing.
- `scripts/run.sh` → launch the built `.app` (logs to the terminal).
- `scripts/verify.sh` → build + test + lint; must exit 0 before any phase is "done."
- `scripts/selfqa.sh ui` → window shell + interaction checks. `scripts/selfqa.sh stress` → **the load test of record**: real window, live display link, all four channels, every effect on (release build).

## Self-QA — how you see your own output (build this first, in Phase 0)
Full spec: `docs/SELF-QA-HARNESS.md`. You have three ways to verify without the human:
1. **Offscreen PNG** — render any graph output to an offscreen texture and write a PNG to `selfqa/out/`. Open and inspect it. Use for all content correctness (playback, corruption, composite). No hardware, no permissions.
2. **DVC100 loopback** — capture the real analog-facing signal (app → HDMI card → HDMI-RCA → DVC100) and write both PNG frames and a metrics JSON (effective fps, dropped/dup frames, interlace combing, signal present). Use to verify the SD output path. Needs hardware + one-time camera permission (already granted by the human — see `docs/ONE-TIME-SETUP.md`).
3. **Virtual MIDI** — create a virtual CoreMIDI source in a test and send messages to self-verify detect/mapping without the physical controller.
Every visual/output acceptance item is checked by you via these before it counts as done. Save the PNGs/metrics you used as evidence under `selfqa/out/<phase>/`.

## Task queue (owner rule, 2026-09-29)
**All tasks go through `docs/QUEUE.md`.** Append every new request there (verbatim)
before starting it, work the queue top to bottom one item at a time, and move an item
to Done only with its commit hash and how it was verified. Rules are in the file.

## Workflow rules
1. Read the current phase's acceptance in `@docs/BUILD-PLAN.md` first. Work through phases in order, but **keep going across phases in one run** — don't stop between phases to ask permission.
2. After changes to `Core`, run `scripts/test.sh`. Before a phase counts as done, run `scripts/verify.sh` AND the relevant self-QA checks; verify.sh must exit 0.
3. Commit per phase (buildable commits) so progress is checkpointed if a run is interrupted.
4. **Self-debug loop:** when a self-QA check fails, read the PNG/metrics, form a hypothesis, fix, re-run — iterate. Don't surface a failure to the human that you can diagnose from the artifacts yourself.
5. **Only stop for the human when** (a) you've reached the clickable-app milestone (Phase 2 done + self-verified), or (b) you're truly blocked: missing hardware/permission/sample media, or an LGPL/GPL licensing wall. On a blocker, write what's needed to `docs/BLOCKED.md` and stop; don't thrash.
6. Update `docs/BUILD-PLAN.md` checkboxes and any touched `/Docs` as part of done.
7. Keep hardware behind protocols with mocks so `Core` still builds/tests headlessly even when the DVC100 isn't attached.

## Devices & sample media
- Device names/IDs and paths live in `config/devices.json` (copy from `config/devices.example.json`; the human fills real values). Read device identity from there — never hardcode.
- Sample videos are in `samples/` with a `samples/manifest.json`. There must be at least one real MPEG-2 file (`motion.m2v`): the libav path and the MPEG corruptor need a genuine bitstream. `.dv` files play as ordinary video through AVFoundation (no bitstream effects); many self-QA checks still use `bars.dv`/`motion.dv` as SD fixtures. If `samples/` is empty or has no `.m2v`, that's a blocker (rule 5b).

## Smooth playback outranks everything

**The picture must never stutter. This is the highest priority in the app — above any
feature, any effect, any piece of UI.** A dropped frame is visible to an audience; a
missing feature is not. If a change would risk the frame rate, it does not ship, or it
ships behind a switch that is off.

The rules that follow from that:

- **Measure the WORST frame, not the mean, on the live loop.** `scripts/selfqa.sh stress`
  times the whole display-link tick (graph + UI) under full load on a release build.
  The graph-only check in `selfqa ui` cannot see UI or presentation stalls — it missed a
  halved frame rate. Never time a debug build.
- **Budget is one frame at the project rate — 33.4 ms at 29.97.** Measure on real HD footage too (`VIDEOBOY_SOAK_CLIPS`, `selfqa decode`): the SD fixtures hide decode cost. Measured 0.4.6 (2026-09-26), full load: SD fixtures **mean 6.2 ms, worst ~7 ms**; 10-min soak on 2× 1080p H.264 + ProRes + DV **0 dropped, 0 ticks over 16 ms, worst 16.5 ms, memory flat**. Re-measured 2026-09-28 after the DV removal: stress mean 6.4 ms, p95 6.6, worst 17.8; 10-min soak on 2× 1080p H.264 + ProRes + 4K HEVC **0 dropped, 4 ticks over 16 ms, worst 18.2 ms, memory flat, 0 leaks** (`docs/AUDIT-2026-09-28.md`). Remaining occasional stall: the GPU fence (~8 per 5 min, up to 19 ms, cause open — `docs/AUDIT-2026-09-26.md`). Headroom is the safety margin, not spare capacity.
- **Nothing expensive on the render path.** No allocation per frame where a cached
  buffer will do, no CPU pixel loops (`ImageBuffer(width:height:r:g:b:)`, not
  `setPixel` in a loop), no synchronous file or network I/O, ever.
- **Effects must early-return when bypassed or neutral.** Every node here does; keep
  it that way. It is what makes a long chain cost nothing when it is not in use.

**Invariants of the frame path — break one and the app stutters or plays wrong:**
- **The graph is FRAME-clocked.** A clip advances one frame per render; echo/feedback
  step once per render. So the engine renders once per 29.97 content frame
  (`Engine.contentFrameDue`), never per display refresh — unpaced, a 60 Hz screen played
  every clip at 2× and a 120 Hz one at 4×.
- **Passes submit, they do not wait.** Use `metal.submit(commandBuffer, label:)`, never
  `waitUntilCompleted()` in a node: one queue orders everything, and the engine fences
  ONCE per frame (`waitForIdle`). Only a CPU readback waits (on its own buffer). Per-pass
  waits cost ~11 ms/frame. Fallback switch: `VIDEOBOY_SYNC_EVERY_PASS=1`.
- **Decoding never happens on the tick.** Each clip decodes ahead on its own queue (`ClipPrefetcher`); the live tick waits at most 5 ms for a frame it did not get ahead of, then holds its previous picture (`Engine.liveMissWaitLimit`; fallback `VIDEOBOY_BLOCKING_DECODE=1`). Sources are decoded no larger than the canvas needs and fitted to it on the GPU (`CanvasFit`); nothing enters the graph at HD.
- **The library is saved** in an SQLite catalog (`Catalog`, `~/Movies/Videoboy/Videoboy Catalog.vbcatalog` by default), written through by `LibraryModel` on its own queue. Self-QA never attaches the person's catalog — only scratch ones. **Imports run as a background `ImportJob`**; nothing about adding clips (walking folders, posters, measuring) may run on the main thread. `selfqa import` (1,000 clips dropped mid-show) must show 0 dropped frames.
- **Per-frame CPU pictures go through `TextureUploader`** (reused, double-buffered,
  SIMD swizzle), never `makeTexture(from:)`, which allocates — 165 MB/s at full load.
- **In-window previews never wait for vsync** (`displaySyncEnabled = false`) and skip
  presenting while their window isn't visible; a blocked `nextDrawable()` stalls the
  whole tick. Only the output window syncs to its display.
- **Automation is sampled at the frame's presentation time, before it renders**
  (`Engine.onBeforeRender`). Fades and sweeps read `framePresentationTime`, never
  `CACurrentMediaTime()` after the render — that wanders with tick cost and made a
  pushed picture jump 13–30 px per frame. `selfqa push-fade` asserts it.
- **The render clock is a SCREEN display link, never a view's.** A view's link stops
  when its window is hidden — and the same loop feeds the output, so hiding the main
  window froze the analog signal. `selfqa stress` asserts the hidden-window case.

## Code standards (from SPEC §1.5 — non-negotiable)
- Clarity over cleverness. Boring, obvious, repairable code. A little bloat is fine if it aids stability or legibility.
- Every file opens with a header comment (purpose, I/O, connections, how to extend). Doc-comment types and non-trivial functions. No magic numbers — use the param-code table.
- Prefer a little duplication over the wrong abstraction. Extract shared code only once the pattern is real.
- Fail visibly: no swallowed errors; log with subsystem tags (`[dv]`, `[clock]`, `[midi]`). Missing file/device/dep degrades to a labeled, greyed state — never a crash.
- Feature-flag in-progress subsystems so half-built work ships disabled.
- Unit-test the fragile bones: clock/scheduler + latency compensation, param-code resolution, template round-trip.

## Verifying UI
`selfqa ui` calls `mouseDown` directly: it skips hit-testing, first-click activation and real modifier delivery. For anything the human clicks, also check the real app (`scripts/run.sh`) — route checks through `hitTest`, and assert that new UI never moves existing controls (a performer's hands are on them).

## Layout is fixed
Inside VJ mode, SPEC §14 is normative and `docs/mockups/layout-v6.html` is the visual source of truth. The window also gets a bottom mode bar (Import / VJ / Settings, ⌘1–⌘3) merged with the status strip (proposal §4) — open it before writing any UI code. Do not redesign the arrangement, do not substitute a simpler shell, do not use floating/movable windows. Use real AppKit controls (NSPopUpButton, NSSegmentedControl, NSSwitch, NSSlider, NSCollectionView); don't hand-roll replacements.

## Guardrails
- Licensing: build/vendor FFmpeg as **LGPL** (no GPL components) since the app is distributed. If a GPL component would be pulled in, STOP and report. libretro emulator cores (later phases) are GPL → run **out-of-process**, never linked.
- User-supplied assets (ROMs, disk images, copyrighted media) are referenced by path, never bundled or downloaded.
- No secrets in the repo. No network calls at runtime except where a phase explicitly specifies (IP feed). Build-time network limited to package registries.
- Hardware behavior (displays, capture, MIDI) sits behind protocols with mock implementations so `Core` builds and tests headlessly. Do not fabricate hardware results or claim a `[HARDWARE]` path works without human confirmation.
- Don't add scope. If a change isn't in the current phase, note it in `docs/BUILD-PLAN.md` backlog and move on.

## Local model delegation
`qwen` runs Qwen3-Coder-30B locally. Invoke it as the global instructions say — `qwen -1 'instruction' </dev/null`, or `cat file | qwen -1 'instruction'`. The bare `qwen "<prompt>"` form blocks forever on inherited stdin.

Delegate to it: doc comments, commit messages, mechanical renames, summarizing long logs, first-pass summaries of unfamiliar files, test scaffolding, localization strings.

Never delegate: architecture, Swift concurrency, retain cycles, anything spanning more than three files, anything touching the build graph.

The model's Swift knowledge is weak and outdated. Always include the relevant existing code in the prompt rather than relying on its recall.

Never apply a delegated patch without running `scripts/build.sh` first.

## Repo hygiene
- `.claudeignore`: exclude `build/`, vendored binaries, any user media/ROMs.
- `.claude/settings.json`: deny destructive shell (`rm -rf`, disk tools) and network beyond registries.
- `docs/SPEC.md` is reference only; `CLAUDE.md` + `BUILD-PLAN.md` govern when they conflict.
