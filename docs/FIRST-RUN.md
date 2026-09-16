# FIRST-RUN.md

Your first sit-down with Videoboy. What to click, what works, what doesn't.

## Launch it

```sh
scripts/build.sh      # builds Core, the app, and assembles Videoboy.app
scripts/run.sh        # launches it, with logs in your terminal
```

The app is unsigned and ad-hoc signed, as intended — no Apple Developer Program, no
notarization. If macOS objects, right-click `build/Videoboy.app` ▸ Open once.

Run `scripts/bootstrap.sh` first on a fresh clone: it generates the sample fixtures
and copies `config/devices.example.json` to `config/devices.json`.

## What you'll see

The full canonical layout from SPEC §14 — the 5×5 grid, every panel present:

```
 SOURCE A │ SUB MIX ONE │  PROGRAM   │ SUB MIX TWO │ SOURCE C
 SOURCE B │  (preview)  │  PREVIEW   │  (preview)  │ SOURCE D
 SUB MIX  │  A→B FADER  │ ONE→TWO F. │  C→D FADER  │ SUB MIX
   1 FX   ├─────────────┼────────────┼─────────────┤   2 FX
  (tall)  │ SM1 LIBRARY │ ASSET BROW │ SM2 LIBRARY │  (tall)
          │──── RECORD / STREAM / OUTPUT / TOGGLES ────│
```

Panels collapse by clicking their header. They never move — that's deliberate.
Resize the window narrower and the outer columns collapse to rails, then disappear.

Source A sits directly on B, and C on D, sharing a hairline rather than floating
apart: they feed the same bus and are never used separately. Recording lives at the
**top right** — the big red button — not in the bottom bar.

Every continuous control is a custom fader with a thick track, a fill showing travel,
and a cap that overhangs the slot like a DJ fader. Effect parameters take two lines so
the fader gets the full panel width; drag the **three-dash grip** on an effect card to
reorder the chain, which reads like Photoshop layers — the top card is applied last,
so it is what you see on top.

## What actually works

**Play a DV file.** Click **Load…** on Source A, pick `samples/motion.dv`, then press
**▶** on that panel's shuttle strip. It plays in the panel preview, through Sub Mix
One, into Program Preview.

**The wedge — this is the point.** In the **Sub Mix 1 FX** panel, the *DV · DIF
corruptor* card is live:

| Slider | Code | What it does |
|---|---|---|
| amount | `31B` | how much of the frame gets damaged |
| mode | `32B` | which damage: shuffle / duplicate / drop blocks, flip DCT coefficients, swap sequences, hold sequences |
| rate | `33B` | how often the damage re-rolls, in beat subdivisions |

Push **amount** up and the picture breaks apart. This is happening on the *compressed
DV bitstream before it is decoded* — libav is decoding genuinely damaged DIF blocks.
It is not a shader pretending. `mode` at the far left is block shuffle; drop is the
classic DV dropout look.

**The analog chain.** Below the corruptor in **Sub Mix 1 FX** are three effects that
start switched **off** — flick their switches on:

- **Composite · NTSC** — the reason the app exists. It encodes the picture to an NTSC
  composite waveform and decodes it back, so dot crawl, rainbowing and chroma bleed
  come out of the process rather than being drawn on. `path` toggles composite vs
  S-Video (S-Video is visibly cleaner because Y and C never share a wire). `wobble`
  and `head sw` are TBC-off jitter and the head-switching tear at the bottom. `gen`
  runs the codec repeatedly for an Nth-generation dub.
- **Echo / Trails** — frame-history trails with a luma key, so only bright things tail.
- **Feedback** — the infinite tunnel. `zoom` just above centre pushes the image inward.

**Generators.** Each source panel has a popup next to **Load…** listing twelve
synthetic sources — plasma, checkerboard, noise fields, gradients, halftone,
scanlines and the rest. Pick one and that channel switches from its file to the
generator, with a slow transport-locked ramp already driving its phase so it moves
on the bar rather than sitting still.

