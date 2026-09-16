# Videoboy — Build Spec (macOS, native)

**App name: Videoboy.** A live analog-style SD video mixer. Use "Videoboy" as the product/bundle name, window title, and default template author throughout.

Instructions for Claude Code. Read this entire file before writing code. Build in the phase order given. Each phase ends in a launchable `.app` that must be verified before moving on. Do not attempt to build all phases at once.

---

## 0. What this app is

A native macOS live-video mixing application for producing SD (480i/480p, 4:3) glitch/analog-aesthetic output, driven off a musical clock, controlled by MIDI, and sent to cheap HDMI→RCA adapters for analog finishing (VHS, MX-1, AVE-5, feedback loops). It replaces analog *source decks* with digital file playback; the analog *processing chain downstream stays physical*. Audio is out of scope for output (the app is silent) but the clock listens to audio for beat detection.

Design target for UX: Logic Pro X / pro-app density, not indie utility. Information at a glance, tight custom AppKit views, no wasted chrome. See §14.

---

## 1. Tech stack (fixed — do not substitute)

- **Language:** Swift. AppKit (not SwiftUI) for the main window and all dense custom views. SwiftUI only permissible for isolated modal panels if it saves time; default to AppKit.
- **Render/compositing:** Metal. All frames live as `MTLTexture`/`CVMetalTexture`. One shared `MTLDevice`, one command queue, texture pool with reuse. No per-frame allocations in the render loop.
- **Video decode/playback:** AVFoundation (`AVPlayer`/`AVPlayerItemVideoOutput` → `CVPixelBuffer` → Metal) for standard files. **libav (FFmpeg) for DV** — see §5.
- **Image/AU filters:** Core Image is available and bridges to Metal (`CIContext(mtlDevice:)`). Use it for the "relevant AU/CI video filters" (§9) but keep the primary pipeline in Metal.
- **MIDI:** Core MIDI (`MIDIClientCreate`, virtual + hardware endpoints). Also OSC (see §7) via a small UDP layer.
- **Effects module format:** **ISF (Interactive Shader Format)** as primary. FFGL as secondary. See §8.
- **Persistence:** plain-text templates. TOML or JSON, human-readable and hand-editable. See §16.
- **Output packaging:** signed `.app` bundle.

Third-party via SPM only, kept minimal. Candidates: an ISF-parsing helper (or write the parser — the format is a GLSL file with a leading JSON blob), an OSC library, libav via a vendored xcframework.

---

## 1.5 Code standards & expandability (governing rule — applies to every phase)

This codebase is meant to be **opened up and worked on for years**. Optimize for a stranger (or the user, a year from now) understanding and safely extending it. When clarity and cleverness conflict, choose clarity. **A little bloat is acceptable if it buys stability, legibility, or easier repair** — prefer the boring, obvious, repairable version over the clever, compact, fragile one.

**Principles:**
- **Clarity over cleverness.** No dense one-liners, no hidden control flow, no premature optimization. Readable, boring, obvious code. Optimize only a spot proven slow, and comment *why* when you do.
- **Explain everything.** Every file opens with a header comment: what it is, its inputs/outputs, what it connects to, and how to extend it. Every type and non-trivial function gets a Swift doc comment (`///`). Name things in full — no cryptic abbreviations. No magic numbers; use the param-code table (§13) and named constants.
- **Prefer a little duplication over the wrong abstraction.** Don't force-share code between two modules just because they rhyme today. Independent units are easier to repair and delete. Extract a shared helper only once the pattern is real and stable.
- **One extension point.** The render-graph **Node protocol** (§2) is *the* seam. Adding a source, effect, output, or module = implement that one protocol + drop a plain-text manifest. Don't invent parallel plugin mechanisms. Ship a documented recipe: "To add a new module: (1) copy `Template.swift`, (2) fill these 4 methods, (3) declare param codes, (4) add manifest — done."
- **Uniform module skeleton.** Every node type follows the same file layout so a new one is copy-then-fill. Provide `Modules/_Template/` as the canonical starting point.
- **Fail visibly, never silently.** No swallowed errors. Log with subsystem tags (`[clock]`, `[dv]`, `[midi]`, `[titler]`). A missing core/ROM/plugin/file degrades gracefully to a greyed, labeled state — never a crash (consistent with §16, §18.2). Include a debug overlay toggle showing clock phase, per-node latency, dropped frames, and active mappings.
- **Feature flags for in-progress work.** Every subsystem behind a flag so half-built modules can ship disabled without destabilizing the app. This is how phases stay independently shippable.
- **Test the fragile bones only.** Unit-test the three things most likely to break silently: the clock/scheduler + latency compensation (§4), param-code mapping resolution (§13), and template save/load round-trip (§16). Skip exhaustive UI tests.

**Folder layout (fixed):**
```
/App            app shell, window management, menus
/Graph          Node protocol, render graph, texture pool, scheduler
/Clock          render clock, musical transport, beat detection, Link
/Modules
   /_Template   canonical copy-me module (documented skeleton)
   /Sources     file, dv, photo-folder, screencapture, ip-in, svg, capture, titler-native, titler-emu
   /Effects      isf host, ffgl host, composite-codec, echo, mx1-set, ci-passthrough
   /Outputs     display-out, recorder, ip-out, scope
/Control        control-event bus, midi, osc, detect/learn, param-code registry
/Emu            out-of-process libretro host, IPC, library manager (§18.2)
/Persistence    template read/write, migration
/UI             AppKit views (previews, meters, faders, panels)
/Docs           ARCHITECTURE.md, ADD-A-MODULE.md, data-flow diagram, per-subsystem README
```

**Docs are a deliverable, not optional.** `ARCHITECTURE.md` (the graph + two clocks, one diagram), `ADD-A-MODULE.md` (the recipe above, worked through with one real example), and a short README in each `/Modules/*` subfolder. Keep them updated as part of each phase's "done."

