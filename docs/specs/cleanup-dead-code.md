# Brief — remove dead code and per-beat log noise

**For:** an implementing session (Sonnet). **Written:** 2026-09-27, against commit
`c1a2421` (version 0.4.7) on branch `perf/audit`. **Size:** small. Mechanical and
behaviour-neutral; nothing a performer can see or hear may change.

Background: `docs/AUDIT-2026-09-26.md`, items **L6** (dead declarations) and **L7** (log
noise). Read `CLAUDE.md` first; its rules apply, especially *build through the scripts*
and *stage by name*.

---

## 1. Delete these 21 declarations

Each one appears **exactly once** in `App/Sources`, `Core/Sources` and `Core/Tests`: its
own declaration, with no caller anywhere (verified by `grep -rnw <name>` on `c1a2421`).
Delete the declaration, plus its doc comment and any code that exists only to support it.
Line numbers are approximate, so find each one by name.

| # | Declaration | File |
|---|---|---|
| 1 | `func groupedPopUp` | `App/Sources/Videoboy/UI/Controls.swift` (~196) |
| 2 | `func setAllCollapsed` | `App/Sources/Videoboy/UI/EffectChainPanelBody.swift` (~1176) |
| 3 | `var blendPopUp` | `App/Sources/Videoboy/UI/PanelBodies.swift` (~602) |
| 4 | `func setBlendMode` | `App/Sources/Videoboy/UI/PanelBodies.swift` (~1009) |
| 5 | `private var ntscDetailButton` | `App/Sources/Videoboy/UI/SettingsBarPanelBody.swift` (~154) |
| 6 | `private var dvDetailButton` | `App/Sources/Videoboy/UI/SettingsBarPanelBody.swift` (~162) |
| 7 | `func setNegotiatedMode` | `App/Sources/Videoboy/UI/SettingsBarPanelBody.swift` (~191) |
| 8 | `bodyHeightWhenCollapsed` | `App/Sources/Videoboy/UI/PanelView.swift` (~55) |
| 9 | `panelHeaderPaddingY` | `App/Sources/Videoboy/UI/Theme.swift` (~54) |
| 10 | `groupSeam` | `App/Sources/Videoboy/UI/Theme.swift` (~535) |
| 11 | `hasOSDFace` | `App/Sources/Videoboy/UI/Theme.swift` (~604) |
| 12 | `saveStateInstructions` | `App/Sources/Videoboy/Emu/EmulatorController.swift` (~89) |
| 13 | `lastFrameCount` | `App/Sources/Videoboy/UI/EmuScreenView.swift` (~49) |
| 14 | `func resetHistory` | `Core/Sources/VideoboyCore/Clock/Scheduler.swift` (~179) |
| 15 | `carriesPicture` | `Core/Sources/VideoboyCore/Bitstream/DVFormat.swift` (~84) |
| 16 | `func pruneAcknowledgements` | `Core/Sources/VideoboyCore/Modules/Emu/AmigaCommandBridge.swift` (~381) |
| 17 | `decorations` | `Core/Sources/VideoboyCore/Modules/Emu/ScalaLingo.swift` (~243) |
| 18 | `isToggle` | `Core/Sources/VideoboyCore/Modules/Emu/TitlerControls.swift` (~165) |
| 19 | `func useLargestAvailableSize` | `Core/Sources/VideoboyCore/Modules/Emu/TitlerControls.swift` (~381) |
| 20 | `showsProgress` | `Core/Sources/VideoboyCore/Modules/Titler/NowPlaying.swift` (~121) |
| 21 | `isCorner` | `Core/Sources/VideoboyCore/Scopes/ScopeRenderer.swift` (~86) |

**Before deleting each one, re-run `grep -rnw <name> App/Sources Core/Sources Core/Tests`.**
Delete only if the sole hit is the declaration. Then:

