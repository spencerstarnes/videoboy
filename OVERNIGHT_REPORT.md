# Overnight Report

## Summary

Five defects fixed, two of them real undefined behaviour and one a latent whole-app
crash. 38 tests added, coverage 81.14% → 82.27%, suite still green at 363/363.
One measured optimisation (84% faster solid fill) and one measurement honestly
reported as **not** a win. The most useful finding was not a bug but a tooling gap:
`lint.sh` reports clean from an incremental build, which had been hiding eight real
warnings — including the undefined behaviour. Nothing was reverted; nothing is blocked.

## Metrics

| Metric | Baseline (`a4164ff`) | Final | Δ |
|---|---|---|---|
| Build | pass | pass | — |
| Tests total | 325 | **363** | +38 |
| Tests passed | 325 | **363** | +38 |
| Tests failed | 0 | **0** | — |
| Tests skipped | 0 | 0 | — |
| Test duration | 16.1 s | 15.5–17 s | ~flat |
| Coverage (line, Core) | 81.14% | **82.27%** | +1.13 |
| Coverage (function) | 76.98% | **78.87%** | +1.89 |
| Coverage (region) | 70.80% | **72.35%** | +1.55 |
| Lint | 0 | 0 | — |
| Compiler warnings (clean build) | **8 Core + 43 App** (baseline said "1" — see below) | **5 Core + 6 App** | −40 |
| Type errors | 0 | 0 | — |
| App bundle | 8.7 MB | 8.7 MB | — |
| Dependency audit | no third-party packages | unchanged | — |

**The baseline warning count was wrong, and that matters.** Phase 1 recorded "1
warning" because `swift build` was incremental and did not recompile unchanged files.
A build from scratch reports 51. `scripts/verify/warnings.sh` now cleans first so this
cannot recur.

## Bugs fixed

| Severity | Bug | Root cause | Commit |
|---|---|---|---|
| **High** | A NaN or infinity parameter would trap the whole app at the next fader read | `min`/`max` do not sanitise NaN (every comparison against it is false), and `Int(Double)` is a fatal error for non-finite values. 12 enums and `ParamRegistry.setValue` all clamped this way | `d7865ab` |
| **High** | Titler alignment and leading read pointers that had already expired | `CTParagraphStyleSetting(value:)` keeps the pointer rather than copying; `&x` is valid only for the call it is passed to, and `CTParagraphStyleCreate` dereferences it afterwards | `ee756d1` |
| Medium | A guard that could never fail | `try?` wrapped `appendingPathComponent`, which neither throws nor returns an optional | `f235f0a` |
| Low | Tap tempo stacked one 30 fps timer per tap | `flashTempoChange()` created a repeating `Timer` and kept no reference, so nothing cancelled the previous one | `fb6a141` |
| Low | Dead coalescing branch in `Preferences` | `try?` had already flattened the double optional, so `?? []` could never run | `37f3f33` |

Both **High** entries are undefined behaviour that every existing test passed through.
That is the point worth carrying forward: neither was findable by running the suite.

## Performance

| Location | Issue | Before | After | Change | Commit |
|---|---|---|---|---|---|
| `ImageBuffer` solid fill | Per-pixel `setPixel` pays a bounds precondition and a uniqueness check 345,600 times per SD frame | 1.489 ms/frame | 0.233 ms/frame | **−84%** | `09a1b5c` |
| `DVDecoder.decode` | Copied a 120 KB DV frame into a `var` that was never mutated, then copied that | 2.85 ms/frame | 2.85 ms/frame | **0%** | `37f3f33` |

The second row is the honest one. Removing a redundant 120 KB copy per frame *sounds*
like a win and measured as nothing at all — libavcodec's actual decode work dwarfs it.
It was kept as a **warning fix**, not claimed as an optimisation.

One more correction worth recording: the solid-fill problem first measured at
**66 ms/frame** and looked catastrophic. That was a debug build. `scripts/build.sh`
ships release, where the same loop is 1.489 ms. The fix still clears the bar on its
own merits, but the alarming number was an artefact of how tests run and no user would
ever have seen it.

## Reverted attempts

None. No change failed verification.

Two changes were **temporarily** reverted on purpose, to prove the tests guarding them
actually catch the bug, then restored:

- The `NormalisedSweep` guard — without it the test does not fail, it takes the runner
  down with `Fatal error: Double value cannot be converted to Int`.
- The corruptor's dynamic slot resolution — the new dead-switch audit failed and named
  both offenders precisely.

## BLOCKED

None.

## UNCONFIRMED

- **No live path produces a NaN today.** I went looking: `tapTempo` guards
  `average > 0`, `TempoEstimator` guards `secondsPerBeat > 0` and `spread > 0`, and
  `Transport.beatsPerMinute` guards `> 0` — and all of those reject NaN correctly,
  because `NaN > 0` is false. The trap was one careless divide away from reachable,
  not actively firing. Fixed anyway: it removes the class.