---

## 2. Core architecture

Everything is a **node** on a render graph evaluated once per output frame. Nodes: Source → Channel FX → Sub-mix → Layer-composite → Output. All connections carry a `MTLTexture` at project resolution/pixel-format.

```
A ─▶[chFX]─┐
B ─▶[chFX]─┼─▶ SUB-MIX ONE ─▶[bus FX]─┐
           │   (layer comp A over B)   │
C ─▶[chFX]─┐                           ├─▶ PRIMARY OUT (ONE over TWO) ─▶ outputs/recorders/scopes
D ─▶[chFX]─┼─▶ SUB-MIX TWO ─▶[bus FX]─┘
           │   (layer comp C over D)
```

Hard rule from the brief: **A+B always feed ONE; C+D always feed TWO.** Never remap. "Simple mode" disables C, D, and TWO and hides their UI (A/B → ONE → primary). Provide it as a top-level toggle.

The graph is driven by a single **render clock** (display-linked, §4). The **musical clock** (§4) is a separate timing bus that schedules parameter changes, cuts, and clip advances onto beats — it does not drive frame production.

Build the graph as a data structure (nodes + typed edges) so templates (§16) are just serialization of it.

---

## 3. Output path (the whole point — build first, verify on real hardware)

Target: two independent program feeds (ONE, TWO — though PRIMARY is the composite) sent to **MicroSilicon-type HDMI adapters** that a downstream HDMI→RCA converter feeds into the analog chain.

**How the Mac addresses these adapters:** an HDMI output adapter appears to macOS as an **external display**, not a media device. So "sending a player to a card" = presenting a borderless, full-screen `NSWindow` on that display, containing a `MTKView` that draws the program texture. Implement:

- Enumerate displays (`NSScreen` / CoreGraphics `CGGetActiveDisplayList`).
- A **Display Router** panel: assign PRIMARY / ONE / TWO / preview / test-pattern to any connected display.
- Borderless output windows: no title bar, no menu, `level` above normal, pointer hidden, exact pixel mapping (1:1, no HiDPI scaling — force backing scale 1.0).

**Resolution / frame rate — this is the source of your VDMX frame-rate trouble, treat it carefully:**

- Default project format: **720×480, 4:3, 29.97 fps interlaced (480i59.94)** — this is what the analog chain actually wants. Also offer 480p59.94, 640×480 square-ish, and PAL 720×576/25i.
- The HDMI adapter's EDID advertises modes. You cannot force a mode the adapter won't accept. Query the mode, and if 480i isn't offered, output **480p59.94** and let the downstream HDMI→RCA box handle interlacing, OR do **software interlacing** (see §11) into a 60p signal (two fields per 59.94 frame → present at 59.94). Expose the choice explicitly per output; do not guess silently. Log the negotiated mode in the Display Router so the user sees what actually happened.
- Decouple **decode rate**, **render rate**, and **output present rate**. Sources at 23.976/24/25/30 get retimed to the clock, not frame-dropped ad hoc. Present exactly on the display's `CVDisplayLink` callback for that screen.

**Verify Phase 1 on the actual MicroSilicon adapter + a CRT/VHS before proceeding.** Frame-rate correctness cannot be verified in software alone.

---

## 4. Timing: two clocks

### 4a. Render clock
Per-output `CVDisplayLink` (or `CADisplayLink` on 14+). Drives frame production and present. Nothing musical here.

### 4b. Musical clock (the "pulse")
Your model is correct and is the standard DAW transport model. Implement it as a **scheduler with lookahead**, which is stronger than "one pulse to register, next to act":