**Blend modes.** Sub Mix One, Sub Mix Two and Program Preview each carry a blend
popup and a layer-opacity slider — all thirteen Photoshop-style modes. The blend and
the fader are independent, so "screen at 40% opacity with the fader at 70%" is a
thing you can set.

**The audio clock.** Set **Clock** to **Audio** in the toolbar and Videoboy listens
to the default input, estimates tempo by autocorrelating the onset envelope, and
drives the transport from it. The **Sync** readout shows detection confidence; below
25% it ignores the estimate rather than dragging the tempo around on speech or
applause. It will ask for microphone access the first time.

**Modulating anything.** Every parameter row in the FX panels has three little
letters beside it — **M S C**. They are buttons:

- **M** — MIDI learn. Click it, then move a control on your deck.
- **S** — audio. Pick a tap and a shape: *Level (envelope)*, *Onset (pulse)*, *Bass*,
  *Treble*, or anything under **More…** with full control of the shaping. Needs the
  clock set to Audio to actually move.
- **C** — an LFO. Pick a shape, then a rate as a clock subdivision (so it stays
  musical) or a free-running Hz.

A lit letter means that parameter is being driven. This is where it stops being a
video player and becomes an instrument — put a pulse on the corruptor's amount and
the picture breaks on the kick.

**The faders.** A→B, C→D and ONE→TWO all work, with **Cut** (and **◆ Swap** on
ONE→TWO). Drag them and Program Preview follows.

**The transport.** Tempo, **Tap** (tap four times), and **▶** start the musical clock.
With it running, the corruptor re-rolls its seed on every quarter note — the damage
changes *on the beat*, latency-compensated so the visible change lands on time.

**MIDI.** Any connected MIDI device is picked up at launch; the status bar names it.
Mappings target param codes, so swapping a module keeps them.

**The CRT toggles.** In the bottom bar: **Safe** draws the action-safe and title-safe
rectangles over every preview, **Overscan** shows what a tube would actually cut off,
and **BFI** inserts black frames on a clock.

**Output.** The **Test Pat** switch in the bottom bar opens a borderless output window
on the display named in `config/devices.json` (`MACROSILICON` here) and sends PROGRAM
to it. Switch it off to close it and restore the display.

## What's visible but deliberately dead

Present, greyed, labelled — never hidden, so the shape of the app is legible:

- **Color Ctrl** and **Layer Mask** — the MX-1 effect set and the Core Image
  passthrough from SPEC §9 are not written yet.
- **Record** — Phase 4. The **Stream** readout is live (see below).
- **Modulation assignment is on the FX parameters only.** The badge columns on the
  faders and shuttles are still decorative.
- **MX-1 effects** (negative, B&W, mosaic, posterize, mirror, flip, freeze) are built
  and tested but not yet placed in a chain, so they have no controls.
- Asset Browser tabs, search, import, and the drag-to-load flow.
- Clock sources other than Internal (audio detection, MIDI clock, Link).
- **⇧ Learn** button: MIDI learn works in Core and is tested, but the shift-to-highlight
  UI affordance isn't wired to the button yet.
- Source C and D load and play, but only A and B reach PROGRAM through ONE.

## Known rough edges

- **Only `.dv` files play.** Choosing anything else tells you so. The AVFoundation
  path for ordinary formats isn't wired up — the DV bitstream path was the priority.
- **The FX panel text truncates** in the outer columns at narrow window widths.
- **The output display won't switch to 720x480.** macOS refuses the mode; see
  `docs/BLOCKED.md` §2. The program is scaled into the card's current mode instead,
  and the app logs exactly what it negotiated rather than guessing. The analog chain
  still works — the loopback proves it — this only affects pixel-exactness.
- **The DVC100 is on S-Video, not composite**, on this rig. `config/devices.json`
  records it. Reading the wrong connector returns a valid, perfectly black picture.
