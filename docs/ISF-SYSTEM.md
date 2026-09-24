# ISF-SYSTEM.md — how ISF modules plug into Videoboy

ISF (Interactive Shader Format) is the effect format VDMX and friends use: a GLSL
fragment shader with a JSON header describing its controls. Videoboy runs ISF files
**without a third-party translator**. Metal is C++, so a GLSL shader body wrapped
inside a generated Metal `struct` compiles almost unchanged, and Apple's own Metal
compiler does the real work. This page explains how that system fits the rest of the
app. The plan for finishing it is `docs/ISF-PLAN.md`.

Status (branch `feature/isf-converter`): the converter, the node, the library and
the three built-in modules are built and tested. **Nothing in the running app uses
them yet.** Wiring them in is the merge step below.

---

## The one-paragraph version

An ISF file becomes an **`ISFNode`**, an ordinary `Node` on the render graph (the
one extension point, SPEC §1.5). It sits in an FX chain exactly where a native
effect sits. Its controls are addressed by the same **param codes** (SPEC §13) the
native effects use, so MIDI learn, LFO / AUD modulation, beat sweeps and saved
templates reach it with no extra code. Compiling happens on a background queue,
never on the render tick. Until a module is ready it passes its picture through
unchanged.

## The picture

```
 .fs files on disk                                                    (ISFLibrary)
   App bundle: Contents/Resources/ISF/Builtin   ← built-ins: Colour, Transform, Echo
   ~/Library/Application Support/Videoboy/ISF   ← the operator's own imports
   ~/Library/Graphics/ISF                       ← shared with VDMX and other hosts
        │ scan: parse headers only, keep failures with reasons
        ▼
 ISFDocument ─── inputs, passes, categories, kind (effect / generator / transition)
        │
        ▼                          BACKGROUND QUEUE (ISFCompiler), never the tick
 ISFMetalGenerator ── GLSLTokenizer + small token rules + ISFMetalPrelude
        │              → Metal source + uniform layout + line table
        ▼
 MTLDevice.makeLibrary(source:)  ── same call MetalContext uses at startup
        │
        ▼
 ISFProgram (pipelines, shared by every node running that file)
        │ handed over on the main thread, between ticks
        ▼
 ISFNode : Node ───────────────────────────────────────────────────────────────┐
   render(inputs:context:)  — one pass per PASSES entry, persistent buffers,   │
                              wet/dry via MetalContext.blend, no per-frame     │
                              allocation, submits without waiting              │
   parameters / applyParameters(from:)  — VIDEOBOY_CODE → ParamCode            │
                                                                               │
 RenderGraph: source ─▶ [FX chain: … ISFNode …] ─▶ sub-mix ─▶ PROGRAM ◀───────┘
 ParamRegistry: slot = node identifier, code = the file's VIDEOBOY_CODE
```

## The pieces

All in `Core/Sources/VideoboyCore/Modules/Effects/ISF/`. They're pure Swift plus Metal,
build headlessly, and are covered by `swift test`.

| File | Job |
|---|---|
| `ISFDocument.swift` | Parse one `.fs`: JSON header → inputs, passes, categories; classify effect / generator / transition. Also reads the Videoboy extensions `VIDEOBOY_CODE` and `VIDEOBOY.IDENTITY_AT_DEFAULTS`. |
| `GLSLTokenizer.swift` | Split GLSL into tokens that join back **byte for byte**. It's not a parser. |
| `ISFMetalPrelude.swift` | The GLSL vocabulary in Metal: `vec2` typedefs, GLSL `mod`, two-argument `atan`, `IMG_NORM_PIXEL`, `texture2D`, … and the one place the y-flip lives. |
| `ISFMetalGenerator.swift` | Build the Metal source: struct-wrap the body, apply the small token rules, lay out uniforms, map compiler errors back to the author's line numbers. |
| `ISFProgram.swift` | Compile to pipelines (`ISFProgram`); `ISFCompiler` does it off the main thread with a cache. |
| `ISFNode.swift` | The graph node: passes, persistent / float buffers, uniforms, bypass, identity-skip, timing. |
| `ISFSizeExpression.swift` | `"$WIDTH/4"`-style pass sizes, parsed once and evaluated per frame. |
| `ISFLibrary.swift` | Find and parse files in the three folders; `ISFNode.builtin(_:identifier:)`. |
| `ISFImporter.swift` | **Import = copy** into `~/Library/Application Support/Videoboy/ISF`, with the `.vs` partner and any `IMPORTED` images, so a module survives its original being moved or deleted. Refuses non-ISF files with a reason; renames on a clash (`Glow 2`), never overwrites; − moves to the Trash. |