- A master **transport** holds: BPM, running/stopped, phase (position within bar), PPQN subdivisions.
- BPM comes from: (a) tap tempo, (b) manual entry, (c) **audio beat detection** (§4c), (d) external **MIDI clock** in, (e) **Ableton Link** if you add it (recommended later — network beat sync, well-documented). Selectable source, with an offset/nudge control.
- The transport emits **future-timestamped events**: "beat N occurs at host-time T." Modules subscribe.
- **Latency compensation (do this, don't skip it):** each module declares its processing latency in frames. When a module must *act on* a beat (a cut, a param jump, a clip advance), it schedules the action for `T − module_latency` so the visible result lands on T. This is exactly how Ableton compensates: everything is delayed to the longest-latency path so all events land on the beat. Maintain a global `maxLatency` and align to it. This subsumes your "takes one pulse to register, next to act" — that's the degenerate case where latency = one beat.
- Distinguish **BPM-synced** modulation (LFOs, fades — compensated automatically) from **transport-position** actions (things that read bar/beat position — the ones that go out of sync if you forget compensation). Flag transport-position modules in the graph.

Subdivision system for clip/slideshow timing: each beat subdivides to 1/1, 1/2, 1/4, double-time, triple, dotted. A module picks its subdivision and the scheduler hands it the right timestamps.

### 4c. Audio beat detection
Input from an audio device (`AVAudioEngine` tap) or system audio. Onset/tempo detection: energy-based onset + autocorrelation tempo estimate is enough; do FFT for spectral flux. Output feeds transport BPM/phase and also a raw **audio-reactivity bus** (RMS, per-band levels, onset flags) that any effect parameter can subscribe to (§13).

---

## 5. DV playback and DV/MPEG artifact manipulation (the hard, central feature)

**Reality:** native DV decode via AVFoundation is gone (Apple dropped the QuickTime 7 codec path at macOS 10.15). Do **not** rely on AVFoundation for DV.

**Path:**
1. Vendor **libavcodec/libavformat** (FFmpeg) as an xcframework. Decode DV (`dvvideo`) → frame → upload to Metal. **Licensing:** build FFmpeg **LGPL** (shared, no GPL-only components like x264) so the `.app` can be distributed; document the FFmpeg version and license in the bundle. If any GPL component is pulled in, flag it and stop.
2. **Artifact manipulation happens on the compressed bitstream, before decode** — this is the "data is king" requirement and it's the whole reason DV matters. DV frames are DIF blocks (fixed-size, self-contained macroblocks with their own DCT coefficients). Implement a **DV DIF corruptor** node that operates on the raw `AVPacket` bytes pre-decode:
   - drop/duplicate/shuffle DIF blocks
   - zero or bit-flip DCT coefficient regions
   - swap audio/video DIF sequences
   - hold/repeat sequences on beat
   All corruptors are clock-schedulable and MIDI-mappable.
3. **MPEG artifacting:** same idea for an MPEG-2/H.264 path — a bitstream node that drops P/B frames, corrupts motion vectors, or holds reference frames to produce datamosh/pixel-bleed. Decode the corrupted stream with libav. Keep MPEG and DV as separate corruptor modules with shared infrastructure.

Provide a "DV Stream" playback module that presents DV files as first-class sources with the corruptor chain inline, matching what was scoped in the prior DV conversation.

---

## 6. Sources

Each source is a node producing a texture on the clock:

- **Video file** (AVFoundation for standard codecs; libav path for DV).
- **DV stream** (§5).
- **Photo folder as a clip (priority feature).** Import a folder → treat as an ordered image set. Unlike Resolve, do **not** bake to a frame sequence at project fps. Instead bind advancement to the **musical clock**: right-click the clip → interpretation = advance every 1/1, 1/2, 1/4, double-time, etc. The clip is a "player" whose playhead is the transport. Support ping-pong / loop / one-shot (§12 shuttle). This makes slideshows and animations behave as beat-locked clips.
- **Screen capture as a source.** Use `ScreenCaptureKit` (`SCStream`) — pick display, window, or region → texture. Mirror VDMX's implementation model (live, low-latency, selectable target). Provide it as a normal source anywhere in A/B/C/D.
- **IP feed in.** Accept an incoming network video stream (NDI if you license/vendor the SDK — the de facto standard for IP video; otherwise RTSP/RTP via libav, or a simple MJPEG/UDP path). Make it a selectable source. (Also an output — §15.)
- **Capture in (DVC100 + HDMI capture).** See §10.
- **SVG source** (§17), **test pattern** (§11), **title generator** (§18) are also selectable sources.

Source management: a **clip bin / pool** with folder import, tagging, quick assignment to A/B/C/D, thumbnails, and drag to a channel. Fast keyboard + MIDI assignment. Detect-style controller setup applies here too (§7).

---

## 6A. Generators (synthetic sources)

No-input producers that emit a texture on the clock, selectable anywhere A/B/C/D, routable through the composite path (§9) and effect chains, and sharing the same parameter/addressing surface as everything else (§13). Most are **ISF generators** (a shader with no `inputImage`, per §8); a few are native Metal where that's simpler. Register them in the source bin alongside files and captures (§6).

**Base set** (the standard VJ/broadcast/graphics generator vocabulary — don't exceed it without reason):
- **Solid color** — RGB/HSV pick, with NTSC-legal presets and an out-of-gamut warning.
- **Gradient** — linear/radial, 2+ stops, angle.
- **Checkerboard** — cell size, two colors, offset/phase.
- **Stripes / bars** — width, angle, count (calibration bars live under test patterns §11; this is the freeform version).
- **Grid / crosshatch** — line weight, spacing (feeds feedback seeding, §10/§11).
- **Concentric rings / target.**
- **Value / white noise** — static grain.
- **Perlin/simplex noise field** — smooth procedural noise; octaves, scale, drift speed. The basis for most "cloud" looks.
- **Difference clouds / plasma** — turbulent fractal noise (the Photoshop "Difference Clouds" look = accumulated absolute-difference fractal noise); octaves, turbulence, palette.
- **Dot / halftone field** and a **scanline/CRT-bar** generator for overlay use.

**Clock oscillation (required, variable-rate).** Any generator parameter — and generally any param code (§13) — can be driven by an **LFO locked to the transport**:
- Rate as a **clock subdivision** (4/1, 2/1, 1/1, 1/2, 1/4, 1/8, dotted, triplet) so motion stays musical, plus a **free-run Hz** mode for un-synced motion. Rate is fully variable and is itself a mappable/automatable parameter.
- Shapes: sine, triangle, ramp up/down, square, sample-and-hold, noise — with depth, phase offset, uni/bipolar, and invert. Deliberately the same shape set as the audio-react options (§13) so the two feel identical to use.
- Enables e.g. checkerboard phase flipping every 1/4, plasma scale breathing on the 1/1, a solid strobing between two colors on the beat, noise reseeding on a subdivision.
- Oscillation runs through the same latency-compensated scheduler (§4), so a beat-synced flip lands on the beat.

---

## 7. Control: MIDI, "shift-to-detect," OSC, generic controllers

- **Core MIDI** in/out, hardware + virtual endpoints. Support Note, CC, Program Change, 14-bit CC, NRPN, and **MIDI clock** (in for tempo, out for slaving downstream).
- **Detect / learn ("shift-to-detect"):** replicate VDMX's smart detect. Hold a modifier (Shift), touch a control in the UI, then move a hardware control → the app captures the incoming message and maps it. Bonus: on connect, fingerprint known controllers (by MIDI port name / SysEx identity reply) and auto-load a mapping template if one exists. Ship templates for a few common decks; make templates user-editable plain text.
- **Every mappable target carries a stable address code** (§13) so remaps survive module changes.
- **OSC** in/out over UDP for controllers/phones/other software. Same learn flow.
- Design the input layer as a generic **ControlEvent** bus (source-agnostic: MIDI, OSC, keyboard, audio-reactivity all normalize to it) so "support lots of kinds" is one abstraction, not N special cases.

---

## 8. Effects module system (ISF-first)

- **Primary format: ISF.** It's GLSL + a JSON header describing inputs; it's the format VDMX uses, it's open, and it has a Metal path on macOS. Write/vendor an ISF parser: parse the JSON blob, translate the GLSL to Metal (via a GLSL→MSL step, or run the community Metal ISF path), expose declared INPUTS as mappable parameters. Support `inputImage` (→ effect), no image input (→ generator), and two-input+progress (→ transition).
- Scan the standard cross-app ISF folders (`~/Library/Graphics/ISF/`) plus an app-managed folder. "Modules should be importable" = drop an ISF file in, it appears.
- **FFGL** as secondary for effects needing non-shader logic. Load `.bundle` plugins from `~/Library/Graphics/FreeFrame Plug-Ins/`. Lower priority than ISF; implement after ISF works.
- **Native modules** for things that are not shaders: the DV/MPEG bitstream corruptors (§5), capture/feedback (§10), scopes (§19), title gen (§18). These share the same parameter/addressing/mapping infrastructure as ISF modules so the UI treats them uniformly.

Do **not** build a large modern-looking effect library. Effects are: analog-behavior emulation (§9), a small MX-1-style set, echo/trails, the AU/CI passthrough filters, and whatever ISF files the user drops in.

---

## 9. Effects: analog emulation, not modern looks

The "not obvious to most" analog character does **not** come from the MX-1's named effects (those — mosaic, posterize, negative, freeze, flip, B&W, paint — are trivial shaders; build them, but they're not the magic). It comes from the **composite signal path**. Build a **CompositeCodec module** that emulates NTSC encode→decode:

- RGB→YIQ, chroma modulated on a ~3.58 MHz subcarrier, luma/chroma bandwidth limiting, then decoded back — producing dot crawl, rainbowing, chroma bleed, ringing.
- 4:1:1 / 4:2:2 chroma subsampling options (DV is 4:1:1 NTSC — lean into it).
- Composite vs S-Video path toggle (S-Video skips the chroma-cross artifacts — gives the "slightly cleaner" MX-1 Y/C look).
- TBC behavior emulation: line jitter, head-switching noise band at frame bottom, slight time-base wobble; toggle "TBC locked" (clean) vs "off" (wobble).
- Generation-loss stacking: run the codec N times for Nth-gen VHS dubbing feel.

Other required effects:
- **Echo/tone trails** (VDMX-style feedback echo): frame-history buffer, feedback gain, decay, key/luma-threshold. Clock-syncable.
- **MX-1 effect set:** freeze, negative, B&W, mosaic, posterize/paint, flip/mirror — as ISF or simple Metal shaders.
- **AU/Core Image passthrough:** expose the useful CI filters (saturation, exposure, hue, `CIAffineTransform` for scale/skew/flip/rotate, sharpen, etc.) as mappable modules. Enumerate available CI filters and whitelist the sensible video-rate ones.
- Overscan / CRT-target features live in §11.

State plainly in code comments where an effect is *behavioral emulation* vs a real signal model, so future work can deepen the accurate ones.

---

## 10. Capture + feedback (incorporate the DVC100 app, then push it)

- **Capture in:** HDMI capture dongles and the Pinnacle **DVC100** present as UVC/`AVCaptureDevice`. Bring in the existing DVC100 app's capture code as an `AVCaptureSession` source node. Support device pick, format pick, and expose it as a normal source (assignable to A/B/C/D, recordable, scope-able).
- **Feedback:** the DVC100 app already sends signal back to the input it captures, with a frame-delay setting. Generalize:
  - A **feedback bus**: route any output/bus back into an input, internally (texture feedback loop) and/or externally (out a display → physical HDMI→RCA → back into a capture dongle).
  - **Frame-delay** control (0..N frames), **feedback gain**, geometric transform in the loop (zoom/rotate/offset — the classic infinite-tunnel), and **key/threshold**.
  - Research note baked in: physical feedback through the adapters has real round-trip latency (capture buffer + display present + converter). Provide a **measured-latency calibration**: flash a frame, detect its return, compute round-trip frames, and offset the clock scheduling for feedback-driven beat effects so they stay on time. Expose the measured value.
  - Black/colored-frame insertion and grid overlays in the loop to seed echo artifacts (§11).
- All capture/feedback controls are detect-mappable (§7) and clock-schedulable.

---

## 11. CRT / analog-target features

- **Safe-zone overlays** on previews (action-safe / title-safe 4:3), toggle.
- **Overscan** control (previews show overscan boundary; output can pre-scale for overscan).
- **Test pattern generator** as a source and as a routable output (SMPTE-style bars, 100% bars, pluge, crosshatch/grid, flat fields). Toggle to send straight to any display for calibration.
- **Black / colored-frame insertion**: per-channel or on-bus, clock-timed — for BFI motion feel and to seed feedback echoes.
- **Grid / crosshatch insertion** for feedback seeding.
- **Software interlacing**: build ONE from two fields when outputting to an interlaced-expecting chain; expose field order.

---

## 12. Mixing UI + shuttle

- **Two-input, two-output mixer, fixed routing:** A/B → ONE, C/D → TWO (§2). Per sub-mix: crossfader (A↔B, C↔D) with **auto-fade** and **cut-on-beat** buttons. **Swapping cut** button (hard-cut swap of the two feeding a bus).
- **Layer compositing (Photoshop modes):** ONE = A over B, TWO = C over D, PRIMARY = ONE over TWO — each composite has a blend mode: normal, multiply, screen, overlay, lighten, darken, difference, add, subtract, color-dodge/burn, hard/soft light. Implement all as Metal blend shaders. Per-layer opacity.
- **VDMX-style routing highlight:** yellow highlight on a channel shows the sub-track letters it feeds, so the signal path is legible at a glance. **All** channels get preview boxes (the brief wants all previews, not just some):
  - Left cluster: small **A** preview + small **B** preview, larger **ONE** preview beneath.
  - Right cluster (mirror): small **C** + small **D**, larger **TWO** beneath.
  - **PRIMARY** preview prominent.
- **Shuttle / transport per clip:** play, loop, **ping-pong**, front-to-back, scrub, in/out points, speed. Clock-lockable so loops respect the beat grid.

---

## 13. Parameter addressing (survive module changes)

Every adjustable parameter has a **stable code** independent of the module instance, written as a parenthetical, so templates and mappings don't break when modules change. Scheme:

- Module-scoped, e.g. scale is always `11A`, opacity `01A`, etc. Reserve a fixed code table for common params (opacity, scale, x, y, rotate, blend-amount, feedback-gain, delay-frames…) so they're identical across every module. Module-unique params get module-local codes.
- A mapping (MIDI/OSC/audio-react/keyboard) targets the **code**, not the module pointer. Swapping the effect in a slot preserves any mapping whose code still exists.
- Audio-reactivity binds the same way: a reactivity source (RMS / band / onset) → a param code, with shape options: pulse, fade, invert, sample-hold, gate, envelope, on-beat-only. The detect button can link a physical control *or* an audio-react source to any code.

Serialize codes in templates (§16).

---

## 14. UI / UX — CANONICAL LAYOUT (build exactly this)

This section is normative. The window is one fixed grid; panels collapse but never move. Reference mockup: `docs/mockups/layout-v6.html` — the source of truth for **arrangement**. Where the notes below say otherwise, the notes win: they record changes the owner made after using the built interface, and the mockup has not been redrawn.

**Owner revisions (2026-09-16), after a review of the running app:**

1. **Record moved to the toolbar, top right** — a large round red button with its codec and stream selectors beside it, separated from the transport by a hairline. This overrides the "toolbar holds *only* transport/clock" rule in §14.1 and the "Record lives in the bottom bar" rule in §14.2. Reason: recording is the one control that must be hit without hunting and read from across a room. The bottom bar keeps Stream, Output and Toggles.
2. **Faders are custom, not `NSSlider`** (see §14.3). A hairline track with a small round knob does not read at a glance on a control surface.
3. **Effect parameters take two lines** (see §14.2).
4. **Panels that always appear together are joined**, not gapped (see §14.4).

### 14.1 The grid
One window, 5 columns × 5 rows, everything aligned top-to-bottom:

```
            col1(0.9)   col2(2.0)   col3(2.1)   col4(2.0)   col5(0.9)
row1 (1.05)  SOURCE A   SUB MIX ONE  PROGRAM    SUB MIX TWO  SOURCE C
row2 (1.05)  SOURCE B    (preview)   PREVIEW     (preview)   SOURCE D
row3 (0.60)  SUBMIX1 FX  A→B FADER  ONE→TWO F.  C→D FADER   SUBMIX2 FX
row4 (1.75)  (tall,      SUB MIX 1   ASSET      SUB MIX 2    (tall,
row5 (0.55)   spans      LIBRARY     BROWSER     LIBRARY      spans
              r3–r5)    ── RECORD / STREAM / OUTPUT / TOGGLES BAR ──  r3–r5)
```
- Sub Mix One preview spans rows 1–2 of col2; Program spans rows 1–2 of col3; Sub Mix Two spans rows 1–2 of col4.
- The two FX panels are tall, spanning rows 3–5 on the outer columns.
- The settings bar spans cols 2–4 on row 5.
- Above the grid: title bar, then a unified toolbar holding **only** transport/clock (tempo, tap, play, phase, clock source, sync, subdivision, detect/learn). Record/stream/output live in the bottom bar, not the toolbar. Below the grid: a status bar (MIDI/OSC/node count/dropped frames/fps).

### 14.2 Panels and their implied functions
Every panel is an `NSBox`-style group with a clickable header (disclosure chevron, title, optional bus-color dot, right-aligned mono subtitle). Clicking the header collapses the body; the panel keeps its grid cell so alignment never breaks.

- **Source A/B/C/D** (4 panels, outer columns). Each: a 4:3 preview of that channel's source, plus its own **shuttle strip** — ⇤ ◀ ▶ ⇥ transport buttons, a scrub track, and a loop-mode toggle (loop / ping-pong / one-shot, per §12). All four sources get a shuttle. Assigning a source = drag from a library/browser onto the panel, or pick from its header menu.
- **Sub Mix One / Sub Mix Two** previews. 4:3, safe-zone overlay, NTSC IRE readout. Header subtitle shows its feed (`A ▸ B`, `C ▸ D`) and blend mode.
- **Program Preview** (center, largest). Safe/test/overscan affordances, blend mode for ONE▸TWO, and the swap-cut. Shows the real output format (`720×480 · 480i`).
- **Sub Mix 1 FX / Sub Mix 2 FX** (tall outer). Ordered effect chain per sub-mix: Load Asset / Save row, then effect cards. Each card header: a **three-dash drag grip**, the name, an `NSSwitch` enable, and remove ✕.

  **Each parameter takes two lines, not one:**

  ```
  M S C   amount·31B                              0.42
  ▬▬▬▬▬▬▬▬▬▬▬▬▬▬●▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬
  ```

  Badges, name-with-param-code and the numeric value share the top line; the fader gets the full panel width to itself. One line left the control roughly forty points of travel in a column this narrow, which is unusable. The numeric readout is a **fixed width**, so the row does not twitch as digits change under a drag.

  **Order reads like Photoshop layers**: the card at the *top* is the last thing applied, so it is what you see on top. Signal therefore flows up the list. Drag the grip to reorder.
- **A→B Fader / ONE→TWO Fader / C→D Fader**. Each: Cut, Fade, Cut-on-beat toggle, Auto; an M/S/C/Slo column; labeled crossfader with numeric value. ONE→TWO additionally carries the swap-cut.
- **Sub Mix 1 Library / Sub Mix 2 Library.** Per-sub-mix working sets (the clips/generators staged for that side), thumbnail grid, page popup, search. Drag to a source panel to load.
- **Asset Browser** (center). Global library, tabbed: **Sources · Generators · VSTs · Graphics · Clips · Images** (plus Emulators when §18.2 ships). Search, Import, grid/list toggle. Items carry a type badge (DV, MOV, MPG, GEN, SVG, SCR, IP, CAP, EMU, IMG).
- **Record / Stream / Output / Toggles bar** (bottom, spans center). Four labeled sections: **Record** (codec, which streams — PRIMARY and/or discrete A/B/C/D, REC button), **Stream** (protocol, bitrate, Go Live), **Output** (per-destination routing popups showing negotiated mode, e.g. `PRI→HDMI-1 480i`), **Toggles** (safe zones, overscan, BFI, test pattern).

### 14.3 Cocoa control mapping (use real AppKit controls; don't reinvent)
`NSPopUpButton` for every selector (blend, codec, routing, page, clock source). `NSSegmentedControl` for tab strips and mutually-exclusive toggles (browser tabs, safe/test/overscan, grid/list). `NSSwitch` for effect enable and the boolean toggles in the settings bar. `NSSearchField` for searches.

**Continuous parameters and crossfaders use `VBFader`, not `NSSlider`.** `NSSlider` gives a hairline track, no fill showing travel, and a small round knob that vanishes against a dark panel — none of which reads at a glance on a dense control surface, and none of which it lets you change. `VBFader` is a thick track, a filled portion showing position, and a cap that **overhangs the track**, as a DJ fader's does; the overhang is what makes position readable in peripheral vision. A compact variant is used where a fader is more readout than control (a shuttle's scrub track). All of its geometry lives in `Theme.Fader`.