- **`selfqa/out/phase-2/output-stage` still reports FAIL.** It negotiated
  1280×1024@60 instead of 720×480. The startup log shows why — the third display is
  `MACROSILICON` at 1280×1024, which is the capture card. This is a hardware-dependent
  check and I cannot confirm it without your eyes on the chain, so I have not touched
  it.

## Proposals requiring review

Ordered by impact.

1. **Adopt the async AVFoundation API (11 warnings).** `tracks(withMediaType:)`,
   `duration`, `naturalSize`, `nominalFrameRate` are all deprecated since macOS 13.
   The replacements (`loadTracks`, `load(.x)`) are **async**, so adopting them makes
   `AVFClipDecoder.init` async and changes a public signature — explicitly out of
   scope for an autonomous pass. Affects `AVFClipDecoder` (5) and `RecordSelfQA` (6).
2. **Decide what a refused parameter write should do.** `ParamRegistry.setValue` now
   returns `false` for a non-finite value, but it is `@discardableResult` and all 114
   call sites ignore it. If a modulation source ever does produce a NaN, the only
   evidence will be a log line. A counter on the settings bar, or a one-time notice,
   would make it visible.
3. **`lint.sh` should either clean first or say what it cannot see.** Right now it
   reports clean from an incremental build. `scripts/verify/warnings.sh` covers this,
   but only if someone remembers to run it; folding it into `verify.sh` costs ~90 s.

## Security

No findings. Specifically checked: no hardcoded secrets, no network calls beyond the
explicitly-specified IP/stream paths, no shell interpolation of user input, no path
traversal in the config or library file handling, no third-party packages to audit,
and FFmpeg remains LGPL-only (the build fails if `CONFIG_GPL`/`CONFIG_NONFREE` is set).

The one user-supplied-input parser, `config/devices.json`, now has 18 tests covering
malformed, partial, wrongly-typed, empty and oversized input. All degrade rather than
crash.

## Feature set: implemented vs planned vs asked for

You asked for this comparison specifically, and for it to exclude changes you made
yourself.

**Implemented and done** — 25 of 30 BUILD-PLAN items. Phases 0–3 complete and
self-verified: the DV and MPEG bitstream wedge, per-channel FX chains, the musical
clock with latency compensation, the full four-channel mix with layer compositing,
composite/NTSC emulation, feedback, the MX-1 effect set, generators and the transport
LFO, audio reactivity, NTSC scopes, recording, the routing/send panel, and the
canonical 5×5 window shell.

**Partially implemented** — 1 item.

| Feature | State |
|---|---|
| Core Text character generator (§18.1) | Core node done and pixel-tested: fill, outline, shadow, kerning/tracking/leading, alignment, position/anchor, scale, title-safe clamp, roll/crawl clock-synced, period preset, NTSC-legal fill warning. **No UI at all** — not in the graph, no text entry, no font or colour pickers. Marked `[~]`, not `[x]`. |

**Planned, not started** — 4 items: ISF host + FFGL (§8), the emulated titler library
(§18.2, GPL/out-of-process), SVG/PS1 source (§17) and IP in/out (§6/§15), and optional
Syphon output.

**Asked for during this session and delivered:** playlists with per-source up-next
queues and right-click queueing; eject (which did not exist in any form); the focus
rebrand with caret and bus colour across both switch types; window sizing that follows
the display (verified at 1766×970 on your BenQ, up from a hardcoded 1460×912); the
shuttle as a hover overlay with a resting play bar; fill mode reachable from the
output bar; the output bar slimmed to a fixed height; maximise restored without full
screen; library bus colour-coding; camcorder font in caps; zebra removed; the
crossfader's centre readout removed; the decorative IRE/resolution captions removed.

**Asked for and NOT delivered:** nothing outstanding from this session.

## Reviewing and undoing

Review every change made tonight:

```
git log --oneline a4164ff..HEAD
git diff a4164ff..HEAD -- Core/Sources App/Sources
```

Undo everything, restoring the exact pre-session state:

```
git reset --hard refs/tags/v0.7.0-pre-overnight
```

The recovery point also exists as a branch, `recovery/pre-overnight`, in case the tag
is ever moved. Nothing was pushed; `main` was never touched; all work is on `next`.

## Recommended next steps

1. **Finish the character generator's UI.** It is the only half-built thing in the
   repo, and `[~]` is load-bearing — do not read it as usable yet.
2. **Look at the output stage on real hardware.** The one failing self-QA check needs
   the analog chain and your eyes; everything else is green.
3. **Fold `warnings.sh` into the release path**, or accept that warnings accumulate
   invisibly between clean builds. This session found two genuine bugs in warnings
   that had been sitting unseen.
4. **Then pick a backlog item.** ISF host is the largest capability unlock; SVG/PS1 is
   the lowest risk; Syphon is the smallest and most immediately useful.
