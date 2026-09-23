# ISF-PLAN.md — the ISF push

Drafted 2026-09-23 for the push starting 2026-09-24. **Revision 2**, after the owner's
notes: no third-party translator if we can write our own; remove MX-1; the FX panel's
layer chain is where ISF modules live.

Nothing in the app has been coded for this. The one piece of code written was a
throwaway feasibility test in a scratch folder, outside the repo (§2.2). Everything
under "Where we are" was checked against `perf/audit`'s working tree.

**Progress (2026-09-23, branch `feature/isf-converter`, not merged):** the converter
(§2) and `ISFNode` (§3) are built, with the built-in ports for Colour, Transform and
Echo (§4.2). Parity gate passed: 30/30, pixel-identical to native, cost within noise.
That covers M3 and M4 and the port half of M8, minus the corpus pass-rate run, which
still needs an ISF corpus on disk. How it all connects, and the merge steps:
`docs/ISF-SYSTEM.md`. Not started: M1 (MX-1 removal), M2 (`ParamCode`), M5–M7
(chain, library UI, cards), M9.

Governs: BUILD-PLAN Phase 4+ line "ISF host (parser → Metal) + FFGL (SPEC §8)". FFGL
and CI/AU passthrough are **not** part of this push (§9).

---

## 0. The pitch

1. **We write our own ISF → Metal converter, and it's small.** Metal shaders are C++,
   and C++ is close enough to GLSL that an ISF shader body can be pasted almost
   verbatim inside a generated Metal `struct`. The struct holds the uniforms, images
   and helper functions as members. Apple's Metal compiler, which the app already uses
   at startup, then does all the real parsing and type checking. Our code is a
   tokenizer, a short list of token rewrites, and a prelude of GLSL built-ins
   (~800–1200 lines of Swift, pure text in / text out). **This was tested tonight:
   it compiles** (§2.2). No glslang, no SPIRV-Cross, no C++, no GPL question.
2. **The FX panel's layer chain is the home for ISF modules.** Each ISF effect is a
   card in the existing adjustment-layer stack: top card applied last, drag to
   reorder, A / B / BOTH, two-line faders, MIDI / AUD / LFO. Nothing new in the UI
   except a small badge saying where the module came from.
3. **An ISF file becomes a node in the existing render graph**, not a second plugin
   system. The ISF JSON header is the module's manifest (SPEC §1.5 holds).
4. **Compiling never happens on the frame loop.** Conversion and compilation run in
   the background and cache to disk. Until a module is ready it passes its input
   through and its card says "compiling…".
5. **Built-ins become ISF where they're just shaders:** Colour, Transform and Echo
   ship as bundled `.fs` files, loaded by default, with their existing param codes
   (so saved templates and MIDI mappings survive). **MX-1 is removed**, not ported (§4.1).
6. **What isn't a shader stays native but looks identical.** The DV corruptor, bus
   codec, Feedback and (for now) Composite · NTSC each get a descriptor in the same
   shape, so the panel builds every card the same way.

---

## 1. Where we are (verified against the code)

