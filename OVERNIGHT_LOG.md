# Overnight Autonomous Session

Branch: `next`. Recovery point: tag `v0.7.0-pre-overnight` and branch
`recovery/pre-overnight`, both at **a4164ff**.

Restore everything with `git reset --hard refs/tags/v0.7.0-pre-overnight`.

Baseline commit for Phase 4's `git diff <baseline>..HEAD`: **a4164ff**.

---

## Phase 1 — Reconnaissance

### Project map

**Videoboy** — a native macOS app for live analog-style video mixing. The competitive
core is musical manipulation of compressed video bitstreams (DV / MPEG) output cleanly
to SD 480i for an analog chain.

| | |
|---|---|
| Language | Swift 6.1.2 (language mode v5), arm64 only |
| Toolchain | Xcode 16.4 (16F6), macOS 15.5 (24F74) |
| UI | AppKit (not SwiftUI) + Metal |
| Package manager | SwiftPM. **No third-party packages at all** — `App` depends only on `../Core` |
| Native dep | LGPL FFmpeg 9.0.1, vendored as arm64 dylibs under `vendor/ffmpeg`, reached through the `CFFmpeg` system-library target |
| Test framework | XCTest (Core only) + a bespoke self-QA harness for anything visual |
| Linter | `scripts/lint.sh` — bespoke. No SwiftLint, no swift-format installed |
| Type checker | The Swift compiler; there is no separate step |

Two packages:

- **`Core/`** — 59 files, 12,039 lines. All non-UI logic: bitstream engine, clock,
  param registry, render-graph model, titler, scopes. No AppKit. Builds and tests
  headlessly.
- **`App/`** — 62 files, 17,225 lines. Thin AppKit + Metal shell that links Core.
  Owns windows, panels, output. Has **no XCTest target**; it is exercised by the
  self-QA harness instead.
- **`Core/Tests/`** — 22 files, 5,817 lines.

Entry points: `App/Sources/Videoboy/main.swift` → `AppDelegate` →
`MainWindowController` → `ShellView` / `ShellController` → `Engine`.

### Verified commands

Every one of these was run and its exit status recorded.

| Purpose | Command | Result |
|---|---|---|
| Install deps | `scripts/bootstrap.sh` (vendors FFmpeg; already done) | not re-run, vendor/ present |
| Test | `scripts/test.sh` | exit 0, 17s |
| Build | `scripts/build.sh` | exit 0, 3s incremental |
| Lint | `scripts/lint.sh` | exit 0, 1s |
| Everything | `scripts/verify.sh` | exit 0 |
| Run | `scripts/run.sh` | launches `build/Videoboy.app` |
| Self-QA | `scripts/selfqa.sh {ui,offscreen,playback,analog,audit,stream,record}` | exit 0 |
| Coverage | `scripts/test.sh --enable-code-coverage` then `xcrun llvm-cov report` | works; flags must come via test.sh or FFmpeg headers are not found |

Note: bare `swift test` in `Core/` **fails** — it misses the `-Xcc -I vendor/ffmpeg/include`
flags that `_common.sh` supplies. Always go through the scripts.

### Baseline

| Metric | Value |
|---|---|
| Build | **pass**, 3s (incremental), **1 warning** |
| Tests | **325 total, 325 passed, 0 failed, 0 skipped**, 16.1s |
| Coverage (Core) | **81.14% line**, 76.98% function, 70.80% region |
| Lint | **0 errors, 0 warnings** (exit 0) |
| Type errors | **0** |
| App bundle | 8.7 MB |
| Dependency audit | **No third-party packages to audit.** One native dep, FFmpeg 9.0.1, vendored and pinned; LGPL verified (build fails if `CONFIG_GPL`/`CONFIG_NONFREE`) |

The single build warning is benign and pre-existing:
`'core': found 1 file(s) which are unhandled` — `Modules/_Template/README.md`, which is
documentation sitting in a source directory on purpose.

### Failing tests

**None.** 325/325 pass at baseline.

### Ranked risk map

Ranked by: line coverage, size, 3-month churn, and error-handling gaps. Churn is
measured over `git log --since="3 months ago"`.