**Library and browser grids use fixed-size cells.** Every item is exactly one thumbnail wide with a fixed image height and caption height, packed tightly. Cells that size themselves to their captions read as clutter however neatly they are spaced. `NSOutlineView`/custom stack for effect chains. `NSBox`/custom `NSView` groups for panels. System accent color for active/selected state; amber/cyan used **only** as ONE/TWO bus identity, never as chrome. Standard dark-mode materials and vibrancy; hairline separators.

### 14.4 Behavior
- **Docked, collapsible, never movable.** No floating/undocking/reordering (this is the deliberate break from VDMX). Collapse state and split ratios serialize into the plain-text template (§16); because panels can't move, that serialization stays trivial.
- **Panels that always appear together are joined, not gapped.** Source A sits directly on Source B, and C on D; the libraries sit directly on the settings bar. Joined panels share a hairline and square off the corners on that edge, so the pair reads as one block. This is the Resolve/FCP reading of space — a gap means "these are separate concerns", so putting one between every panel makes all the gaps meaningless and the window busier than it needs to be. Gutters and radii are tighter than the mockup's for the same reason (§14.4 already anticipated this).
- **Width-reactive** for full-screen and macOS Split View: wide shows everything; compact auto-collapses the outer columns (sources + FX) to labeled rails; narrow keeps Program + faders + the settings bar. Reflow and auto-collapse rather than horizontal scrolling. Implement with `NSSplitView` (fixed, non-rearrangeable dividers), `NSStackView`, Auto Layout priorities, and a width observer driving breakpoint states. Set a minimum window width and drop to narrow instead of clipping.
- **Detect affordance:** holding Shift highlights every mappable control (§7).
- Previews are Metal-backed; never block the render thread for UI.
- **Density tuning is deferred, not skipped.** Corner radii, padding, and inter-panel gutters in the mockup are larger than ideal — a live control surface wants tighter geometry. Put radii/padding/gutter values in one place (a single `Theme`/design-token file) so they can be dialed in later without touching layout code.

