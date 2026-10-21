# Rewrite plan — 2026-10-19

> **Amended 2026-10-21 by `docs/GAME-PLAN-2026-10-21.md`.** That file sets the order
> of work (R4 moves ahead of R3; new performance phases sit between), replaces the
> rules below, and corrects R0, R1 #4, R2 and R3. Where the two disagree, the game
> plan wins.

A staged rewrite in place, written to be executed by an autonomous Claude Opus run,
one phase per run. It follows from the 2026-10-19 static audit (findings are quoted
inline with file:line as of commit `a4aeb32`).

## Why not a greenfield rewrite

`Core/` is sound: the bitstream parsers are bounds-checked, the clock and latency
compensation, param codes and template round-trip are unit-tested (915 test
functions), the frame-path invariants in CLAUDE.md hold in the code, and the measured
budget has headroom. Throwing it away re-risks the one thing the project says must
never regress (smooth playback) for no gain.

What is actually broken sits in four places:

1. **The verification gate lies.** Skipped self-QA sections still read PASS, lint
   cannot warn, and the load test of record is not in `verify.sh`.
2. **Persistence can lose the performer's library and show** (non-transactional
   migration, swallowed BEGIN, non-atomic show write).
3. **`ShellController.swift` is a 3,965-line god object** that duplicates engine
   state by hand and has no tests.
4. **The wedge is off by default and its beat reseed is overwritten every tick**, so
   the product's thesis is not true in the running app.

So the rewrite is: fix the gate so every later phase is honestly checked, fix the
data-loss bugs, rebuild the App layer around a single show model, then turn the wedge
on for real. Phases are ordered so each one makes the next one safer to do.

## Rules for the executing agent

- One phase per run. Read this file, `CLAUDE.md`, and the phase's section. Do not
  start the next phase in the same run unless the current one's acceptance passed.
- **Every phase ends with `scripts/verify.sh` exiting 0 AND the phase's named self-QA
  checks passing on a release build**, with evidence pinned under
  `selfqa/out/rewrite/<phase>/`. Record the commit hash and the checks run in
  `docs/QUEUE.md` (owner rule).
- Commit per phase, buildable. Small phases may be several commits; never one
  commit that carries two phases.
- **Frame-path invariants from CLAUDE.md are hard constraints.** If a change makes
  `selfqa stress` worst-tick worse than the current pinned number, it does not ship.
- **The window layout does not move.** `selfqa ui` asserts control positions; any
  extraction that moves a control is wrong.
- No new scope. Anything discovered that is not in this plan goes into
  `docs/BUILD-PLAN.md` backlog with one line.
- Stop and write `docs/BLOCKED.md` only for: missing hardware, missing samples, a
  licensing wall, or an acceptance check that fails three fix attempts in a row.
- Do not add Apple Developer Program, signing, or distribution work.

Estimated cost per phase is given as a rough guide for planning the runs, not a
budget to fill.

---

## Phase R0 — Make the gate honest

Nothing else in this plan can be trusted until a green `verify.sh` means something.
Do this first and do not touch product code in this phase.

### Changes
- `Core/Sources/VideoboyCore/SelfQA/SelfQACheck.swift:117-150`: add
  `check.skip(reason:)` that records a `.blocked` outcome. Verdict becomes
  `PASS` only when no section was skipped; a skip yields `BLOCKED`. Replace every
  `check.note(... "skipped")` with `check.skip` (at least: `UISelfQA.swift:1166,
  1397, 1444, 2594, 2623, 2749`, `ABRollSelfQA.swift:385`, `AVE5SelfQA.swift:127`,
  `LockSelfQA.swift:232, 249`, `UndoSelfQA.swift:123, 141`, `FXFocusSelfQA.swift:161`,
  `FullScreenSelfQA.swift:340`; grep for the rest).
- `scripts/selfqa.sh` / `App/.../SelfQARunner.swift:113-116`: `BLOCKED` exits
  non-zero from `verify.sh` (keep exit 0 for a hand run so the human can still see
  partial output). Add a `--allow-blocked` flag used only by hand.
- `scripts/verify.sh`: add `stress`, `midi`, `audit`, `template`, `mosh`, `undo`,
  `lock`, `push-fade` to the gate. Keep `soak` opt-in (10 minutes) but add a
  `scripts/verify.sh --soak` that runs it.