- **Only one process can hold the DVC100** — quit `DVC100.app` before the loopback.
- **Sub Mix 1 FX drives Source A only.** Per-channel FX chains come later. The three
  bus effects act on the whole ONE bus, which is correct; the corruptor is per-source
  because it has to run before decode.
- **External feedback is not routed yet.** The loop's round trip is measured and the
  node accepts a captured frame as its history, but capture is not wired into that
  input live. Internal feedback works.
- The settings bar panel carries an "Output" header the mockup doesn't have.

## Verifying it yourself

```sh
scripts/verify.sh              # build + test + lint, must exit 0
scripts/selfqa.sh offscreen    # render checks, no hardware
scripts/selfqa.sh loopback     # DVC100 analog capture (quit DVC100.app first)
./build/Videoboy.app/Contents/MacOS/Videoboy --selfqa ui        # layout at 3 widths
./build/Videoboy.app/Contents/MacOS/Videoboy --selfqa playback  # the live graph
scripts/selfqa.sh analog       # composite codec, echo and feedback, no hardware
scripts/selfqa.sh calibrate    # measure the real feedback round trip (needs hardware)
./build/Videoboy.app/Contents/MacOS/Videoboy --selfqa output    # the HDMI output stage
```

Evidence lands in `selfqa/out/<phase>/` — PNGs plus a `result.txt` for each check.
The interesting ones to look at:

- `selfqa/out/phase-1/dv-corruption/` — one PNG per corruption mode. This is the wedge.
- `selfqa/out/phase-2/beat-synced-corruption/` — one PNG per beat, same source frame.
- `selfqa/out/phase-2/playback/` — the fader sweeping A to B through the real graph.
- `selfqa/out/phase-2/ui-layout/` — the shell at wide, compact and narrow.
- `selfqa/out/phase-3/composite-codec/` — the NTSC codec, clean through to 4th
  generation and TBC-off wobble.
- `selfqa/out/phase-3/feedback-latency/` — the marker frame going out and coming back;
  the physical loop measures **3 frames / 100 ms** on this rig.
- `selfqa/out/phase-2/loopback/` — **the real analog signal**, captured back off the
  DVC100 after going out the HDMI card and through the HDMI-to-RCA converter.
  30.000 fps, 0 dropped frames, 720x480, all six colour bars recovered.

## Read next

- `docs/BLOCKED.md` — the three things needing you, one of which is a single action.
- `docs/ARCHITECTURE.md` — the graph, the two clocks, the one extension point.
- `docs/ADD-A-MODULE.md` — how to add a source or effect.


## Sending Videoboy into OBS

Videoboy publishes MPEG-TS over UDP, which OBS reads with its own Media Source. There
is nothing to install on either side.

1. In Videoboy, open **Settings › Outputs** (⌘,) and press **+**. Set **Kind** to
   **OBS** and **Target** to `9000`. A bare port means localhost — sending video off
   this machine has to be typed in deliberately, as `host:port`.
2. Click the send glyph under any preview and choose the destination you just made.
   The **Stream** readout in the Output bar shows the target and the frame count.
3. In OBS, add a **Media Source**, untick **Local File**, and set **Input** to
   `udp://127.0.0.1:9000`. Set **Input Format** to `mpegts`.

Tips:

- Untick **Restart playback when source becomes active** in OBS, or it will drop the
  stream every time you switch scenes.
- A keyframe goes out twice a second, so OBS shows a picture within about half a
  second of being pointed at the stream.
- Encoding costs about 7 ms a frame against a 33 ms budget at SD, so it keeps up
  comfortably — but it is real CPU work and only runs while something is routed.

## Sending previews to a display

Every preview has a send glyph in its bottom-right corner. It lists every display
attached to the machine plus anything defined in Settings › Outputs. The display
Videoboy is running on is listed but greyed: a borderless output window there would
cover the controls with no way back.

Right-click the glyph under **Program Preview** for the **four-up preview**, which
tiles all four sources onto one screen.