---

## 15. Routing + recording

- **Routing/send panel** for A/B/C/D and the sub-mixes. A **send-channel** abstraction: each output slot picks a send; outputs are a mix of (a) macOS displays (the HDMI adapters), (b) app-internal outputs (recorder, scope, IP-out), (c) screen-capture consumers.
- **IP feed as input and output** (§6 for in). IP-out: encode PRIMARY (or any bus) to NDI (preferred) or RTP/MJPEG for another machine/app.
- **Recording:** record PRIMARY, and **discrete A/B/C/D** and/or ONE/TWO simultaneously when armed. Use AVAssetWriter; format choice (ProRes for quality, or a DV-out path via libav if the user wants tape-accurate re-encode). Record at project fps; timecode-stamp so multi-stream recordings align.

---

## 16. Templates (plain text)

- The whole app state = the render graph + mappings + layout + clock settings, serialized to **human-readable, hand-editable** TOML/JSON.
- Save/load setups as templates. Param codes (§13) are the mapping keys. A template edited in a text editor must reload correctly.
- Include a template version field and a migration path so future module changes don't hard-break old templates (unknown codes are preserved/ignored, not fatal).

---

## 17. SVG source with PS1-style rendering

- Import SVG, display options: **still** and **rotate**, plus shuttle controls for **scale** and **texture**.
- **PS1-limitation toggle:** render the SVG (triangulated) through Metal with deliberate PS1 constraints — low-precision vertex snapping (integer/coarse raster grid), affine (non-perspective-correct) texture mapping, no sub-pixel precision → the characteristic **triangle/vertex wobble** and texture warp. Plenty of reference implementations exist for "PS1 vertex snapping / affine texture warp" shaders. Toggle on/off.
- Low internal render resolution with nearest-neighbor upscale to 480 for authenticity.