- `scripts/lint.sh:44-48`: pass `"${FFMPEG_FLAGS[@]}"` so the warning build actually
  builds; call `scripts/verify/warnings.sh` from `verify.sh`; fix the warnings it
  finds (the titler pointer-lifetime one is undefined behaviour; fix it properly, do
  not silence it).
- `samples/`: `scripts/verify.sh` runs `scripts/make-fixtures.sh` when `motion.m2v`
  is missing, and fails if it still is afterwards.
- Evidence tree: delete the six committed `FAIL` and two `BLOCKED` `result.txt`
  files under `selfqa/out` (`git ls-files selfqa | grep result.txt`, then grep
  `verdict`). Re-pin only green evidence from this phase's run.
- `docs/QUEUE.md`: move Q1 and Q2 to Done with `a4aeb32` and the 2026-10-10
  `ab-roll` evidence. Tick the matching boxes in `docs/BUILD-PLAN.md:240-249`.

### Acceptance
- `scripts/verify.sh` exits 0 on the Mac Studio with every added check in it, and
  exits non-zero when `samples/motion.m2v` is renamed away (prove it, then restore).
- `scripts/lint.sh` reports at least the warnings `warnings.sh` reported before
  the fixes, then 0 after.
- `selfqa/out/audit/result.txt` is PASS (the five inert emulated-titler faders
  from audit L3 are either wired or removed; "enabled but unwired" is 0).

Rough cost: one short run.

---

## Phase R1 — Correctness fixes, one commit each

Small, independent, each with a unit test where Core is involved. Land in this
order; none depends on another.

| # | Fix | Where | Test |
|---|---|---|---|
| 1 | **Beat reseed overwritten.** Only apply `.corruptSeed` from the registry when the registry value *changed* since last apply (same pattern as `.position` at `ClipSourceNode.swift:879`); the scheduler's reseed wins otherwise. | `Core/.../ClipSourceNode.swift:876` | New Core test: schedule a beat, tick, assert `corruption.seed` equals the beat seed, not the default. |
| 2 | **Show file not atomic.** `write(to: url, options: .atomic)`. | `Core/.../TemplateDocument.swift:233` | Existing round-trip test plus a test that the write of an unencodable document leaves the old file intact. |
| 3 | **Migration not transactional.** Each `if version < N` block runs inside `BEGIN`/`COMMIT` with `ROLLBACK` on throw, and checks `PRAGMA table_info` before each `ALTER`. | `Core/.../Catalog.swift:185-192` | Test: open a v1 catalog that already has `optimized_path`; it must open and end at version 2. |
| 4 | **Transactions.** `BEGIN` failure is an error (log + skip the batch, never autocommit it); `ROLLBACK` on any step failure; set `sqlite3_busy_timeout(db, 2000)` at open. | `Core/.../Catalog.swift:130, 381-385` | Test with a second connection holding a write lock: the batch waits, then lands whole. |
| 5 | **ISF header ints.** `Int(exactly:)` with a clamp, and a depth limit (32) in `ISFSizeExpression`. | `ISFDocument.swift:349`, `ISFNode.swift:267`, `ISFSizeExpression.swift:91-159` | Test: header with `"MAX": 1e300` and a 10,000-paren expression both parse to an error, not a trap. |
| 6 | **H.264 scaling list overflow.** Do the arithmetic in `Int` and bounds-check `delta`. | `H264Syntax.swift:219` | Test with `delta = Int32.max`. |
| 7 | **FSEvents watcher lifetime.** Retained context box with `retain`/`release` callbacks; `stop()` before the box is released. | `ISFFolderWatcher.swift` | Test: start, drop the last reference while events are queued, no crash under ASan (`swift test -Xswiftc -sanitize=address` once, by hand). |
| 8 | **MPEGTSStreamer teardown.** `headerWritten` flag; `close()` skips `av_write_trailer` when false. | `MPEGTSStreamer.swift:159, 218-231` | Test: open with an unreachable URL, deinit, no crash. |
| 9 | **Template node teaches the forbidden pattern.** `metal.submit(commandBuffer, label:)`; same in `CharacterGeneratorNode.swift:300-340` (and replace its `makeTexture(from:)` with `TextureUploader`). | `_Template/ExampleNode.swift:120` | Existing offscreen test; grep in `lint.sh` that forbids `waitUntilCompleted` outside `SelfQA/` and `OffscreenRenderer`. |
| 10 | **Modal on stop-recording.** Route through `presentNotice`; same for `AppDelegate.swift:271`. | `ShellController.swift:639` | `selfqa record` asserts no modal panel is on screen after stop. |
| 11 | **Button automation after render.** Move `fireActionTriggers` and `flipAutomatedButtons` into `onBeforeRender` and sample `framePresentationTime`. `beginMove` stamps `startedAt` from the next presentation time, not `CACurrentMediaTime()`. | `ShellController.swift:3922, 3235, 1475` | `selfqa push-fade` plus a new `selfqa cut-on-beat` check: a scheduled CUT lands on the frame whose presentation time is the beat. |
| 12 | **Superseded loads retire on main.** Hand the stale `PreparedClip` to the retire queue in both early returns. | `Engine.swift:1079-1085, 1114-1115` | `selfqa playback` with rapid re-loads shows no main-thread stall over 5 ms (`MainThreadSampler`). |
| 13 | **Preferences save on every assignment.** Coalesce on a utility queue with a 250 ms debounce and a flush at quit. | `Preferences.swift:349-355` | Unit test: ten assignments produce one write. |
| 14 | **Launch VACUUM on main.** Run the weekly backup on the catalog queue after the first frame is up. | `Catalog.swift:130, 353-362` | `selfqa stress` from a cold launch with a large scratch catalog shows no launch stall. |
| 15 | **Logger stderr queue unbounded.** Drop lines (counting drops) when the output queue is more than 1,000 behind. | `Logging.swift:102-106` | Unit test with a blocked pipe. |
| 16 | **Swallowed errors worth seeing.** Log and surface: `ImportJob.swift:208` bookmark, `EmulatorController.swift:326, 339` config write, `PanelSet.swift:216` malformed manifest, `AmigaSystemInstaller.swift:248` missing backup. | as listed | Each gets a `Log.error` with a subsystem tag; manifest case gets a unit test. |

