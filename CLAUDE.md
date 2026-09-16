# CLAUDE.md

Auto-loaded every session. Keep this short. Operational detail lives in `@docs/BUILD-PLAN.md`; full feature reference is `docs/SPEC.md` (read the relevant section when a phase needs it — do not load it wholesale).

## What this is
**Videoboy** — a native macOS app for live analog-style video mixing (product/bundle name: Videoboy). The competitive core ("the wedge") is **musical, playable manipulation of compressed video bitstreams** (DV / MPEG-family) output cleanly to SD (480i) for an analog chain. Everything else is supporting cast. This is NOT a general VJ tool and must not grow into one.

## Current focus
Run **autonomously** through `@docs/BUILD-PLAN.md` Phases 0–2 and produce a **launchable, clickable macOS app** before the human engages. The human's first experience must be a running app they can click and play with — bugs and missing features are fine; a non-launching or headless-only result is not. You verify your own work with the self-QA harness (see below) — do not wait for the human to test. Stay in MVP scope (the bitstream wedge + clean SD output); later phases (generators, ISF host, titler, scopes, IP, SVG) stay untouched. When unsure whether something is in scope, it isn't.

Do **not** pursue Apple Developer Program, notarization, or distribution signing. Run the app **locally, unsigned** (ad-hoc `codesign --sign -` is fine). The app is a proper `.app` bundle with `NSCameraUsageDescription` set (required or camera access crashes).

## Environment (Mac Studio, Apple Silicon)
- Target arm64 only. Do not add x86 assumptions or Rosetta steps.
- Detect, don't hardcode: run `sw_vers`, `xcodebuild -version`, `swift --version` and target what's installed. Metal is the render backend.
- Third-party deps: SwiftPM only. Any vendored binary (FFmpeg xcframework, libretro cores) must contain an arm64 slice.

## Architecture (keep this shape)
- `Core/` — a SwiftPM package holding all non-UI logic: bitstream engine, clock/scheduler, param-code registry, template read/write, render-graph model. **Must build and pass `swift test` headlessly.** This is where the wedge lives and where most work happens.
- `App/` — a thin AppKit + Metal target that links `Core`, owns windows/output/UI. Built with `xcodebuild`.
- `UI/` — the canonical window shell from SPEC §14 (normative). Build the full 5×5 panel grid with real AppKit controls; unfinished features render disabled, never omitted. All radii/padding/gutters live in one `Theme` token file.
- One extension point only: the render-graph `Node` protocol (see `docs/SPEC.md` §2, §1.5). Adding a source/effect/output = implement it + drop a manifest. No parallel plugin systems.

## Commands (create these scripts in Phase 0, then always use them)
- `scripts/test.sh` → `swift test` on `Core` (fast loop; run after every change to Core).
- `scripts/build.sh` → build `Core` then `xcodebuild` the app, arm64, into `build/`.
- `scripts/run.sh` → launch the built `.app`.
- `scripts/verify.sh` → build + test + lint; must exit 0 before any phase is "done."

## Self-QA — how you see your own output (build this first, in Phase 0)
Full spec: `docs/SELF-QA-HARNESS.md`. You have three ways to verify without the human:
1. **Offscreen PNG** — render any graph output to an offscreen texture and write a PNG to `selfqa/out/`. Open and inspect it. Use for all content correctness (playback, corruption, composite). No hardware, no permissions.
2. **DVC100 loopback** — capture the real analog-facing signal (app → HDMI card → HDMI-RCA → DVC100) and write both PNG frames and a metrics JSON (effective fps, dropped/dup frames, interlace combing, signal present). Use to verify the SD output path. Needs hardware + one-time camera permission (already granted by the human — see `docs/ONE-TIME-SETUP.md`).
3. **Virtual MIDI** — create a virtual CoreMIDI source in a test and send messages to self-verify detect/mapping without the physical controller.
Every visual/output acceptance item is checked by you via these before it counts as done. Save the PNGs/metrics you used as evidence under `selfqa/out/<phase>/`.

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
- Sample videos are in `samples/` with a `samples/manifest.json`. There must be at least one real `.dv` file (DV can't be decoded by AVFoundation, so the libav path and DIF corruptor need a genuine fixture). If `samples/` is empty or has no `.dv`, that's a blocker (rule 5b).

## Code standards (from SPEC §1.5 — non-negotiable)
- Clarity over cleverness. Boring, obvious, repairable code. A little bloat is fine if it aids stability or legibility.
- Every file opens with a header comment (purpose, I/O, connections, how to extend). Doc-comment types and non-trivial functions. No magic numbers — use the param-code table.
- Prefer a little duplication over the wrong abstraction. Extract shared code only once the pattern is real.
- Fail visibly: no swallowed errors; log with subsystem tags (`[dv]`, `[clock]`, `[midi]`). Missing file/device/dep degrades to a labeled, greyed state — never a crash.
- Feature-flag in-progress subsystems so half-built work ships disabled.
- Unit-test the fragile bones: clock/scheduler + latency compensation, param-code resolution, template round-trip.

## Layout is fixed
SPEC §14 is normative and `docs/mockups/layout-v6.html` is the visual source of truth — open it before writing any UI code. Do not redesign the arrangement, do not substitute a simpler shell, do not use floating/movable windows. Use real AppKit controls (NSPopUpButton, NSSegmentedControl, NSSwitch, NSSlider, NSCollectionView); don't hand-roll replacements.

## Guardrails
- Licensing: build/vendor FFmpeg as **LGPL** (no GPL components) since the app is distributed. If a GPL component would be pulled in, STOP and report. libretro emulator cores (later phases) are GPL → run **out-of-process**, never linked.
- User-supplied assets (ROMs, disk images, copyrighted media) are referenced by path, never bundled or downloaded.
- No secrets in the repo. No network calls at runtime except where a phase explicitly specifies (IP feed). Build-time network limited to package registries.
- Hardware behavior (displays, capture, MIDI) sits behind protocols with mock implementations so `Core` builds and tests headlessly. Do not fabricate hardware results or claim a `[HARDWARE]` path works without human confirmation.
- Don't add scope. If a change isn't in the current phase, note it in `docs/BUILD-PLAN.md` backlog and move on.

## Repo hygiene
- `.claudeignore`: exclude `build/`, vendored binaries, any user media/ROMs.
- `.claude/settings.json`: deny destructive shell (`rm -rf`, disk tools) and network beyond registries.
- `docs/SPEC.md` is reference only; `CLAUDE.md` + `BUILD-PLAN.md` govern when they conflict.