---

## 18. Title generation

Two independent titling paths. 18.1 is a clean native character generator; 18.2 runs real vintage titling software under emulation. Both feed the composite path (§9) and register as sources (§6).

### 18.1 Character generator (clean, native — Core Text)
A basic, non-emulated character generator scoped deliberately to about **Premiere/Resolve "basic text" / Essential Graphics** — not a motion-graphics suite. Built on Apple **Core Text** for layout/rendering, with Core Image/Metal for the styling passes. Works as both an overlay effect (on a bus) and a source. Keep the feature set close to this list; don't let it sprawl:
- Multi-line text entry; font family/weight/size; alignment.
- **Kerning** and **tracking** (letter spacing); **leading** (line spacing).
- **Fill:** solid color (NTSC-legal warning), opacity.
- **Outline / stroke:** color + width.
- **Drop shadow:** color, x/y offset, blur, opacity.
- Position/anchor, scale, safe-zone-aware placement (§11).
- Roll / crawl / reveal modes, clock-syncable (§4).
- Every control carries a param code (§13) and is detect/audio-react mappable.

**Optional "period" preset:** a toggle that routes the CG through the CompositeCodec (§9) and applies mid-90s budget-titler styling — limited palette, chunky edges, low bit depth, slight positioning jitter, 480-line feel. So the old lo-fi titler look is a *style preset on the clean CG*, not a separate module. For true hardware/software authenticity, use 18.2.

