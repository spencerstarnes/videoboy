# Videoboy feature inventory — verified against the code (2026-10-01)

Branch `feature/queue-names` at `a92f464`, app version **0.4.10** (`Core/Sources/VideoboyCore/VideoboyCore.swift`).
Every row was checked in the source, not taken from the docs (several docs are stale:
`docs/STATUS.md` describes v0.4.0, `docs/TODO.md` is flagged out of date by audit L8).
Evidence paths are relative to the repo root and are re-checked mechanically (§R).

**Status key:** ✓ shipped and on by default · ◐ partial / built with gaps · ⚑ built but
switched OFF by a feature flag · ✗ not built (only a comment, a greyed placeholder, or nothing)

Totals at the bottom.

---

## A. Platform and engine

| # | Feature | Status | Evidence |
|---|---|---|---|
| A1 | Native macOS app, AppKit + Metal, Apple Silicon (arm64) only | ✓ | `CLAUDE.md`, `App/Sources/Videoboy/Render/Engine.swift` |
| A2 | Core logic as a headless, unit-tested SwiftPM package (867 tests, 0 failures on 2026-10-01) | ✓ | `Core/Sources/VideoboyCore`, `scripts/test.sh` |
| A3 | Render graph: 4 channels → 2 sub-mix buses → Program (A/B→ONE, C/D→TWO fixed) | ✓ | `docs/SPEC.md` §2, `Core/Sources/VideoboyCore/Graph` |
| A4 | Frame-clocked engine, renders once per 29.97 content frame from a screen display link | ✓ | `App/Sources/Videoboy/Render/Engine.swift` |
| A5 | Decode ahead on per-clip queues; tick never waits more than 5 ms (holds last picture) | ✓ | `Core/Sources/VideoboyCore/Modules/Sources/ClipPrefetcher.swift` |
| A6 | Measured full-load stress: mean 6.4 ms / worst 17.8 ms; 10-min HD soak 0 dropped frames | ✓ | `docs/AUDIT-2026-09-28.md` |
| A7 | Feature flags with env override (`VIDEOBOY_FLAGS`) | ✓ | `Core/Sources/VideoboyCore/VideoboyCore.swift` |
| A8 | Param-code addressing: every control has a stable code (e.g. `24A`); mappings survive module swaps | ✓ | `Core/Sources/VideoboyCore/Control/ParamCode.swift`, `Core/Sources/VideoboyCore/Control/ParamRegistry.swift` |
| A9 | One extension seam (Node protocol + manifest), documented recipe | ✓ | `docs/ADD-A-MODULE.md`, `Core/Sources/VideoboyCore/Modules/_Template/ExampleNode.swift` |
| A10 | Project canvas: SD NTSC 720×480 @ 29.97 only today | ◐ | other canvases are planned for 0.4.11 (`docs/PROPOSAL-2026-09-26.md` §6) |
| A11 | Launch window listing what loads (Adobe/Logic style) | ✓ | `App/Sources/Videoboy/UI/LaunchWindowController.swift` |
| A12 | Self-QA harness: 40 named checks (offscreen PNG, DVC100 loopback, virtual MIDI) | ✓ | `scripts/selfqa.sh`, `docs/SELF-QA-HARNESS.md` |

## B. Sources (what can be loaded into A / B / C / D)

