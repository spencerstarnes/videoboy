# TODO.md

What works, what doesn't, and what's next.

Generated against the control audit: `scripts/selfqa.sh audit` walks the built
window, finds every control, and reports whether it is enabled and wired. Re-run it
after any UI change — it is the authority, not this list's prose.

**Current: 447 controls — 198 live, 249 disabled, 0 enabled-but-unwired.**

"Enabled but unwired" is the dangerous state: a control that looks usable and does
nothing. The audit fails the build if any appear. Everything not built is *disabled*,
which is honest.

---

## Works now — safe to lean on in a session

| Area | What |
|---|---|
| **The wedge** | DV DIF corruptor: 6 modes, amount/mode/rate/seed, on the beat |
| **Playback** | Load a `.dv`, play, loop / ping-pong / one-shot, scrub, step, jump to ends |
| **Mixing** | A→B, C→D, ONE→TWO faders; Cut; Swap; all 13 blend modes |
| **Analog chain** | NTSC composite codec, echo/trails, feedback tunnel — on both buses |
| **Generators** | 12 synthetic sources, assignable to any channel, LFO on phase |
| **Clock** | Tempo, tap, play, subdivision; audio beat detection |
| **Modulation** | M/S/C badges on every FX parameter: MIDI learn, audio taps, LFOs |
| **CRT** | Safe zones, overscan, BFI, test pattern (routed through the graph) |
| **Output** | Borderless window on the HDMI card, mode negotiated and logged |
| **Panels** | Four collapsible groups, Resolve-style, folding to labelled rails |
| **Record** | Arming per feed (A/B/C/D/1/2/P) with transport-locked pulse |

---

## Disabled and labelled — present, inert, waiting on their feature

### Needs real work

- **Record / Stream encoders** (SPEC §15). Arming and the indicators are real; there
  is no `AVAssetWriter` behind them. Pressing record says so.
- **Asset Browser**: tabs, search, import, grid/list. The grid renders from
  `samples/manifest.json`; nothing filters or imports.
- **Library page / search** on both sub-mix libraries.
- **Load Asset / Save** on the FX chains — effect-chain presets.
- **Effect ✕ (remove)** and the per-effect enable switch on unbuilt effects.
- **⇧ Learn** button — MIDI learn works from the M badges; the toolbar button and the
  hold-Shift highlight of mappable controls are not wired.
- **Fader Fade / Auto / Beat** — timed crossfades and cut-on-beat. The scheduler
  exists; the mixer is not subscribed to it.
- **Non-DV playback.** Only `.dv` plays. See "Open questions" below.

### Deliberately deferred (Phase 4+ backlog)

ISF/FFGL host · Core Image passthrough · Core Text titler · libretro titler
(GPL, out-of-process) · NTSC scopes · SVG/PS1 source · IP in/out · Syphon ·
routing/send panel · MIDI clock and Ableton Link as clock sources.

---

## Known limitations

- **macOS refuses the HDMI card's 720×480 mode** (`isUsableForDesktopGUI` is false).
  The program is scaled into the card's current mode and the negotiated mode is
  logged, never guessed. The analog chain still works — the loopback proves it.
- **The DVC100 is on S-Video, not composite**, on this rig. Recorded in
  `config/devices.json`. The wrong connector returns a valid, perfectly *black*
  picture, which looks exactly like a dead output stage.
- **Only one process can hold the DVC100** — quit `DVC100.app` before the loopback.
- **Sample media is synthetic.** Real DV off tape has artefacts no encoder makes.
- **MX-1 effects** (negative, B&W, mosaic, posterize, mirror, flip, freeze) are built
  and tested but not placed in a chain, so they have no controls.
- **Generator colours** have no colour well.
- **Modulation assignment is on FX parameters only** — the badge columns on the
  faders and shuttles are decorative.

---

## Open questions being worked on

### 1. Data effects are codec-specific, and currently misplaced

The DIF corruptor only means anything for DV: it rewrites DIF blocks before decode.
For an MPEG-family file the equivalent transforms are different (drop P/B frames,
corrupt motion vectors, hold references). For a still image or a generator there is
no compressed bitstream at all and **nothing to offer**.

It is also in the wrong place in the interface. It runs on the *source* — correctly,
since it must happen before decode — but it is shown inside the Sub Mix 1 FX chain,
which implies it is a bus effect, and it only reaches source A.

**Direction:** a separate class of **data effect**, living in its own stack that
opens from the source panel. Closed by default; opening it shrinks the sub-mix FX
stack. Its contents follow the loaded media's codec — DV footage gets DV data
effects, MPEG gets MPEG ones, anything without a compressed bitstream makes the
stack vanish entirely. When footage is loaded that has data effects available, the
closed stack pulses once so the option is noticed.

### 2. Data effects on the bus

The same idea applies after mixing, but a bus does not have a codec — it is a
texture. To corrupt a *mix*, the bus has to be re-encoded first.

**This is feasible.** The vendored LGPL FFmpeg has the DV **encoder** compiled in
(verified), so the path is: mixed texture → read back → encode to DV → corrupt the
DIF bytes → decode → texture. Intra-frame, ~120 KB per frame, no GOP latency.

**Direction:** an **interchange codec** popup per bus — None / DV. Choosing DV
inserts the encode-corrupt-decode stage and populates that bus's data-effect stack
with the DV set. Choosing None removes both. MPEG interchange is the more
interesting one for datamosh and needs the encoder enabling in the FFmpeg build plus
handling of inter-frame latency; it is not done.

**Cost to be measured before this ships:** a readback plus encode plus decode per
frame, per bus. If it will not hold 29.97 it is not worth having, and the honest
answer may be that it runs on PROGRAM only.