The built-in modules are `App/Resources/ISF/Builtin/{Colour,Transform,Echo}.fs`.
`scripts/build.sh` copies them into the app bundle.

## How it connects to each part of Videoboy

| Videoboy part | Connection |
|---|---|
| **Render graph** (`Graph/Node.swift`) | `ISFNode` conforms to `Node`. No graph changes needed. `kind` follows the file: effect → `.effect`, generator → `.source`, transition → `.mix`. |
| **Param codes / registry** (SPEC §13) | An input with `"VIDEOBOY_CODE": "53A"` appears in `parameters` under that code. `applyParameters(from:)` pulls it, exactly like the native nodes. Inputs without a code are settable by name (`setValue(_:forInput:)`) until `ParamCode` opens to runtime codes (ISF-PLAN M2). |
| **Templates** (SPEC §16) | Nothing new: templates store values by slot + code, and the ports keep the native codes, so a template saved before the swap loads into the ISF node unchanged. The parity test proves this by driving both through the same registry values. |
| **MIDI / LFO / AUD / sweeps** | Same as templates: they target codes in slots. |
| **MetalContext** | Shares the device, queue, `makeRenderTarget`, `makeTexture` and `blend` (wet/dry). The graph's pixel format is BGRA8; `FLOAT` passes use RGBA16F internally. |
| **Clocks** (SPEC §4) | `TIME` / `TIMEDELTA` / `FRAMEINDEX` advance **per render**. The graph is frame-clocked at 29.97, so shaders don't speed up on a 60 Hz screen. Videoboy extensions `VB_BEAT` / `VB_PHASE` expose the musical clock to shaders. |
| **Smooth playback** (CLAUDE.md) | Compiles never run on the tick. Bypassed or neutral nodes return their input with no pass. No per-frame allocation. Passes submit without waiting. |
| **Logging** | Subsystem `[isf]`. Compile failures log the translated first error. |
| **Self-QA** | `selfqa/out/isf/parity/`: native vs ISF, 27 picture comparisons plus cost. |
| **Preferences → Shaders** | `ISFModuleListView`: every module in the three folders with a built-in / imported / shared badge; the selected one's inputs, credit and **whether it compiles**; **+** (files or folders), **−** (imports only; built-ins and the shared folder cannot be removed), drop onto the list, *Copy into Videoboy* for a shared module, *Show Folder*. Scanning, importing and compiling run off the main thread. |
| **FX panel / Asset Browser** | **Not wired yet** (ISF-PLAN M5–M7). `ISFLibrary.scan()` is what the Add menu and browser will list. `ISFNode.state` (`.compiling` / `.ready` / `.failed(reason)`) is what a card shows. |

## What is proven (evidence)

- **Converter:** 20 fixtures, one per rule or prelude function, each must **compile**
  in Metal, not just look right. A deliberate error is reported as `line 7:11: …`
  against the author's file.
- **Node:** identity is bit-exact; "up" in a shader is up on screen; pass-through while
  compiling or failed; bypass is free and keeps persistent buffers; multi-pass with
  smaller buffers; FLOAT accumulation; generators; TIME/FRAMEINDEX; codes reach the
  registry; hot reload keeps values.
- **Built-ins vs native** (`selfqa/out/isf/parity/result.txt`, 30/30): Colour
  (6 settings incl. half wet), Transform (5 incl. flips and offsets), Echo (2 × 8-frame
  moving sequences). Every comparison shows **mean difference 0.000**; the worst single
  channel anywhere is 1/255. Cost at 720×480, best of three: Colour −0%, Transform −6%,
  Echo −2% relative to native.

- **Shaders pane** (`scripts/selfqa.sh shaders`, `selfqa/out/isf/shaders-pane/`): in the
  real Preferences window with real clicks, against temporary folders. Import copies;
  with the originals deleted the modules are all still listed; a non-ISF file is refused
  with an alert; an import is compiled and shown ready; − removes an import and is
  disabled on built-ins; Copy keeps a shared module; the window keeps its size.
  The owner's 7 VDMX shaders (imported as copies): **6 of 7 compile**; *Broken
  Tesseract* fails on `mat4 *= mat4` (no Metal overload in the prelude yet), and that
  error is reported against the generated line, not the file's.

## Spec coverage (2026-09-24)

Measured with `VIDEOBOY_ISF_TRIAL=/folder scripts/test.sh --filter ISFFolderTrial`,
which scans a folder the way the app does, compiles every file, renders twelve frames
at 720×480 and times them (`selfqa/out/isf/trial/`).