| # | Feature | Status | Evidence |
|---|---|---|---|
| B1 | Ordinary video files via AVFoundation (.mov/.mp4, H.264, HEVC incl. `hev1`, ProRes) | ✓ | `Core/Sources/VideoboyCore/Modules/Sources/AVFClipDecoder.swift`, `Core/Sources/VideoboyCore/Modules/Sources/HEV1Reader.swift` |
| B2 | MPEG-family files through the bitstream decoder (libav, LGPL) so the wedge has packets to damage | ✓ | `Core/Sources/VideoboyCore/Modules/Sources/MPEGStreamDecoder.swift` |
| B3 | DV files | ✗ | DV path removed 2026-09-28 (`git log` ad14e29, c5786d9) |
| B4 | Photo folder / image sequence as ONE beat-locked clip (`SEQ`, a frame per quarter note) | ✓ | `Core/Sources/VideoboyCore/Modules/Sources/ImageSequenceDecoder.swift` |
| B5 | 13 native generators (Solid, Linear/Radial Gradient, Checkerboard, Stripes, Grid, Rings, White Noise, Noise Field, Difference Clouds, Halftone, Scanlines, Now Playing) | ✓ | `Core/Sources/VideoboyCore/Modules/Sources/GeneratorSourceNode.swift` |
| B6 | ISF generators from the shared ISF folders (`~/Library/Graphics/ISF`, VDMX's) | ✓ | `Core/Sources/VideoboyCore/Modules/Effects/ISF`, `App/Sources/Videoboy/UI/GeneratorThumbnails.swift` |
| B7 | Test pattern source (SMPTE-style bars etc.) | ✓ | `Core/Sources/VideoboyCore/Modules/Sources/TestPatternSourceNode.swift`, `App/Sources/Videoboy/Platform/BarsSelfQA.swift` |
| B8 | Camera / capture card via AVFoundation (webcams, Continuity Camera, UVC) | ✓ | `App/Sources/Videoboy/Platform/LiveAVFoundationCapture.swift` |
| B9 | Window capture via ScreenCaptureKit (pick a window) | ✓ | `App/Sources/Videoboy/Platform/WindowCaptureSource.swift` |
| B10 | Configured sources list (Settings ▸ Sources, + / −) | ✓ | `App/Sources/Videoboy/UI/SourceListView.swift` |
| B11 | IP camera / NDI / RTSP / SRT input | ✗ | listed greyed in Settings ▸ Sources; no decoder |
| B12 | DV deck (FireWire) input | ✗ | greyed placeholder |
| B13 | DVC100 as a live source (not just self-QA loopback) | ✗ | `docs/BUILD-PLAN.md` backlog |
| B14 | Emulated titler: real Scala MM400 on Amiberry (Kickstart 3.1), out-of-process, genlock key | ◐ | `Core/Sources/VideoboyCore/Modules/Emu/EmulatedTitlerNode.swift`; key colour/threshold/edge have no fader |
| B15 | Native Core Text character generator | ◐ | `Core/Sources/VideoboyCore/Modules/Titler/CharacterGeneratorNode.swift`; node built, **not reachable from the UI** |
| B16 | Now Playing overlay (Apple Music + Spotify; three looks; fades on change) | ✓ | `Core/Sources/VideoboyCore/Modules/Titler/NowPlayingRenderer.swift`, `App/Sources/Videoboy/Platform/NowPlayingWatcher.swift` |
| B17 | SVG / PS1-style source | ✗ | `docs/SPEC.md` §17, not started |
| B18 | Audio playback of clips | ✗ | by design: the app outputs no audio (`docs/SPEC.md` §21) |

## C. Per-channel playback (the shuttle)

| # | Feature | Status | Evidence |
|---|---|---|---|
| C1 | Play / stop per source, preview per source | ✓ | `App/Sources/Videoboy/UI/PanelBodies.swift` |
| C2 | Loop · Ping-Pong · One Shot | ✓ | `Core/Sources/VideoboyCore/Modules/Sources/ClipSourceNode.swift` |
| C3 | Scrub track and frame step | ✓ | `App/Sources/Videoboy/UI/VBMiniPlayBar.swift` |
| C4 | STEP playback locked to the beat (a frame per 8 bars … per 1/16), click faster / right-click slower | ✓ | `Core/Sources/VideoboyCore/Modules/Sources/ClipSourceNode.swift` (`slowLadder`, `fastLadder`), `App/Sources/Videoboy/UI/VBStepButton.swift` |
| C5 | Playback speed parameter | ✓ | `Core/Sources/VideoboyCore/Modules/Sources/ClipSourceNode.swift` (`playbackSpeed`) |
| C6 | In / out marks (stored in the catalog, trim playback) | ✓ | `Core/Sources/VideoboyCore/Persistence/Catalog.swift` |
| C7 | Fit · Fill · Stretch · Centre per source (FIT key) | ✓ | `Core/Sources/VideoboyCore/Modules/Sources/PreviewFill.swift` |
| C8 | Queue per channel (Play Next to the front, Play Last to the end; saved with the show) | ✓ | `Core/Sources/VideoboyCore/Modules/Sources/ClipQueue.swift`, `App/Sources/Videoboy/UI/QueueView.swift` |
| C9 | A/B ROLL (roll the taken source, re-cue the leaving one) + ADV (load the next clip) | ✓ | `Core/Sources/VideoboyCore/Control/ABRoll.swift`, `docs/specs/ab-roll-adv.md` |
| C10 | Hot cues / cue points inside a clip (DJ-style) | ✗ | no cue-point model; only one in/out pair per clip |
| C11 | Reverse play as a key, time-remapping curves | ✗ | reverse only via Ping-Pong |
| C12 | Beat-quantised loop lengths inside a clip (loop roll, beat jump) | ✗ | — |

## D. Library, catalog and import

| # | Feature | Status | Evidence |
|---|---|---|---|
| D1 | SQLite catalog (Lightroom model), WAL, single writer queue, weekly backup | ✓ | `Core/Sources/VideoboyCore/Persistence/Catalog.swift` |
| D2 | Bookmarks so moved/renamed files can be found (relink in the model) | ◐ | `Core/Sources/VideoboyCore/Persistence/Catalog.swift`; no Relink… command found in the UI |
| D3 | Nested bins; imports keep the folder tree | ✓ | `App/Sources/Videoboy/Platform/BinsSelfQA.swift` |
| D4 | Icon / list / column views (Finder model), path bar, multi-select, drag anywhere, ⌘C/⌘V/⌘⌫ | ✓ | `App/Sources/Videoboy/UI/LibraryGridView.swift`, `App/Sources/Videoboy/UI/LibraryListView.swift`, `App/Sources/Videoboy/UI/LibraryColumnView.swift` |
| D5 | Hover-scrub thumbnails with real decoded frames | ✓ | `App/Sources/Videoboy/UI/LibraryItemView.swift` |
| D6 | Search | ✓ | `App/Sources/Videoboy/UI/LibraryBrowser.swift` |
| D7 | Background import job + contextual status bar (1,000 clips mid-show, 0 dropped) | ✓ | `App/Sources/Videoboy/UI/ImportJob.swift`, `App/Sources/Videoboy/Platform/ImportSelfQA.swift` |
| D8 | Import mode (⌘1): Devices / Locations, Add · Move · Copy, duplicates skipped, bin choice, J/K/L viewer, I/O marks | ✓ | `App/Sources/Videoboy/UI/ImportModeView.swift` |
| D9 | Copy + Optimize: linked optimized media (MPEG-2 GOP 6 on SD), playback prefers it | ✓ | `App/Sources/Videoboy/UI/OptimizeQueue.swift`, `docs/specs/0.4.10-copy-optimize.md` |
| D10 | Per-panel libraries (A/B and C/D) + central Asset Browser (Sources · Generators · Graphics · Clips · Images · EMU) | ✓ | `App/Sources/Videoboy/UI/LibraryPanelBody.swift` |
| D11 | Tags, smart bins, colour labels in use, energy fader | ✗ | planned 0.5.0 (`docs/PROPOSAL-2026-09-26.md` appendix A) |
| D12 | Saved Playlists and Setlists, Lists tab | ✗ | planned (`docs/PROPOSAL-2026-09-28-setlist.md`) |
| D13 | Catalog export to JSON | ✗ | proposed, not found in code |

## E. Mixing, cutting and transitions

| # | Feature | Status | Evidence |
|---|---|---|---|
| E1 | Three crossfaders: A↔B, C↔D, ONE↔TWO (custom DJ-style `VBFader`) | ✓ | `App/Sources/Videoboy/UI/VBFader.swift`, `Core/Sources/VideoboyCore/Modules/Mix/CrossfadeNode.swift` |
| E2 | CUT and FADE keys, beat-quantised, with their own rates | ✓ | `Core/Sources/VideoboyCore/Modules/Mix/FadeAutomation.swift` |
| E3 | Bus keys (A / B, C / D, 1 / 2) take a source to air | ✓ | `App/Sources/Videoboy/UI/VBBusButton.swift` |
| E4 | 13 blend modes (Normal … Soft Light) + Key | ✓ | `Core/Sources/VideoboyCore/Modules/Mix/BlendMode.swift` |
| E5 | 13 transition patterns: Dissolve, Wipe H/V, Slide H/V, Push H/V, Iris, Split H/V, Interlace H/V, AVE-5 | ✓ | `Core/Sources/VideoboyCore/Modules/Mix/Transition.swift` |
| E6 | Panasonic WJ-AVE5 wipe block (31 patterns, MULTI, border/soft edge, back colour, joystick) | ✓ | `Core/Sources/VideoboyCore/Modules/Mix/AVE5Wipe.swift`, `App/Sources/Videoboy/UI/AVE5WipePanel.swift` |
| E7 | Clip Pads: 8 launchers (1–4 A/B, 5–8 C/D), pre-opened, ⌥ load+play+cut, ⌥⌘ on the beat | ✓ | `Core/Sources/VideoboyCore/Control/ClipPadBank.swift`, `App/Sources/Videoboy/UI/ClipPadView.swift` |
| E8 | Hot Punch (!): pad press goes straight to Program | ✓ | `docs/specs/clip-pads.md`, `App/Sources/Videoboy/Platform/PadsSelfQA.swift` |
| E9 | Preview/Program (PVW/PGM) on separate buses with a take | ◐ | sub-mix monitors act as preview; there is no dedicated PVW bus or AUTO/TAKE pair |
| E10 | Soft-edge / border width on ordinary wipes | ✗ | `docs/BUILD-PLAN.md` ("Not yet") |
| E11 | Layer mask, picture-in-picture box, split screen as a layer | ✗ | Layer Mask in backlog; AVE-5 P-IN-P drawn disabled |
| E12 | Upstream/downstream keyers as separate layers (DSK) | ✗ | only the Key blend mode on a fader |
| E13 | Per-source crop, anchor point and a visible opacity fader | ✗ | layer opacity `66A` exists with no fader (`Core/Sources/VideoboyCore/Control/ParamCode.swift`); Transform has no crop |

## F. Effects

| # | Feature | Status | Evidence |
|---|---|---|---|
| F1 | Datamosh · H.264 (live I-frame removal, P-frame bloom, MOSH hold, HEAL with shapes, heal on the beat) | ✓ | `Core/Sources/VideoboyCore/Modules/Effects/DatamoshNode.swift`, `docs/DATAMOSH.md` |
| F2 | Composite · NTSC (encode→decode, dot crawl, chroma bleed, TBC wobble, head switching, generation loss, S-Video path) | ✓ | `Core/Sources/VideoboyCore/Modules/Effects/CompositeCodecNode.swift` |
| F3 | Feedback (frame delay, gain, zoom, rotate, luma key) | ✓ | `Core/Sources/VideoboyCore/Modules/Effects/FeedbackNode.swift` |
| F4 | Freeze (hold) | ✓ | `Core/Sources/VideoboyCore/Modules/Effects/FreezeNode.swift` |
| F5 | Echo / Trails | ✓ | `App/Resources/ISF/Builtin/Echo.fs` |
| F6 | Transform: scale, position X/Y, rotation, flip H/V (no crop, anchor or 3-D rotation) | ✓ | `App/Resources/ISF/Builtin/Transform.fs` |
| F7 | Colour: brightness, contrast, saturation, shadow, highlight, black, white, gamma | ✓ | `App/Resources/ISF/Builtin/Colour.fs` |
| F8 | ISF import: any ISF effect/generator dropped in becomes a card (shared + app folders) | ✓ | `Core/Sources/VideoboyCore/Modules/Effects/ISF`, `App/Sources/Videoboy/UI/ISFModuleListView.swift` |
| F9 | Effect chain per FX panel, reorderable cards (Photoshop-layer order), one A · B · MIX focus | ✓ | `App/Sources/Videoboy/UI/EffectChainPanelBody.swift`, `App/Sources/Videoboy/Platform/FXFocusSelfQA.swift` |
| F10 | MPEG bitstream corruptor (the wedge's damage card) | ⚑ | built and tested; `bitstreamCorruptor` flag OFF by owner decision |
| F11 | NTSC output emulation toggle on the output bar | ⚑ | `outputSignalEmulation` flag OFF |
| F12 | FFGL plug-ins, Core Image / AU passthrough | ✗ | `docs/SPEC.md` §8–9, not started |
| F13 | Macroblock-level motion-vector editing on MPEG-2 | ✗ | deferred (`docs/BUILD-PLAN.md`) |
| F14 | Per-effect presets / effect snapshots | ◐ | whole-show save works; single-chain preset keys still open |

## G. Modulation, automation and the clock

| # | Feature | Status | Evidence |
|---|---|---|---|
| G1 | Transport: BPM, play/stop, phase, subdivisions (1/1 … 1/16, dotted, triplet) | ✓ | `Core/Sources/VideoboyCore/Clock/Transport.swift` |
| G2 | Latency compensation (schedule at T − latency), unit-tested | ✓ | `Core/Sources/VideoboyCore/Clock` |
| G3 | Tap tempo | ✓ | `App/Sources/Videoboy/UI/VBTempoField.swift` |
| G4 | Beat detection with BeatNet (ported network) from system audio, an audio input, or ONE app's audio (Core Audio process taps) | ✓ | `Core/Sources/VideoboyCore/Audio/BeatNet`, `App/Sources/Videoboy/Platform/SystemAudioTap.swift`, `docs/BEATNET.md` |
| G5 | LFO on any effect parameter: 7 shapes, subdivision or free Hz, depth, phase, polarity, invert | ✓ | `Core/Sources/VideoboyCore/Clock/LFO.swift` |
| G6 | Audio-reactivity bus (RMS, bands, onsets) → any effect parameter | ✓ | `Core/Sources/VideoboyCore/Audio/AudioReactivityBus.swift` |
| G7 | ⌥⌘ beat sweeps on faders and parameters (automation sampled at presentation time) | ✓ | `Core/Sources/VideoboyCore/Control/ParameterSweep.swift`, `App/Sources/Videoboy/Platform/PushFadeSelfQA.swift` |
| G8 | Driven-parameter marks (outline breathes on the beat) | ✓ | `docs/DESIGN-BACKLOG.md` "Done in this pass" |
| G9 | Manual BPM entry, ×2 / ÷2, downbeat ("one") finding, nudge/offset | ◐ | tempo field present; ×2/÷2 and bar-finding not built (`docs/BUILD-PLAN.md`) |
| G10 | MIDI clock in/out, Ableton Link | ✗ | removed from CLOCK as unbuilt (`App/Sources/Videoboy/Render/Engine.swift` comment) |
| G11 | Timeline / cue-list automation (record a performance, play it back) | ✗ | — |
| G12 | Calibrated feedback latency (measured 3 frames / 100 ms) | ◐ | `Core/Sources/VideoboyCore/Modules/Effects/FeedbackLatencyCalibrator.swift`; measured, not applied |
| G13 | Timecode sync (SMPTE LTC / MTC) | ✗ | no implementation; TC is shown and burned in, not followed |
| G14 | Sync to DJ hardware (Pro DJ Link / StageLinQ) | ✗ | song linking to Apple Music is planned instead (`docs/PROPOSAL-2026-09-28-setlist.md` §6) |

## H. Control

| # | Feature | Status | Evidence |
|---|---|---|---|
| H1 | Core MIDI in: Note, CC, pitch bend; any velocity counts as a press | ✓ | `Core/Sources/VideoboyCore/Control/MIDIInput.swift` |
| H2 | Shift-to-detect MIDI learn on every enabled control; Esc cancels, ⌫ unmaps | ✓ | `App/Sources/Videoboy/UI/DetectSession.swift`, `App/Sources/Videoboy/Platform/UndoSelfQA.swift` |
| H3 | MIDI mapping pane (remove one at a time) | ✓ | `App/Sources/Videoboy/UI/PreferencePanes.swift` |
| H4 | Every beat-rate key follows one rule (click faster, right-click slower) — 93 keys | ✓ | `App/Sources/Videoboy/UI/VBStepButton.swift` |
| H5 | Hot keys pane; number keys fire pads | ✓ | `App/Sources/Videoboy/UI/PreferencePanes.swift` |
| H6 | 14-bit CC, NRPN, MIDI out (LED feedback to controllers), controller templates/fingerprinting | ✗ | `docs/STATUS.md` §7 |
| H7 | OSC in/out | ✗ | status bar reads "OSC: off"; no implementation |
| H8 | Undo / redo (general) | ✗ | no `NSUndoManager`; targeted take-backs only (`App/Sources/Videoboy/Platform/UndoSelfQA.swift`) |
| H9 | Macros & AI control | ✗ | Settings pane reads "Not built yet" (`App/Sources/Videoboy/UI/PreferencePanes.swift`) |

## I. Output, monitoring and scopes

| # | Feature | Status | Evidence |
|---|---|---|---|
| I1 | Borderless output window on any display, mode negotiated and logged | ✓ | `docs/SPEC.md` §3, `App/Sources/Videoboy/Platform/OutputSelfQA.swift` |
| I2 | Send glyph under every preview: route Program / ONE / TWO / any source to a display; four-up tiled send | ✓ | `App/Sources/Videoboy/UI/RoutingPopover.swift` |
| I3 | Previews for all 4 sources, both sub-mixes and Program | ✓ | `docs/mockups/layout-v6.html`, `selfqa/out/perf/pads/window.png` |
| I4 | Scopes: waveform, RGB parade, histogram, vectorscope, mini luma; OVER (overlay) and L3 | ✓ | `Core/Sources/VideoboyCore/Scopes` |
| I5 | NTSC legality (7.5–100 IRE) reporting | ✓ | `docs/DESIGN-BACKLOG.md` |
| I6 | FILE / TC overlays and DATA BURN (burned-in timecode/file data) | ✓ | `selfqa/out/phase-2/ui-layout/data-burn-program.png` |
| I7 | Safe zones, overscan (on/off), BFI, test pattern to output | ✓ | `App/Sources/Videoboy/UI/SettingsBarPanelBody.swift` |
| I8 | Multiviewer with tally colours | ◐ | the grid is a multiviewer; red outline on the on-air monitors; no tally out |
| I9 | Projection mapping, edge blending, multi-projector warp | ✗ | out of scope by design |
| I10 | Syphon / NDI / virtual camera out | ✗ | optional backlog item |
| I11 | Overscan as a continuous control | ✗ | `docs/BUILD-PLAN.md` |

## J. Recording and streaming

| # | Feature | Status | Evidence |
|---|---|---|---|
| J1 | Record Program and discrete A/B/C/D together, one folder per take | ✓ | `App/Sources/Videoboy/Platform/RecordingSession.swift` |
| J2 | Codecs: ProRes 422, ProRes HQ, ProRes 4444, H.264, HEVC | ✓ | `App/Sources/Videoboy/Platform/FrameRecorder.swift` |
| J3 | Stream to OBS: MPEG-TS over UDP, nothing to install | ✓ | `Core/Sources/VideoboyCore/Bitstream/MPEGTSStreamer.swift` |
| J4 | RTMP / SRT / NDI streaming | ✗ | — |
| J5 | Recording audio with the picture | ✗ | the app outputs no audio |
| J6 | Encoding off the main thread for recording/streaming | ◐ | audit F7/F8 open (`docs/FEATURE-LEDGER-2026-09-27.md`) |

## K. Shows, settings and modes

| # | Feature | Status | Evidence |
|---|---|---|---|
| K1 | Show files (`.vbt`, plain-text JSON, template v5): New / Open / Open Recent / Save / Save As, auto-save, save-on-quit | ✓ | `Core/Sources/VideoboyCore/Persistence/TemplateDocument.swift`, `App/Sources/Videoboy/Platform/TemplateSelfQA.swift` |
| K2 | Mode bar: ⌘1 Import · ⌘2 VJ · ⌘3 Settings (switching never interrupts output) | ✓ | `App/Sources/Videoboy/UI/AppMode.swift`, `App/Sources/Videoboy/UI/ModeController.swift` |
| K3 | Settings mode, 13 panes: Project, Media, Optimize, Save, Defaults, Outputs, Data Burn, Sources, Hot Keys, MIDI Mapping, EMU, Macros & AI, Shaders | ✓ | `App/Sources/Videoboy/UI/PreferencePanes.swift`, `selfqa/out/phase-2/ui-layout/preferences-*.png` |
| K4 | Setup assistant (locations, project, optimize) | ✓ | `App/Sources/Videoboy/UI/SetupAssistant.swift` |
| K5 | Panels collapse to rails; width-reactive at three breakpoints; fixed docked grid | ✓ | `App/Sources/Videoboy/UI/CollapsedRailView.swift`, `selfqa/out/phase-2/ui-layout/compact.png` |
| K6 | "Don't remind me again" suppressions, resettable | ✓ | `App/Sources/Videoboy/UI/ReminderAlert.swift` |
| K7 | Simple mode (A/B only) | ✗ | `docs/STATUS.md` §2 |
| K8 | LOCK per bank | ✗ | planned (setlist proposal §7) |

## Totals

| Status | Count |
|---|---|
| ✓ shipped | 85 |
| ◐ partial | 10 |
| ⚑ built, flag off | 2 |
| ✗ not built | 33 |
| **rows** | **130** |

(Counted mechanically from the tables above — see §R. A first hand count was wrong
and was replaced by this one.)

## §R — re-check

All 119 path-like references above were tested for existence on 2026-10-01
(`[ -e path ]` per path, globs expanded): every evidence path resolves. The status
counts are `grep -c` over the table rows, not a hand tally. The command is in
`docs/research/2026-10-01/README.md`.