| Fact | Where | Why it matters |
|---|---|---|
| `FeatureFlag.isfHost` already exists, unused | `VideoboyCore.swift` | The flag to ship behind is already there |
| Shaders are one MSL string compiled at startup with `makeLibrary(source:)` | `SelfQA/MetalContext.swift` | Runtime Metal compilation is already the house pattern; our converter emits the same thing |
| Passes submit without waiting; the engine fences once per frame (now a CLAUDE.md invariant) | `MetalContext.swift:933` | Extra ISF nodes cost GPU time, not CPU stalls. ISF nodes must follow the same rule |
| The graph is **frame-clocked**: one render per 29.97 content frame (`Engine.contentFrameDue`), not per display refresh | CLAUDE.md invariants | ISF `TIME`/`TIMEDELTA`/`FRAMEINDEX` and persistent buffers must advance per render, never per refresh, or shaders run at 2× on a 60 Hz screen |
| Chains are hardwired: 6 nodes × 4 channels + 6 per bus, in `Engine.buildGraph` | `Engine.swift:195–330` | The layer chain has to become data |
| **Drag-to-reorder doesn't change the render.** `onReordered` fires but nothing subscribes | `EffectChainPanelBody.swift:174,734` | Live bug. Fixed by M5 |
| "Remove" sets wet/dry to 0; "Add" un-hides the card | `ShellController.swift:1800–1825` | No real add/remove exists yet |
| Card parameters are hand-listed in `PanelSet.chain(for:)`, separate from each node's `parameters` | `PanelSet.swift:240–400` | Two lists kept in step by hand. Descriptors remove the duplicate |
| Faders reach slots through `effectNameToSlot`, `effectNameToChannelSuffix`, `cardOwning(_:)` and 25 hardcoded effect-name strings | `ShellController.swift:1591+` | The biggest removal in the push |
| `ParamCode` is a **closed enum** (183 cases); 11 `allCases`/`rawValue:` call sites | `Control/ParamCode.swift` | ISF inputs are only known at runtime. It has to open up first |
| Templates store values as `[String: Double]` by code and keep unknown codes on load | `TemplateDocument.swift:29,194` | Serialisation is nearly ready. Old MX-1 values load harmlessly |
| The render tick is `NSView.displayLink` → main thread | `Engine.swift:552` | Graph edits between ticks on main are safe. **Compiles must not be on main** |
| Composite runs 1–6 passes chosen at runtime (generation loss) | `CompositeCodecNode.swift:111` | ISF has fixed pass counts, so it stays native for now |
| Feedback keeps a ring of N frames, reports `latencyInFrames`, takes an external captured frame | `FeedbackNode.swift` | Not expressible in ISF; stays native |
| MX-1 is referenced in 15 source/test files (122 lines); codes `91A`, `92A` | grep | Removal is its own small milestone (M1) |
| Stress check (live window, 4 decodes, everything on): worst tick 27.9 ms, p95 10.3 ms, 0 dropped | `selfqa/out/perf/stress/result.txt` | Live headroom |
| **`ui-layout` in the working tree FAILS its frame-time check: worst 118 ms** (last commit: 12.9 ms). Also failing: rate-key placement, library search | `selfqa/out/phase-2/ui-layout/result.txt` | CLAUDE.md now says never to time a debug build (roughly 10× slower on the frame path), so this may be a debug-build run. **Unverified.** Either way it must be explained, and `ui` + `stress` green on a release build, before the push starts (M0) |
| No `~/Library/Graphics/ISF` on this machine | — | We need a set of ISF files to test the converter against (§8) |

---

## 2. The converter — our own, no translator

### 2.1 The idea

GLSL (what ISF shaders are written in) and MSL (Metal) are both C-family languages
with near-identical vector maths: `mix`, `clamp`, `smoothstep`, `fract`, `dot`,
swizzles and so on. The real obstacles are few and specific:

| GLSL has… | Metal has… | How we bridge it |
|---|---|---|
| global uniforms, textures and mutable globals visible everywhere | no mutable globals; resources only as function arguments | **wrap the whole shader in a `struct`**: uniforms, textures, sampler and globals become members, the user's functions become member functions. Everything is in scope with **no identifier rewriting** |
| `vec2 / vec3 / mat2 / ivec…` | `float2 / float3 / float2x2 / int2…` | `typedef`s in the prelude |
| `mod`, `atan(y,x)`, `texture2D`, `lessThan`, `inversesqrt`… | `fmod` (different sign rule), `atan2`, `.sample()`, … | overloaded member functions in the prelude, with GLSL's exact semantics (e.g. `mod(x,y) = x − y·floor(x/y)`) |
| ISF's `IMG_PIXEL`, `IMG_NORM_PIXEL`, `IMG_THIS_PIXEL`, `IMG_SIZE`, `isf_FragNormCoord`, `gl_FragColor`, `gl_FragCoord` | — | prelude members, filled in by the generated entry point. `gl_FragCoord.y` is flipped (GL is bottom-up, Metal top-down) |
| `out T x` / `inout T x` parameters | `thread T& x` | token rewrite |
| `lowp/mediump/highp`, `#version`, `precision …;` | — | stripped |
| `discard` | `discard_fragment()` | `#define` |
| forward declarations `float f(float);` | redeclaring a member is an error | token pass drops them (member functions can be called before their definition inside a struct, so they aren't needed) |
| identifiers that are Metal keywords (`constant`, `device`, `thread`, `kernel`, `vertex`, `fragment`, `sampler`, `texture`) | reserved | token pass renames them (`constant` → `constant_`) |
| array constructors `float[3](…)` | C++ brace init | token rewrite |

Everything else passes through untouched, and **Metal's compiler does the parsing
and type checking**. When it rejects something, the error's line number maps back
to the `.fs` file through a line table the generator keeps, and the card shows
`⚠ line 14: …` in terms of the user's own file.

### 2.2 Feasibility test (done tonight, throwaway, not in the repo)

A 60-line test in the session scratch folder compiled, through the same
`MTLDevice.makeLibrary(source:)` call the app uses, a GLSL-style ISF body wrapped as
above. It used bare `TIME` and `amount` uniforms, a mutable global, a `const` global,
an `inout` parameter rewritten to `thread vec2&`, a two-argument `atan`, GLSL `mod`
and `IMG_NORM_PIXEL`. **Result: `COMPILED OK`.** One lesson learned: the `mod`
helpers must be explicit per-type overloads, not templates (templates were
ambiguous). What it doesn't prove yet: pixel-correct output, cost versus a native
shader, and pass rate across real-world files. Those are the M3 gates.

### 2.3 Honest limits

- **Pass rate on third-party files won't be 100%.** Sloppy GLSL that desktop OpenGL
  drivers forgive (e.g. vector `==` used as a bool in an `if`) will fail Metal's
  stricter checks. Those files show as greyed cards with the error line, never a
  crash. **Target: ≥ 85% of the Vidvox ISF-Files set compiles; ≥ 95% of those that
  compile render correctly on a spot check.** Each failure pattern we see often
  becomes one more prelude function or token rule.
- **ISF vertex shaders (`.vs`)** are rare. They ship greyed in this push unless the
  corpus says they're common.
- If the pass rate after M3's timebox is badly short (under ~70%), that's the moment
  to reconsider a real translator (§2.4). I don't expect it, but it's written down so
  it's a decision rather than a drift.

### 2.4 Alternatives, if we ever need one

| Option | What it is | Cost | Verdict |
|---|---|---|---|
| **A. Our own (above)** | struct-wrap + prelude + token rewrites; Metal compiles it | ~1k lines Swift; no deps | **Recommended** |
| B. glslang + SPIRV-Cross | Khronos's full GLSL compiler to SPIR-V, then SPIRV-Cross to MSL | vendored C++ xcframework; glslang's parser file is GPL-3 + Bison exception (needs your OK) | Highest compatibility; the heaviest dependency. Fallback only |
| C. ISFMSLKit (Vidvox) | option B pre-packaged by the ISF authors, BSD | Xcode frameworks + PINCache; not SwiftPM (breaks our deps rule) | Useful as a *reference* for ISF semantics, not a dependency |
| D. Our own Metal-bodied format | ISF JSON header + Metal body, no GLSL at all | zero conversion | Loses the whole third-party ISF library, which is the point of ISF. Could still suit a future native-only module |
| E. Run GLSL in OpenGL, share frames with Metal via IOSurface | macOS's deprecated GL stack | two GPU APIs; deprecated | No |

---

## 3. Architecture

### 3.1 The shape

```
                        BACKGROUND QUEUE (never the tick)
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ ISFLibrary scan ─▶ ISFDocument (JSON header + GLSL body, parsed)         │
  │                      │                                                   │
  │                      ▼                                                   │
  │               ISFMetalGenerator (ours: tokenizer, token rules, struct    │
  │                      │          wrap, prelude, entry point, line table)  │
  │                      ▼                                                   │
  │               MSL text ──(disk cache)──▶ MTLLibrary + pipeline per pass   │
  │                                           (async Metal APIs)             │
  └──────────────────────┬───────────────────────────────────────────────────┘
                         │ compiled program, handed over on main
                         ▼
  MAIN / TICK:   ISFNode : Node ── render(inputs:context:) ── one pass per PASSES entry
```

- **`ISFDocument`** (Core, pure Swift): parses the header, inputs, passes, imported
  images and categories. Classifies the file as effect (has `inputImage`), generator
  (no image input) or transition (`startImage` + `endImage` + `progress`).
- **`ISFMetalGenerator`** (Core, pure Swift): §2. Text in, text out, fully
  unit-testable. The prelude is one `.metal` string, kept beside it.
- **`ISFProgram`**: compiled pipelines + uniform layout. Immutable, and shared by every
  instance of the same file, so the three copies of a card compile once.
- **`ISFNode : Node`**: owns its render targets, persistent buffers and uniform
  scratch. No Metal objects are created per frame.

### 3.2 Threading and compile rules (smooth playback outranks everything)

- Scan, parse, generate and compile run on one serial background queue, using the
  **async** `makeLibrary(source:options:completionHandler:)` and
  `makeRenderPipelineState(descriptor:completionHandler:)`.
- The compiled program is handed to the node on main, between ticks. Until then the
  node returns its input and the card shows "compiling…".
- Built-ins are prewarmed at launch, before the first programme frame.
- Cache: `~/Library/Caches/Videoboy/ISF/<sha256(file + generator version)>.metal`.
  A cache miss isn't an error.
- Hot reload: an FSEvents watch on the ISF folders. The new program replaces the old
  only after it compiles, so saving a broken file never blacks out a live chain.

### 3.3 Rendering an ISF node

- **Uniforms:** we generate both the entry point and the uniform struct, so the
  layout is ours and needs no reflection. It's written into a reused buffer and bound
  with `setFragmentBytes` (under 4 KB, no allocation).
- **Auto uniforms:** `TIME`, `TIMEDELTA`, `FRAMEINDEX`, `RENDERSIZE`, `PASSINDEX`,
  `DATE`. They advance **per render** (the graph is frame-clocked at 29.97), so a
  shader's speed doesn't depend on the display's refresh rate. **Videoboy extension:** `VB_BEAT`, `VB_PHASE` from `musicalPosition`, so a
  shader can lock to the musical clock. VDMX's host has nothing like it.
- **Passes:** one render pass per `PASSES` entry, sized at project resolution or by the
  pass's `WIDTH`/`HEIGHT` expression. `PERSISTENT` targets survive across frames;
  `FLOAT` targets use `rgba16Float`.
- **Bypass is the host's job:** universal `02A` wet/dry on every ISF node; returns
  its input untouched at 0, the same as every native node. Partial mix reuses
  `metal.blend`.
- **Neutral-skip:** the optional header key `"VIDEOBOY": {"IDENTITY_AT_DEFAULTS": true}`
  means "when every input is at its DEFAULT, return the input". Built-in ports set it,
  which preserves "Colour is on by default and costs nothing".
- **Per-node GPU time** from `gpuStartTime`/`gpuEndTime` goes to the debug overlay
  and the stress check (§6).

### 3.4 Parameter codes (SPEC §13) for runtime inputs

`ParamCode` changes from a closed enum to an open `struct ParamCode: RawRepresentable,
Hashable, Codable`, with the existing values as `static let`s. Use sites like `.wetDry`
don't change. A code for an ISF input comes from, in order:

1. **Declared:** `"VIDEOBOY_CODE": "51A"` on the input. Other ISF hosts ignore unknown
   keys, so the file stays valid ISF. **This is how ported built-ins keep their codes**,
   and with them every saved template and mapping.
2. **Otherwise:** `x:<INPUT NAME>`, e.g. `x:amount`. It's stable while the input keeps
   its name, and swapping one ISF for another that also has `amount` keeps the
   mapping (SPEC §13's intent).
3. The card shows `amount·51A` for declared codes and `amount·x` for generated ones.

The slot stays the address; the code is the label within it, as today.

---

## 4. The FX panel is the housing

Yes: the adjustment-layer chain is where ISF modules live. It already has the right
shape (ordered layers, top applied last, per-card enable, A / B / BOTH, mappable
two-line faders). What changes is underneath it:

- **`EffectChain`** (Core): an ordered `[ModuleInstance]` per sub-mix, holding module
  ID, instance ID, enabled flag and values. It's pure data, unit-tested, and it's what
  the template saves.
- **One card = three nodes** (channel A copy, channel B copy, bus copy), exactly as
  A / B / BOTH works today. All three early-return while bypassed, so an idle card
  costs nothing.
- **`Engine.rebuildChain(bus:)`** rewires the graph from the model: head ← channel
  source, tail → sub-mix. It replaces the hand-wired block in `buildGraph` and the
  "heal the tail edge" code in `setChannelSource`. It runs on main between ticks.
  Reordering a card rewires for real, which fixes today's cosmetic-only drag.
- **Every card comes from a descriptor.** ISF cards from the `.fs` header; native
  cards (Composite, Feedback, DV corruptor) from a JSON sidecar in the same shape.
  `PanelSet`'s hand-written lists and `ShellController`'s name tables are deleted.
- **Fixed stages stay fixed** and aren't layers: the DV corruptor runs on bytes before
  decode; the bus codec, programme composite and scope overlay sit after the mix.
- **Default chain on a fresh launch** = today's cards minus MX-1, same order, same
  defaults: Transform, Colour, Composite · NTSC, Echo / Trails, Feedback.
- **Templates:** version bump. An old template with no `chain` loads as the default
  chain with its values applied by code. Old `91A`/`92A` (MX-1) values are kept and
  ignored, as the loader already does for unknown codes.

### 4.1 Removing MX-1 (owner decision, 2026-09-23)

MX-1 is removed, not ported. Scope (15 files, 122 lines): `MX1EffectNode.swift`, the
`mx1_fragment` shader and `mx1Pipeline`, `mx1One`/`mx1Two` and the per-channel copies
in `Engine`, its card in `PanelSet`, the `ShellController` routing entries, the
`NormalisedSweep`/`TextureUploader`/`CompositeCodecNode` mentions, three Core tests,
three self-QA references, and the docs (SPEC §8/§9 list the MX-1 set as required; this
revision overrides that and SPEC gets a dated owner note). Codes `91A` and `92A` are
**retired, never reused** (ParamCode rule).

**One question before deleting:** MX-1 contains **Freeze** (hold the current frame).
Negative, mono, mosaic, posterize and mirror are trivial and can come back as ISF
files if anyone ever misses them, but Freeze is a live-performance gesture. Kill it
with the rest, or keep it as its own small native card? (D3)

### 4.2 Which built-ins become ISF

| Effect | Target | How | Risk |
|---|---|---|---|
| Colour | `Builtin/Colour.fs` | 1 pass, 8 floats, `IDENTITY_AT_DEFAULTS`, codes 51A–58A | Low |
| Transform | `Builtin/Transform.fs` | 1 pass, codes 11A–16A | Low |
| Echo / Trails | `Builtin/Echo.fs` | 2 passes, one `PERSISTENT` history target | Medium: must keep "bypass preserves history" |
| Composite · NTSC | **native** + descriptor | runtime pass count (generation 1–6) | ISF port later via a `VIDEOBOY.REPEAT_PASS` host extension (backlog) |
| Feedback | **native** + descriptor | N-frame ring, external capture, declared latency | — |
| DV corruptor, bus codec | **native forever** | they run on bytes; this is the product | — |
| MX-1 | **removed** (§4.1) | — | — |

**Gates on each port.** The native version stays until all three pass; then it's
deleted in the same commit (no two implementations kept in step):
1. **Pixel parity:** native vs ISF on the offscreen renderer, 3 fixtures × 5 settings.
   Mean abs diff ≤ 0.5/255, max ≤ 2/255. Evidence in `selfqa/out/isf/parity/`.
2. **Cost:** ISF worst-frame GPU time ≤ native + 10%. This is also what proves the
   struct-wrap costs nothing once Metal's optimiser inlines it.
3. **Compatibility:** a template saved before the port loads and renders identically
   after it, with mappings intact.

---

## 5. The interface

### 5.1 Where modules appear

| ISF kind | Shows in | Used by |
|---|---|---|
| **Effect** | FX panel **+ Add** menu, and the Asset Browser's effects tab | adding a card to the layer chain (menu, or drag from the browser onto an FX panel) |
| **Generator** | Asset Browser **Generators** tab, beside the built-in generators | dragging onto a source panel, as generators work today |
| **Transition** | — | next push (touches the crossfader, which is on the tick) |

The Add menu is grouped: **Built-in**, then the ISF `CATEGORIES`, then **Failed to
load (n)** at the bottom, disabled, with the reason as a tooltip.

### 5.2 Card anatomy — unchanged from SPEC §14.2

```
 ≡  Colour                      [built-in]   ⏻  ✕
    A │ B │ BOTH
    MIDI AUD LFO   bright·51A                     0.50
    ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬●▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬

 ≡  Bad TV                      [ISF]        ⏻  ✕
    MIDI AUD LFO   noise·x                        0.12
    ▬▬▬▬▬●▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬

 ≡  Kaleido.fs                  [error]          ✕
    ⚠ line 14: no matching function for call to 'IMG_PIXEL'
```

### 5.3 ISF input type → control

| ISF `TYPE` | Control | Code(s) | Notes |
|---|---|---|---|
| `float` | `VBFader` with the header's MIN/MAX/DEFAULT | 1 | the 90% case |
| `bool` | `NSSwitch` | 1 | on above 0.5 |
| `long` (VALUES/LABELS) | `NSPopUpButton` | 1 | MIDI sweeps across the list |
| `event` | momentary button | 1 | edge-triggered like CUT |
| `color` | swatch + collapsible R G B A faders | 4 | each mappable |
| `point2D` | X and Y faders (a drag-pad later; `TitlerPlacementPad` is the precedent) | 2 | |
| `image` (extra) | popup A / B / C / D / ONE / TWO / none | 0 | **ships greyed** this push |
| `audio` / `audioFFT` | bound to `AudioReactivityBus` | 0 | **ships greyed** this push |

Every row registers with `ParamRegistry`, so Shift-detect, MIDI learn, LFO, AUD, beat
sweeps and templates work with no per-module code.

### 5.4 Decisions for you (my recommendation in bold)

| # | Question | Recommend |
|---|---|---|
| ~~D1/D2~~ | ~~Translator choice and glslang licence~~ | **Settled: our own converter (§2).** No licence question remains |
| **D3** | Freeze: remove with MX-1, or keep as its own small native card? | **Keep Freeze** as a one-switch native card. It's a performance gesture, not a look |
| **D4** | Composite · NTSC and Feedback stay native this push? | **Yes** (§4.2) |
| **D5** | The Asset Browser tab SPEC calls "VSTs" | **Rename to "Effects"**. It holds ISF and built-ins, not VSTs |
| **D6** | An expensive third-party ISF | **Warn only**: amber "heavy" badge with measured ms. Auto-bypassing mid-show is a worse surprise |
| **D7** | Default chain | **Today's cards minus MX-1**, same order and defaults |
| **D8** | ISF generators in this push? | **Yes (small, M9)**; transitions next push |

---

## 6. Performance plan

- **Baseline first (M0):** `selfqa.sh stress` (the load test of record) on a **release** build, recorded on a green tree.
- **Budget for this push:** with the default chain, the stress check's worst tick rises
  by no more than 2 ms. With 4 extra ISF cards per bus, all on: still 29.97 fps,
  0 dropped, worst tick under 25 ms (budget 33.4 ms). Today's worst is ~19–25 ms,
  driven by a main-thread decode spike (AUDIT-2026-09-23 P5), so ISF has to be
  measured on the GPU per node as well, not only as whole-tick worst.
- **New stress assertion:** loading and compiling 20 ISF files mid-run causes no tick
  over budget. This proves §3.2.
- **Per-node GPU ms** in the debug overlay; this drives the D6 badge.
- **No new CPU waits.** ISF nodes use `metal.submit` like everything else.

---

## 7. Execution plan

Each milestone ends in a buildable commit on `feature/isf` (branched from a green
`perf/audit`), with `scripts/verify.sh` exit 0 and the listed evidence saved. ISF work
stays behind `FeatureFlag.isfHost` until M8.

| M | Deliverable | Acceptance (self-verified) | Size |
|---|---|---|---|
| **M0** Pre-flight | `perf/audit` green + merged; D3–D8 answered; ISF test set on disk | release build: `ui-layout` 115/115, `stress` PASS; baseline written here | S (the 118 ms FAIL is an unknown; could be M) |
| **M1** Remove MX-1 | §4.1; Freeze kept or removed per D3; codes retired; SPEC owner note | tests green; `audit` 0 enabled-but-unwired; stress worst tick not worse | S |
| **M2** Open `ParamCode` | enum → struct, no behaviour change | all tests green; template round-trip unchanged | S |
| **M3** Parser + converter | `ISFDocument`, `ISFMetalGenerator`, prelude, line table, pass-size expressions | 40+ unit tests over hand-written fixtures (every input type, multipass, persistent, v1 header, bad JSON, each token rule), **each asserting the output compiles** with `makeLibrary`; **corpus run: pass rate recorded; ≥ 85% target** | **M, the core of the push.** Timebox 1 session for the corpus-driven fix loop |
| **M4** `ISFNode` | passes, uniforms, auto-uniforms + `VB_BEAT`, persistent targets, wet/dry, identity-skip, async compile, disk cache | offscreen PNGs: an identity shader equals its input exactly; known-output shaders; persistent accumulates; **zero** ticks over budget while compiling 20 files | M |
| **M5** Layer chain as data | Core `EffectChain`; `Engine.rebuildChain`; reorder **really rewires**; template `chain` key + old-template migration | model unit tests; offscreen check that reorder changes output (Transform→Echo ≠ Echo→Transform); pre-push templates open identically | M |
| **M6** `ISFLibrary` | folder scan, categories, FSEvents hot reload, failures kept with reason | good / bad / duplicate files sorted correctly; saving a broken file keeps the old program live | S |
| **M7** Data-driven cards | cards from descriptors; per-type controls (§5.3); grouped Add menu; badges; browser tab; drag browser → FX panel. **Delete** `PanelSet.chain(for:)` lists, `effectNameToSlot`, `effectNameToChannelSuffix`, `cardOwning` | `ui-layout` all pass; `audit` 0 unwired; Shift lights every ISF fader; a virtual-MIDI test maps an `x:` code and moves the output | L |
| **M8** Port built-ins | Colour, Transform, Echo as `.fs`; default chain; natives deleted after gates; flag on by default | §4.2 gates; evidence in `selfqa/out/isf/parity/`; stress with every card on ≤ baseline + 2 ms | M |
| **M9** ISF generators | no-input ISF → Generators tab → assignable to A/B/C/D | offscreen PNG of an ISF generator on channel A reaching PROGRAM | S |
| **M10** Close-out | ADD-A-MODULE: "add an ISF module" (drop a file, done) + "port a native effect"; ARCHITECTURE; STATUS; BUILD-PLAN; SPEC §8/§9/§14.2 notes | `verify.sh` 0; `selfqa.sh all`; stress PASS | S |

**Order:** M0 → M1 → M2 → M3 → M4 → (M5 ∥ M6) → M7 → M8 → M9 → M10. M1 and M2 are
small and mechanical. Doing them first means the chain refactor never has to carry
MX-1 along.

**Realistic pace:** M0–M4 is day one. By its end we know the converter's real pass
rate, the one number that could change the plan. M5–M7 is the risky refactor that
rips out the name tables, and will likely spill into day two. M8 is quick once M7
lands.

**Where I stop for you:**
- after M0, only if the 118 ms regression turns out to be a design problem, not a bug;
- after M3, only if the corpus pass rate is under ~70% (§2.3);
- after M7: running app, a real third-party ISF on both buses, reorder, map, save,
  reload. That's the clickable milestone for this push.

**qwen delegation** (per CLAUDE.md, verified before use): M3 fixture `.fs` files,
doc-comment passes, commit messages, grouping corpus compile errors by pattern. Not
the generator's rules, the chain refactor, or the build graph.

---

## 8. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Real-world ISF is sloppy GLSL that Metal rejects | High, for a minority of files | Each common failure pattern becomes a prelude function or token rule; the rest show greyed with the error line; §2.3 sets the "reconsider" threshold |
| The struct-wrap costs GPU time vs a hand-written shader | Low | M8's cost gate measures it directly on three real effects |
| Line-number mapping drifts, so errors point at the wrong line | Medium | The line table is unit-tested with a deliberately broken fixture per token rule |
| The chain refactor (M5–M7) breaks mappings or A / B / BOTH | Medium | Template-compat test before any deletion; `audit` must stay at 0 unwired; deletions come last within M7 |
| An expensive user ISF drops frames live | Medium | D6 badge + measured ms |
| Parity misses by small amounts (precision, sampler) | Medium | Match sampler and precision in the generator; tolerances are fixed in §4.2, not tuned afterwards |

---

## 9. What I need from you

1. **D3–D8** (§5.4). Only **D3 (Freeze)** blocks anything, and only M1.
2. **A set of ISF files on disk** for the converter's test run. Easiest: install VDMX
   or the ISF Editor, which fill `~/Library/Graphics/ISF/`, or clone
   `github.com/Vidvox/ISF-Files` there. (CLAUDE.md limits build-time network to
   package registries, so I shouldn't fetch it.)
3. Five minutes with the app after M7.

---

## 10. Out of scope for this push

FFGL host · Core Image / AU passthrough · transitions (next push) · extra `image` and
`audio`/`audioFFT` inputs (ship greyed) · ISF vertex shaders unless the corpus says
otherwise · an in-app shader editor · Shadertoy import · porting Composite/Feedback to
ISF · `MTLBinaryArchive` precompilation. Backlog entries go into BUILD-PLAN when this lands.