- **Vidvox ISF-Files** (the official corpus, 327 files, MIT): **every file compiles**;
  315 draw a non-flat picture in their first second. The other 12 are plain by design
  (Solid Color, Show Alpha), wait on their inputs (a moving picture, a second image,
  sound), or — Random Shape — divide `isf_FragNormCoord` by `RENDERSIZE` in the shader
  itself. Started at 250.
- **Ethereios pack** (41 isf.video exports): 39. The last two render dark in their
  first second.

Supported, each with a pixel test (`ISFCompatibilityTests`, `ISFVertexShaderTests`,
`ISFAudioTests`, `ISFTransitionTests`):

- Every INPUT type: event, bool, long (VALUES/LABELS), float, point2D, color, image,
  audio, audioFFT. A point2D with no MIN/MAX is a frame position, sent in pixels.
- Custom vertex shaders (`.vs`), varyings (arrays and matrices too), drawn as the quad
  ISF hosts draw. A `.vs` that only calls `isf_vertShaderInit()` is ignored.
- PASSES, PERSISTENT and FLOAT buffers, WIDTH/HEIGHT expressions; a last pass into a
  named buffer comes out in the graph's format.
- IMPORTED images and cube maps, found by PATH or by the input's name.
- audio / audioFFT from the live capture (the audio clock's, or started on demand).
- Transitions, in every crossfader's transition key.
- ISF v1: PERSISTENT_BUFFERS, `vv_` names, `_name_imgRect/_imgSize/_flip`.
- GLSL as packs write it: inout swizzles, mixed matrix constructors, scalar
  `distance`/`length`, `sampler2D` parameters, shadowing initializers, C++ words as
  names, both-dialect files (`__VERSION__` is 120).

## Known limits (visible, not silent)

- Extra `image` inputs beyond the first are bound to black until the FX card gets a
  source picker (ISF-PLAN §5.3).
- A host-supplied `cube` INPUT (not IMPORTED) has nothing to feed it.
- The controls of an ISF transition (other than progress) have no faders yet; they are
  registered, so they can be MIDI-mapped.
- Audio is mono: `audio` and `audioFFT` images are one row.

---

## Merging (waiting for the owner's go-ahead)

The branch **only adds files**. The exceptions are one enum case in
`Logging.swift` (`case isf`) and one copy step in `scripts/build.sh`. Neither file
has uncommitted edits in `perf/audit`, `feature/transitions` or
`feature/beat-detection` as of 2026-09-23.

**Step 1 — merge the branch.**
1. In the `perf/audit` worktree, delete the untracked `docs/ISF-PLAN.md`. It's the
   same plan, and this branch now tracks it. Git refuses a merge that would overwrite
   an untracked file.
2. `git merge feature/isf-converter`
3. `scripts/verify.sh`, then `scripts/test.sh --filter "ISF|GLSL"`.

Nothing visible changes after step 1: no engine code uses the new types yet.

**Step 2 — swap the native Colour, Transform and Echo for their ISF ports** (a
separate commit, after `perf/audit`'s own work is committed, because it touches
`Engine.swift`):

```swift
// Engine.buildGraph — per channel and per bus; same identifiers as today.
let colour = ISFNode.builtin("Colour", identifier: Engine.channelSlot(letter, "colour"), context: metal)
let transform = ISFNode.builtin("Transform", identifier: Engine.channelSlot(letter, "transform"), context: metal)
let echo = ISFNode.builtin("Echo", identifier: Engine.channelSlot(letter, "echo"), context: metal)
// …and the bus copies: Engine.colourSlot / colourTwoSlot, transformSlot / transformTwoSlot,
// echoSlot / echoTwoSlot.

// Engine.applyParameters — add one case to the per-channel switch:
case let n as ISFNode: n.applyParameters(from: registry)
// and change the typed bus properties (colour, colourTwo, transformOne, transformTwo,
// echo, echoTwo) from their native types to ISFNode.
```

Slot identifiers and param codes don't change, so **`ShellController` needs no
edits**. Its tables address slots and codes, never node types. Every built-in boots
at its neutral / bypassed defaults, so the moment between launch and compile finishing
looks identical to today.

Checks after step 2: `scripts/verify.sh`, `scripts/selfqa.sh ui`, and
`scripts/selfqa.sh stress` (the load test of record) on a **release** build. The stress
worst tick must not rise by more than 2 ms (ISF-PLAN §6). Once that holds, delete
`ColourControlNode`, `TransformNode`, `EchoNode` and their MSL blocks in
`MetalContext` in the same commit (ISF-PLAN §4.2: no two implementations kept in step).
Also retire `ISFBuiltinParityTests`' native half at that point; it will have nothing to
compare against.

**Not part of this merge:** MX-1 removal (ISF-PLAN M1), opening `ParamCode` (M2),
the layer chain as data (M5), data-driven cards (M7).