- **Keep it** if deleting it breaks the build because it satisfies a protocol requirement
  or a `Codable` key. Write down which one and why; don't work around it.
- **#5–#6:** if the property is *assigned* somewhere (the grep shows only one hit, so it
  shouldn't be), delete the assignment too, as long as it has no other effect.
- **#13 `lastFrameCount`:** delete only if nothing reads it, including string-based
  lookups.

## 2. Do NOT delete these (they look dead but aren't)

- `Engine.loadChains` and `Engine.applyMeasuredFeedbackLatency`: unused *today*, but they
  belong to planned work (patch save/load, feedback-latency compensation: audit L1, L2).
- `ISFDocument.isValidPreamble`: used by `ISFDocument.parse`.
- Anything under `Modules/_Template/` (`ExampleNode`): the documented copy-me module.
- AppKit delegate or `@objc` methods, `override`s, and protocol conformances
  (`FakeDragging`, `outlineView…`, `validateMenuItem`, `hash`, `application…`). AppKit
  calls these by name.
- The native titler (`CharacterGeneratorNode`, `CharacterGeneratorRenderer`,
  `NowPlaying` except `showsProgress`). Whether to keep it is the owner's decision (audit
  L4), not part of this job.

## 3. Remove the per-beat log lines

In `App/Sources/Videoboy/Render/Engine.swift`, delete these two lines (~749 and ~766).
Each fires on every beat for every source and bus, about 45,000 lines an hour, and buries
real warnings:

```swift
Log.info(.clock, "source \(letter) reseeded for beat \(event.targetBeat)")
Log.info(.clock, "bus \(name) data effects reseeded for beat \(event.targetBeat)")
```

Delete **only** the log calls; the reseeding code around them stays exactly as it is.
There is no debug log level, so don't add one for this.

## 4. Verify

All of these must pass before committing. Run each from the repo root.

1. `scripts/build.sh release`: no errors and **no new warnings** from files you touched.
2. `scripts/verify.sh`: must exit 0. A flaky Datamosh timing test,
   `testTheNodeMoshesACutLiveWithoutEverWaitingOnTheTick`, sometimes fails in debug
   builds. It predates this job, so if it fails, run it once on its own with
   `scripts/test.sh --filter DatamoshNodeTests/testTheNodeMoshesACutLiveWithoutEverWaitingOnTheTick`
   and note the result.
3. `scripts/selfqa.sh audit`: still **1,259 controls, 0 enabled-but-unwired**. It is
   *expected* to fail exactly one assertion, the six emulator faders (audit L3). Any
   other failure is yours.
4. `scripts/selfqa.sh stress`: PASS. It proves the engine edit changed no timing.
5. For each deleted name, `grep -rnw <name> App/Sources Core/Sources Core/Tests` returns
   nothing, and `grep -rn 'reseeded for beat' App/Sources` returns nothing.

## 5. Update the docs

In `docs/AUDIT-2026-09-26.md`, mark **L6** and **L7** as FIXED, giving how many
declarations were removed and naming any that were kept, with the reason.

## 6. Commit

- **Other sessions share this tree.** Stage **by name** (never `git add -A` or `git add .`),
  and only files you changed. Leave `selfqa/out/` changes other than the audit's alone,
  and never stage `selfqa/out/isf/trial/` or `selfqa/out/phase-2/ui-layout/source-controls.png`.
- One commit, message like `cleanup: remove 21 unused declarations and per-beat log lines`,
  with the attribution lines your session specifies. **Do not push. Do not bump the version.**
- Never run `scripts/signing-identity.sh`. The build signs ad-hoc from an agent shell,
  which is expected; `build.sh` prints a warning about it.

## Out of scope

Anything else in the audit's open list: feature work, refactors, renames or formatting.
If you spot other dead code, **list it in your report; don't delete it**.

## Report back

Keep it under 150 words: what was removed (count and names), anything kept and why, the
four check results, and the commit hash.