### 18.2 Emulated titler library (run the actual vintage software)

Run real 1980s/90s home-computer titling software inside emulators, capture the emulator's video output as a source, and land the user on the working title-entry screen automatically. Feasibility clarification: the §0/§9 "don't run titler firmware" rule was about **custom-ASIC hardware** devices (Videonics), which have no practical emulator. General-purpose **home computers do emulate perfectly** — that's the whole basis of this feature.

**Emulator integration — out-of-process libretro host (required for distribution).**
- Use **libretro cores**, current and maintained per platform: **PUAE** (Amiga), **VICE** `x64`/`x64sc` (C64, and VIC-20/C128 if wanted), **hatariB** (Atari ST/STE), **MAME** or standalone **AppleWin** (Apple II — weakest option; MAME core is heavier, flag it).
- **Licensing (decides the architecture):** these cores are **GPL**. Do **not** statically link a GPL core into the distributed `.app`. Run each core in a **separate helper process** (an out-of-process libretro host executable) and pass its framebuffer to the main app over **shared memory / IPC**. The GPL core stays a distinct program; the app stays distributable. If — and only if — the build is personal-use and never distributed, direct linking is acceptable; expose this as a build flag and default to out-of-process. As a lowest-coupling fallback, run standalone RetroArch/FS-UAE and capture via **ScreenCaptureKit** (§6) — no linking at all, less integrated.
- **ROMs/firmware/disk images are user-supplied.** Amiga needs a Kickstart ROM; Atari ST needs a TOS ROM; the titling software needs its disk image. All copyrighted — the app references them by path and never bundles or fetches them. Show a clear "missing ROM/disk" state per entry with the expected filename.

**Framebuffer → source.** The host process exposes the core's video (libretro `retro_video_refresh`) as a shared texture; the main app wraps it as a **Source node** (§6), so an emulated titler is assignable to A/B/C/D, recordable, scope-able, and runs through the CompositeCodec (§9).

**Genlock/key behavior.** Amiga (and most of these) titlers were designed for genlock, keying on a background color (colour 0 = transparent). Provide **luma/chroma key** on the emulator source so the background drops out and the title overlays live video — reproducing how these were actually used. Key color/threshold is mappable (§13).