| # | File | Cov | Churn | Why it is risky |
|---|---|---|---|---|
| 1 | `App/UI/ShellController.swift` | n/a | **34** | 1,697 lines, the highest-churn file in the repo, and untestable by XCTest — it is where three bugs already hid this week (dead ✕, dead enable switch, dead badges), all the same "static table has no entry" shape |
| 2 | `Core/SelfQA/MetalContext.swift` | **56%** | — | 885 lines, every shader in the app lives here as a string, and the uninitialised-render-target bug fixed tonight was in it. Shader bugs are invisible to type checking |
| 3 | `Core/Modules/Effects/BusCodecNode.swift` | **26%** | — | Lowest real coverage in Core. Does a GPU→CPU→GPU round trip per frame and touches the DV encoder; failure modes are silent |
| 4 | `Core/Persistence/DeviceConfig.swift` | **0%** | — | Zero coverage. Parses user-supplied JSON from `config/devices.json`; a malformed file is a plausible real input |
| 5 | `App/UI/LibraryPanelBody.swift` | n/a | 8 | 1,072 lines, drag-and-drop plus the new playlist tabs; drag paths already broke once |
| 6 | `Core/Modules/Effects/CompositeCodecNode.swift` | **57%** | — | 338 lines, multi-pass generation loop, reused by the titler's period preset |
| 7 | `Core/Modules/Mix/BlendMode.swift` | **39%** | — | 13 blend modes, only some exercised; wrong maths would be subtle rather than loud |
| 8 | `App/Render/Engine.swift` | n/a | **17** | 751 lines, owns graph wiring and the `applyAllParameters` list — a node missing from that list is silently never updated (this is exactly the NTSC boot bug) |
| 9 | `Core/Modules/Effects/FeedbackNode.swift` | **64%** | — | Ring-buffer indexing plus history; tonight proved its test was passing on garbage |
| 10 | `Core/Modules/Titler/CharacterGeneratorNode.swift` | **68%** | new | Written today. Period preset path is untested (needs a Metal device), and the `renderToImage` vs `render` split means two code paths can diverge |

Other signals: **1** TODO/FIXME/HACK in the whole repo (and it is a doc comment, not a
defect marker). **3** force unwraps in Core, all reviewed and all structurally safe
(`baseAddress!` inside `withUnsafeBytes`, and a `CFAttributedStringCreateMutable` that
cannot return nil for a zero-length allocation). **0** uses of `try!`.

---
## Phase 2 — Safety net

New tests, all capturing CURRENT behaviour, all run three times to confirm they are
deterministic. No source changes in this phase, and no test seams were needed.

| Module | Was | Tests added | Commit |
|---|---|---|---|
| `Persistence/DeviceConfig` | **0%** coverage, parses a user-supplied file | 18 | `16842dd` |
| `Modules/Mix/BlendMode` | 39% coverage, 13 modes | 9 | `0924a41` |
| Dead-control guard (behavioural, App) | nothing checked this | 1 | `c11ecf6` |

Two behaviours pinned deliberately because they are decisions, not oversights, and a
future reader should not "fix" them by accident:

- **DeviceConfig**: one wrongly-typed field takes the whole document down to defaults
  rather than keeping the fields that parsed.
- **DeviceConfig**: absurd geometry (width 0, height −1) is carried through rather
  than validated — this struct records what was REQUESTED, and SPEC 3 logs what
  actually gets negotiated separately.

No `SUSPECTED_BUG_` tests were left outstanding: the one suspected bug found in this
phase was confirmed outright and fixed in Phase 3 rather than left marked.

## Phase 3 — Repair

### FIXED — non-finite parameter values could trap (`d7865ab`)

**Severity: high** (crash, whole-app, though see the honest caveat below).

*Root cause:* `min` and `max` do not sanitise NaN — every comparison against NaN is
false, so both hand it straight back — and `Int(Double)` is a **fatal error** in Swift
for NaN or infinity, not a nil and not a zero.

Twelve enums are selected by sweeping a fader, and all twelve wrote the same line:

```swift
let index = Int((min(max(value, 0), 1) * Double(count - 1)).rounded())
```

`ParamRegistry.setValue` clamped the same way, so a NaN could be **stored** and then
reach all twelve readers.

