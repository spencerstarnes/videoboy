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