**"Smack dab on the right screen" — save-state landing (primary mechanism).**
- libretro cores serialize state (`retro_serialize`/`retro_unserialize`). Each library entry ships a **save-state captured at the working title-entry screen**. Opening an entry = launch core → mount disk → immediately deserialize the saved state → user is on the title screen with zero navigation.
- The user captures each save-state once, for their own software (state contains copyrighted memory, so it's their own copy, same as the disk image).
- **Fallback macro:** for entries where save-states are unreliable, a scripted **autoboot macro** — a timed sequence of injected keypresses/disk-swaps recorded once and replayed on open. Store the macro in the entry manifest as plain text (steps = {delay_ms, action}).

**Input injection + control.** The host feeds keyboard/joystick to the core (libretro input callback). Route the app's **ControlEvent bus** (§7) into it, so MIDI/OSC/detect mappings and keyboard can drive the emulated titler (e.g. map a pad to "commit line," "next page," "roll"). Standard host↔emulator keyboard passthrough with a focus toggle.

**Library structure (what the user asked for).**
- Organized **by platform → software (style) → entry**, as a browsable menu with submenus. Suggested seed entries (user populates each with their own disk image + ROM + save-state):
  - **Commodore Amiga** (PUAE): Scala / Scala InfoChannel (broadcast rolling text/graphics), ProVideo, Aegis Video Titler.
  - **Commodore 64** (VICE): SCA Title-Maker (scrolled message boards), Video Title Shop.
  - **Atari ST** (hatariB): Video Titler ST, TV Titles.
  - **Apple II** (MAME/AppleWin): Broderbund VCR Companion (title cards, "Please Rewind" screens, borders).
  - Structure is open — user adds platforms/entries freely.
- Each entry is a **plain-text manifest** (TOML/JSON, matching §16 ethos):
  ```
  [entry]
  name        = "Scala InfoChannel"
  platform    = "amiga"
  core        = "puae"
  rom         = "system/kickstart31.rom"   # user-supplied, referenced not bundled
  disks       = ["software/scala_ic.adf"]  # user-supplied
  savestate   = "states/scala_title.state" # lands on title-entry screen
  autoboot    = "macros/scala_boot.txt"    # fallback if no savestate
  key_color   = "#000000"                  # genlock key
  help        = "help/scala.md"
  ```
- Unknown/missing referenced files → non-fatal, entry shown greyed with the missing filename (consistent with §16).

**Per-entry help file (what the user asked for).**
- Each entry has a small **plain-text/markdown help file** surfaced in a **description pane** beside the emulator view: what the software does, how to enter/commit a title, and a **hotkey table** (both the software's native keys and this app's overlay keys — focus toggle, key, roll trigger, key-color, recapture-state).
- App can **auto-generate a starter help file** on entry creation (template with the standard app hotkeys pre-filled); user edits the software-specific parts.
- Example help file shape:
  ```
  # Scala InfoChannel — quick help
  Landing screen: page editor (loaded from save-state).
  ## App hotkeys
  ⌘K  toggle keyboard focus (app ⇄ emulator)
  ⌘G  toggle genlock key on/off
  ⌘.  trigger roll/crawl
  ⌘S  recapture save-state at current screen
  ## Software keys
  F1..F4  page templates
  Return  commit line
  ...
  ```

---

## 19. Scopes

- **Waveform** and **vectorscope**, plus a parade. Display **NTSC values** (IRE scale, 7.5 IRE setup line, 100 IRE, sub-black/super-white flags; vectorscope with NTSC color targets/boxes). Compute from the program texture on GPU, draw as a dense pro overlay. Selectable source (PRIMARY / any bus / any channel).

---

## 20. Phasing (build/verify in this order)

Each phase must launch and be verified before the next.

- **Phase 1 — Skeleton + output + clocks.** App shell, Metal graph with two file players → ONE/TWO → PRIMARY, display-router output to real HDMI adapters at 480i/480p, render clock, musical clock with tap/manual BPM + MIDI-clock-in, Core MIDI + detect/learn, param-code + mapping layer, plain-text template save/load. **Verify frame rate on real MicroSilicon adapter + CRT/VHS.** This de-risks the two things most likely to fail: output frame-rate negotiation and the clock model.
- **Phase 2 — Mixing UI.** Fixed A/B→ONE, C/D→TWO routing, crossfaders, swapping cut, cut-on-beat, auto-fade, all previews, routing highlight, blend modes, simple mode, shuttle/ping-pong.
- **Phase 3 — Sources.** Photo-folder-as-beat-clip, ScreenCaptureKit source, clip bin/pool, shuttle per clip.
- **Phase 4 — DV/MPEG.** libav integration (LGPL), DV playback, DIF bitstream corruptor, MPEG datamosh corruptor. Central feature — give it room.
- **Phase 5 — Effects + generators.** ISF host (parser + Metal), CompositeCodec/NTSC emulation, echo/trails, MX-1 set, CI/AU passthrough, audio-reactivity bus + shapes, the **generator set (§6A)**, and the **transport-locked LFO / clock-oscillation** system that drives both generators and any param code. FFGL after ISF.
- **Phase 6 — Capture + feedback.** DVC100/UVC capture, internal + external feedback with frame-delay, latency calibration, BFI/grid seeding.
- **Phase 7 — Analog-target + scopes + extras.** Safe zones, overscan, test patterns, software interlacing, NTSC scopes, SVG/PS1 source, the clean Core Text character generator (18.1) with its optional period preset. The **emulated titler library (18.2)** is the large item here — out-of-process libretro host, shared-memory framebuffer, save-state landing, input injection, library manager + per-entry help files; treat it as its own sub-milestone and verify one platform (Amiga/PUAE) end-to-end before adding the rest.
- **Phase 8 — Routing/recording/IP.** Send-channel routing, discrete multi-stream recording, IP in/out (NDI or RTP).
- **Phase 9 — Polish.** Detect fingerprinting/auto-templates, controller templates, layout persistence, Logic-grade UI pass, Ableton Link (optional).

---

## 21. Non-negotiables / gotchas

- A/B→ONE, C/D→TWO is **fixed**. Simple mode disables C/D/TWO.
- No DMX, no lighting, no external-hardware control beyond MIDI/OSC/capture/feedback/displays.
- Emulated titlers (18.2): GPL libretro cores run **out-of-process** (not statically linked) for any distributed build; direct-link only behind an explicit personal-use flag. ROMs/firmware/disk images are **user-supplied, referenced by path, never bundled or fetched**. Missing files are non-fatal.
- App outputs **no audio**; audio in is for beat detection + reactivity only.
- Default SD 4:3; other resolutions selectable but SD is the design center.
- DV must not go through AVFoundation. FFmpeg must be LGPL for distribution — if a GPL component is pulled, stop and report.
- No modern-looking effects. Effects are analog-behavioral, MX-1-class, echo, CI passthrough, or user ISF.
- Every mappable target has a stable param code; mappings target codes, not instances.
- Templates are plain text and hand-editable; unknown codes are non-fatal.
- Latency-compensate the musical clock (schedule at `T − latency`). Verify a cut-on-beat visibly lands on the beat on the CRT.
- Verify each phase on real hardware before continuing; do not assume software correctness for the output/frame-rate/feedback-latency parts.
- Follow §1.5 everywhere: clarity over cleverness, every file/type explained, one extension point, graceful degradation, docs kept current. Expandability is a first-class requirement, not a nicety.

---

## 22. First action for Claude Code

Start Phase 1 only. Scaffold the Xcode project (Swift, AppKit, Metal), get one file playing through the Metal graph to a borderless output window on a chosen display, add the two clocks and Core MIDI detect, and implement template save/load. Produce a running `.app`, then stop and report the negotiated output mode and measured present timing before Phase 2.