*Fix, in two places on purpose:* the registry now **refuses** a non-finite write and
logs it (coercing to 0 would hide the upstream bug while moving the operator's fader);
and all twelve sweeps now go through one shared `NormalisedSweep` helper, so a value
arriving by another route — a template load, a direct property set — still cannot trap.

*Proof:* the reproducing test was run with the guard removed. It does not fail, it
takes the runner down with `Fatal error: Double value cannot be converted to Int
because it is either infinite or NaN`. Tests: `NonFiniteParameterTests`, 7 cases.

**Honest caveat.** I went looking for a live path that produces NaN today and did not
find one: `tapTempo` guards `average > 0`, `TempoEstimator` guards `secondsPerBeat > 0`
and `spread > 0`, and `Transport.beatsPerMinute` guards `> 0` — and all of those
guards reject NaN correctly, because `NaN > 0` is false. So this was a latent trap one
careless divide away from being reachable, not an active crash. It is still worth
closing: it removes the whole class, and the next person to add a modulation source
should not have to know this.

### FIXED — dead effect controls are now caught structurally (`c11ecf6`)

Not a new defect; a guard against a defect class that has already shipped three times
this week (the corruptor card's enable switch, its modulation badges, and its ✕). All
three had a target and an action, so the existing control audit passed them; all three
were wired to a handler that looked their name up in a static table, missed, and
returned. The new check flips every enabled effect switch and asserts a wet/dry
somewhere in the graph actually moved. Verified by breaking it on purpose.

### Checked and found already correct

- `tapTempo`, `TempoEstimator`, `Transport.beatsPerMinute` — all divisions guarded.
- `Color Ctrl` / `Layer Mask` effect cards resolve to no slot, but are correctly
  declared `isImplemented: false` and render disabled, per the house rule.
- Force unwraps: 3 in Core, all structurally safe (`baseAddress!` inside
  `withUnsafeBytes`, and a `CFAttributedStringCreateMutable` that cannot fail for a
  zero-length allocation). 0 uses of `try!`.

## Phases 4–6 — Verification, optimisation, health

### Phase 4 — adversarial verification

- `git diff a4164ff..HEAD` reviewed: 13 source files, +173/−24. Small and surgical.
- `ParamRegistry.setValue` is `@discardableResult` and **no** caller branches on it
  (114 call sites), so refusing a non-finite write cannot break any of them — they
  keep the previous value instead of storing garbage.
- The 10 mechanical sweep replacements are semantically identical for finite input;
  verified by reading old and new arithmetic side by side.
- **Reproducing tests proved by temporary revert**, both restored afterwards:
  the `NormalisedSweep` guard (runner dies without it) and the corruptor's slot
  resolution (dead-switch audit names both offenders).
- **Clean build from scratch**: `swift package clean` on both packages, then
  `verify.sh` — exit 0 in 94 s, 359 tests.
- **App launched and exercised**: starts clean, 25-node graph, three displays
  enumerated, no errors in 8 s of runtime, terminated cleanly and left no process.
  The startup log confirms the window fix on real hardware — **1766×970**, up from a
  hardcoded 1460×912 — and explains the stale `output-stage` failure (the third
  display is `MACROSILICON` at 1280×1024, the capture card).
- Verification script committed to `scripts/verify/warnings.sh`.
- **Nothing reverted.** No change failed verification.

### Phase 5 — measured optimisation

Profiled the suite; slowest tests are real decode and real Metal work, not artificial
waits. Two candidates measured:

| Location | Before | After | Change | Kept? |
|---|---|---|---|---|
| `ImageBuffer` solid fill | 1.489 ms/frame | 0.233 ms/frame | −84% | yes (`09a1b5c`) |
| `DVDecoder` redundant 120 KB copy | 2.85 ms/frame | 2.85 ms/frame | 0% | kept as a **warning fix**, not claimed as perf (`37f3f33`) |

Both measured in a **release** build, which is what ships. An earlier debug-build
figure of 66 ms/frame for the solid fill was an artefact and is not a user-visible
number.

### Phase 6 — code health

42 warnings cleared (`f235f0a`), all non-behavioural: 40 discarded `try?` results, one
dead downcast, one `try?` on a non-throwing call that made a guard unfailable. The
12 duplicated sweep implementations were consolidated into `NormalisedSweep` during
Phase 3, which is the "3+ identical copies" case.

Deliberately **not** done: the 11 deprecated AVFoundation calls, whose replacements
are async and would change public signatures. Written up as a proposal.

---

Final state: **363 tests, 0 failures. verify.sh exits 0. Nothing blocked.**