### Acceptance
`scripts/test.sh` green with the new tests; `scripts/verify.sh` (the R0 gate) green;
`selfqa stress` worst tick no worse than the pinned number.

Rough cost: one to two runs.

---

## Phase R2 — Readback off the tick (recording, streaming, scopes, data burn)

The one remaining structural violation of "nothing expensive on the render path".

### Design
- New `Core/Sources/VideoboyCore/Render/ReadbackService.swift`. Per frame, for each
  texture a consumer has asked for, encode **one blit** into a shared `MTLBuffer`
  from a ring of three per consumer, on the engine's queue (submitted, not waited).
  A single completion handler per frame (registered on the engine's fence buffer, not
  on each node's) marks the ring slot ready and dispatches to a dedicated serial
  `videoboy.readback` queue.
- On that queue: vImage BGRA→RGBA permute (the `TextureUploader` already does the
  reverse; reuse its approach) into a reused `ImageBuffer`, then hand to consumers.
- Consumers become sinks on the readback queue: `FrameRecorder.write`,
  `MPEGTSStreamer.send`, `ScopeRenderer.compose`, and the Datamosh staging copy
  (`DatamoshNode.swift:332-341`), each with its own bounded queue (drop oldest,
  count drops, surface the count on the status strip).
- `ImageBuffer.fromBGRA` (`ImageBuffer.swift:139-145`) per-pixel loop is deleted in
  favour of the vImage path.
- `DataBurnRenderer`: pre-render a glyph atlas once per font/size; per frame, only
  blit changed glyph cells into a persistent texture. No `CGContext` on the tick.

### Changes outside Core
- `ShellController.swift:3906-3913` and `OutputRouter.swift:340`: replace the
  synchronous calls with registrations on `ReadbackService`.
- `RecordingSession.swift:117-126`: becomes a sink.
- Recording timestamps keep coming from `RecordingClock` with the frame's
  presentation time, not the time the readback finished.

### Acceptance
- New `selfqa stress --record --stream --scopes` (audit H4) on a release build:
  all seven feeds armed, one UDP stream, both scopes, timecode on. Worst tick ≤
  the pinned plain-stress worst tick + 2 ms; 0 dropped frames in 5 minutes.
- `selfqa record` audio/video sync unchanged (the 2026-10 take-audio check).
- Unit test: `ReadbackService` with a mock consumer that blocks for 100 ms drops
  frames for that consumer only and never blocks the caller.

Rough cost: one to two runs.

---

## Phase R3 — The App rewrite: one show model, thin controllers

This is the phase the word "rewrite" refers to. It is done as a strangler: the
model is introduced first, then `ShellController` is emptied into it section by
section, with `selfqa ui` green after every extraction.

### R3.1 — `ShowModel` in Core
A single source of truth for everything the shell currently holds by hand:
- channels: loaded clip, play state, loop mode, speed, queue (`ShellController.swift:171, 1085`)
- chains per channel and bus, with card instances (`:2231`)
- MIDI mappings, roll/advance state (`:1791`), lock state, A/B roll plan
- transport settings, output routing, recording arms

`TemplateDocument` becomes the serialisation of `ShowModel` (one `Codable`
conversion, both directions, with the existing unknown-code preservation).
`UndoHistory` records `ShowModel` diffs instead of ad-hoc closures where it does
today. The model is a plain class, main-thread confined, with an `observe` API
that delivers coalesced change sets (one callback per run-loop turn, not one per
property), so panels reload at most once per turn.

Engine reads the model; it does not keep parallel copies. Where Engine today owns
state the UI also mirrors (`isPlaying`), Engine becomes the writer and the model the
reader, or vice versa, but never both. Write down which in the file header.

Tests (Core, headless): model ↔ template round-trip equals the existing template
tests; undo/redo over a scripted sequence; observer coalescing.

### R3.2 — Extract controllers from `ShellController`, one per MARK section
Target shape of `App/Sources/Videoboy/UI/`:

| New file | From `ShellController.swift` | Owns |
|---|---|---|
| `RecordingController.swift` | `:555` | arming, takes, the record button, the finished notice |
| `OptimizeController.swift` | `:762` | copy + optimize queue UI |
| `MIDILearnController.swift` | `:816` | detect sessions, the M badges, bus-key learn |
| `TemplateController.swift` | `:1507` | File menu, open/save/autosave, recent list; file I/O off main (`:1588, 1630` existence checks included) |
| `ABRollController.swift` | `:1776, 1933` | roll/advance planning |
| `EffectChainController.swift` | `:2213, 2666` | chain edits, card instances, ISF status polling (`:2639` timer becomes event-driven from `ISFCompiler`) |
| `SourceControlsController.swift` | `:2350, 2537` | generator and ISF generator panels |
| `MonitorDataController.swift` | `:2826` | NAME/TC overlay |
| `WipeController.swift` | `:3095` | AVE-5 |
| `OutputController.swift` | `:3802` | router, destinations |
| `TransportAutomation.swift` | `:3235, 3066` | the `onBeforeRender` sampling of fades, sweeps, cuts, button flips (from R1 #11) |

`ShellController` keeps: window wiring, the per-frame `refresh` dispatch, and
ownership of the controllers. Hard limit **600 lines** when done.

Rules for every extraction:
- Move code, do not rewrite behaviour. One extraction per commit.
- State moves into `ShowModel`, never into the new controller, unless it is pure
  view state (hover, popover open).
- After each commit: `scripts/build.sh`, `scripts/selfqa.sh ui`, and the self-QA
  check named for that feature (`record`, `template`, `ab-roll`, `fx-focus`,
  `mosh`, `undo`, `lock`, `midi`). Control positions must be byte-identical in
  `selfqa/out/ui/layout.json` (add that dump in R3.0 if it does not exist).

### R3.3 — App test target
Add `App/Tests/VideoboyTests` with XCTest, run by `scripts/test.sh`. First tests:
each controller constructed against a `ShowModel` and a mock `Engine` protocol
(introduce `EngineControlling` protocol for the handful of methods controllers
call), driving the same scenarios the self-QA checks drive, headless. Target: every
controller has at least one test; `TemplateController` and `TransportAutomation`
have the most.

### R3.4 — Import and library
`ImportJob.swift:140` hands batches to main via a semaphore and the main-thread
side builds catalog records and triggers a 25 to 35 ms layout pass
(`LibraryPanelBody.swift:492`). Change: build `CatalogClip` records on the import
thread, hand only the finished array to main, and have `LibraryPanelBody` diff by
id (`NSCollectionView` batch updates) instead of rebuilding. Acceptance:
`selfqa import` (1,000 clips mid-show) still 0 dropped, and the main-thread sampler
shows no import-caused stall over 8 ms.

### Acceptance for R3
- `ShellController.swift` ≤ 600 lines; no stored property in it mirrors engine or
  model state (reviewer greps for `playingChannels`, `rollOn`, `cardInstances`,
  `queues`; all gone).
- `scripts/test.sh` runs the App tests; all green.
- Full R0 gate green; `selfqa stress` worst tick unchanged; `selfqa ui` layout
  dump identical to the pre-R3 pin.
- The human clicks through one full show (load, map, record, save, reopen) and
  signs off in `docs/QUEUE.md`. This is the one phase that needs a person.

Rough cost: three to five runs. Do not try to do it in one.

---

## Phase R4 — Make the wedge real

Only after R1 #1 and R3, because the corruptor card lands in the chain UI the
controllers now own.

- Turn `bitstreamCorruptor` on by default (`VideoboyCore.swift:85`). Leave
  `outputSignalEmulation` off; that is the owner's call, note it in BUILD-PLAN.
- Beat reseed with prefetch: when the scheduler reseeds, the prefetcher must not
  make four channels miss at once (the 5 ms `liveMissWaitLimit` each). Design:
  the scheduler publishes the *next* beat's seed one beat early; `ClipPrefetcher`
  decodes frames past the next beat boundary with the new seed. Verify with
  `selfqa stress` with four MPEG-2 clips, corruptor on, transport at 174 BPM:
  0 dropped frames, and a new `selfqa wedge` check asserting the decoded picture
  changes on the beat frame and not before.
- Remove the `UISelfQA.swift:1084-1095` assertion that the card is absent; assert
  it is present and its faders resolve to codes 31B–34B.
- Fix the remaining audit L3 faders if R0 did not.

### Acceptance
`selfqa wedge`, `selfqa stress` (corruptor on), the R0 gate. Pin the PNGs showing
pre-beat and on-beat frames.

Rough cost: one to two runs.

---

## Phase R5 — Docs and process consolidation

- Delete `docs/STATUS.md`, `docs/TODO.md`, `docs/FEATURE-LEDGER-2026-09-27.md`,
  `OVERNIGHT_LOG.md`, `OVERNIGHT_REPORT.md` from the root and docs. Replace with one
  `docs/STATUS.md` generated by a script (`scripts/status.sh`) from: test count,
  `selfqa audit` control counts, the pinned stress numbers, and the feature-flag
  defaults read from `VideoboyCore.swift`. Hand-written prose in it is limited to
  the "what is next" list.
- `config/amiga.json` moves to the gitignored device-config pattern with an
  `amiga.example.json`.
- `.claude/settings.json`: deny `rm -r*`, `git push --force*`, `git reset --hard`,
  `git clean -f*`, and `scripts/fix-permissions.sh`; keep `Bash(scripts/*)` for the
  rest.
- Large research PNGs under `docs/research` move out of the repo (link to a
  folder) in a normal commit. Do **not** rewrite history.
- `CLAUDE.md`: update the measured numbers, the `verify.sh` contents, and the
  `ShowModel` architecture line. Keep it short.

### Acceptance
`scripts/status.sh` output matches the code; `verify.sh` green; the five
contradictory documents are gone.

Rough cost: one short run.

---

## Order and dependencies

```
R0 (gate) ─▶ R1 (fixes) ─▶ R2 (readback) ─▶ R3 (shell rewrite) ─▶ R4 (wedge) ─▶ R5 (docs)
```

R1 #1 can land before R3 and should. R2 and R3 can be reordered if the human is
performing a lot and wants recording safe first; they do not touch the same files
except `ShellController.swift:3906`, which R3 moves anyway.

## What this plan deliberately does not do

- No new features. Tags, physical feedback routing, macroblock MPEG editing, IP
  video and the retro emulation ideas stay in the backlog.
- No change to the window layout, the fixed A/B→ONE, C/D→TWO routing, the
  param-code table, or the template format version.
- No change to Core's render-path design. `Engine.evaluate`'s per-frame
  `evaluationOrder` recomputation (`Engine.swift:983`) is a known allocation; cache
  it only if R2's stress numbers need the headroom, and note it in BUILD-PLAN if not.
