# Competitors, their inspectors, and what Videoboy is missing (2026-10-01)

Asked by the owner: *"Take a look at the big competitors of our app, look at their
inspectors specifically and see what major and minor features are absent from VB. … Don't
care so much about DMX control, but I want to make sure that all the stuff a VJ or a
theater visual designer or a video artist may want to play with."*

"Inspections" is read as **inspectors**: the panel where each app shows and edits the
properties of the selected clip, layer, cue or surface. That is where an app's real
feature set lives, so it is the fairest place to compare. DMX/lighting is left out as
asked. Videoboy facts come from `feature-inventory.md` (checked against the code);
competitor facts are from vendor documentation unless marked *secondary*.

---

## 1. The field

| Product | Who it's for | Platform | Price (Oct 2026) | Model | Source |
|---|---|---|---|---|---|
| **Resolume Avenue / Arena 7** | VJs, festivals, LED/mapping (Arena) | Mac, Win | €299 / €799, Wire €399; 1 yr updates, renew €79 / €219 | perpetual + renewals | vendor shop |
| **VDMX6 / VDMX6 Plus** | Mac VJs, video artists | Mac | $199 / $349 | perpetual | vendor |
| **Millumin 5** (Apr 2026) | theatre, dance, installations | Mac (+ MilluNode) | rent €29/7 d, €69/30 d, €199/yr; perpetual from €399 | both | vendor |
| **QLab 5** | theatre show control | Mac | free core; one feature set $599, two $1,099, all $1,399; or $8–15/day | both | *secondary* (Capterra); vendor shows tiers |
| **MadMapper 6** | mapping, LED, lasers | Mac, Win | free (watermark); from €39/mo; perpetual from €399 | both | vendor/CDM |
| **TouchDesigner** | generative, installations, interactive | Mac, Win | free non-commercial (1280×1280); $300 edu; $600 commercial; $2,200 pro | perpetual keys | vendor |
| **Isadora 4** | theatre, dance, interactive | Mac, Win | (not verified) | — | vendor features |
| **Synesthesia** | audio-reactive VJ | Mac, Win | $199 standard, $399 pro | perpetual | vendor |
| **Modul8 3** | classic Mac VJ | Mac | still sold, rarely updated | perpetual | *secondary* |
| **CoGe VJ** | — | — | **discontinued** (needed Quartz Composer) | — | vendor blog |
| **Serato Video** (in DJ Suite) | DJs | Mac, Win | DJ Suite $499 or $14.99/mo | both | vendor |
| **VirtualDJ** | DJs, karaoke, mobile | Mac, Win | Pro $19/mo (lifetime ~$299 *secondary*) | both | vendor |
| **rekordbox video** (Creative plan) | DJs | Mac, Win | ~$180/yr | subscription | *secondary* |
| **vMix** | streaming, live production | Win | $60–$1,200 lifetime; Max $50/mo | both | vendor |
| **Watchout 7 · disguise · Pixera · Smode · Notch** | large shows, media servers | Win (mostly) | ~€3,200 licence; $159/mo; free creator tiers; ~£99–189/mo | mixed | *secondary* |

Videoboy's own segment is unusual: **a Mac-native, four-source, two-bus live mixer for
SD/analog output, with live bitstream damage**. No product above covers that. The closest
in *workflow* are Resolume and VDMX (live mixing), in *output* none, and in *time
behaviour* the DJ tools.

---

## 2. Inspector by inspector

### Resolume — clip, layer and composition panels
- **Clip:** transport mode **Timeline / BPM Sync / SMPTE / Denon**; forward / back / pause;
  speed; **Loop, Ping Pong, Random, Play Once and Eject, Play Once and Hold**; in/out;
  **cue points**; **Beat Looper** (BPM Sync); **Beat Snap** (beat, bar, 2 or 4 bars);
  **trigger style Normal / Toggle / Piano**; **Fader Start**; clip target (own / active /
  free layer); **Auto Pilot** (next, previous, random, first, last, a chosen clip) after
  N loops; a **per-clip transition**; resize Fill / Fit / Stretch / Original; clip
  properties (codec, fps, length, BPM); audio volume / pan; opacity, size, blend,
  alpha and RGB toggles.
- **Layer:** blend, opacity, size, auto size, master, audio, auto pilot, transport,
  **mask mode** (all below / one below), **lock content**, solo, bypass, eject, and a
  **layer transition (type + 0–10 s)**.
- **Around them:** dashboard knobs, **envelopes**, parameter animation, **undo**, a
  **notes panel**, a **clip time panel** (remaining time), **LUTs**, recording, 10-bit
  output, **Ableton Link, MIDI clock, SMPTE, Denon and Pioneer sync** (the last three
  Arena-only), OSC, REST/WebSocket APIs and an **MCP server** for AI control, Wire (node
  patching, ISF, FFT). **No automatic BPM detection**: the BPM page tells you to tap.

### VDMX6 — workspace inspector (layer = source + FX chain + composition)
- **Source:** movie controls (time, rate, volume, loop mode, range), cameras, capture
  boxes, **NDI and Syphon in**, ISF / Quartz Composer / FFGL / Vuo / **TouchDesigner**
  generators, text.
- **FX chain:** Core Image, QC, FFGL, ISF; **shape, chroma and layer masks**; vision FX
  (**remove background, blur faces, face overlay, colour transfer**).
- **Composition:** 20+ blend modes and transitions, opacity, **crop**, **size and position
  as a rect or a quad (perspective) map**.
- **Plugins** (each is its own inspector): LFO, **step sequencer**, **audio analysis with
  BPM detection**, two-channel mixer, preview windows, movie recorder, **face / body /
  hand tracking**, OCR / QR. MIDI, OSC, DMX, Art-Net; **LTC/MTC timecode**; **HAP**;
  Syphon and NDI out.

### Millumin 5 — properties of a layer in a column or timeline
- Media (video, image, audio, **NDI, Syphon, screen, web, dynamic text**, TouchDesigner
  TOX); **mesh warping, masks at every level, soft-edge**, output warping; **layer
  groups** with blend / opacity / effects; **custom and shader transitions**; **Bezier
  keyframes on timelines**; **cues** that recall a time; **Auto States**; **JavaScript**;
  MIDI, OSC, timecode in and **timecode generation**; controls ATEM, PJ-Link projectors
  and PTZ cameras; 5.1 / 7.1 audio; HDR and 10-bit; up to 16K.

### QLab 5 — the cue inspector
- **Basics** (name, number, target, waits, continue), **Triggers** (hotkey, MIDI,
  timecode, wall clock), **I/O**, **Geometry** (fit / fill / stretch, opacity, layer; or
  custom **crop, translation, scale, 3-D rotation X/Y/Z, anchor**), **Time & Loops**
  (start / end, loops, rate, **hold at end**), **Video FX** (blend mode + a stack of live
  effects), audio tabs. Plus **fade cues** for any of those values, **text cues**,
  **camera cues**, **network (OSC) cues**, group cues, and the GO button.

### MadMapper 6 — surface and media inspectors
- Surfaces: quads, triangles, circles, masks, **unlimited-point Bezier mesh warp**,
  **soft-edge**; media and ISF-based **Materials** (with a Mad AI text-to-material
  option); a text generator; **Timelines** replacing cues (keyframes with Bezier-to-flat
  interpolation, an audio track with **FFT**, **beat tracking**, **markers**, **MIDI/OSC
  output tracks**, export to a video file); MIDI, OSC, MTC/LTC.

### TouchDesigner — the parameter dialog
Every operator exposes every parameter, each of which can be an expression, an export
or a reference. Unlimited by design; the cost is that the show is a program.

### Isadora 4 — actors and scenes
Scenes as show states; each actor's inspector exposes its inputs; **MIDI Show Control and
MTC**, projection mapping, OSC / MIDI / serial / TCP / PJ-Link, **IzzyCast** (remote
video), VST hosting, **Python**.

### Synesthesia — scene controls
Audio-reactive shader scenes with mapped controls; media and webcam inputs; **ISF and
Shadertoy import**; live coding; Pro adds **Syphon / Spout / NDI and OSC**.

### Videoboy — where its "inspector" lives
Videoboy has **no single inspector**. Properties live on the surface where they act:
**Source Controls** (the focused source's speed, scrub and generator parameters, at the
top of each FX panel), **effect cards** (each parameter on two lines with MIDI / AUD /
LFO badges and its param code), the **transition and blend keys** (with the AVE-5 popover),
and **Settings** mode. This is closer to a hardware mixer or Resolume's in-panel
parameters than to QLab's or Resolve's single inspector, and it suits live hands. What it
lacks is the *geometry and compositing* half that every other inspector has (below).

---

## 3. What is absent from Videoboy

### 3.1 Major — essential for at least one of the three audiences

| # | Missing | Who has it | VJ | Theatre | Video artist | Notes for Videoboy |
|---|---|---|---|---|---|---|
| M1 | **Cue points / hot cues inside a clip** | Resolume, QLab (start/end per cue), Millumin, MadMapper markers, all DJ apps | ● | ● | ● | deep dive §5.1; one in/out per clip today |
| M2 | **A cue list or timeline with GO** (numbered cues, fades over time, auto-follow) | QLab, Millumin, MadMapper, Isadora, VDMX cue list | ○ | ● | ◐ | Setlists + a rundown view cover part; theatre needs GO and timed fades |
| M3 | **Masks** (shape, chroma, layer masks) | VDMX, Resolume, Millumin, MadMapper, QLab | ● | ● | ● | Key blend only; Layer Mask is in the backlog |
| M4 | **Inter-app video: Syphon in/out, NDI in/out** | Resolume, VDMX, Millumin, MadMapper, Synesthesia Pro, QLab Video, TouchDesigner | ● | ● | ● | backlog item; Syphon out is the cheapest high-value step |
| M5 | **OSC in/out** | everyone | ● | ● | ● | status bar already says "OSC: off"; the ControlEvent bus was designed for it |
| M6 | **Tempo sync with other software: MIDI clock, Ableton Link** | Resolume, TouchDesigner, MadMapper (beat tracking), most DJ apps | ● | ○ | ◐ | removed from CLOCK as unbuilt; deep dive §5.6 |
| M7 | **Timecode (SMPTE LTC / MTC)** | Resolume Arena, VDMX, MadMapper, Millumin, Isadora, QLab | ○ | ● | ◐ | theatre and broadcast sync to a clock, not a beat |
| M8 | **Undo / redo** | Resolume (Undo), every editor | ● | ● | ● | only targeted take-backs today |
| M9 | **Per-source geometry and compositing in one place**: crop, anchor, opacity fader, position/scale with keyframes | QLab Geometry, VDMX composition, Resolume, Millumin | ◐ | ● | ● | Transform card has scale/position/rotation/flip; no crop, anchor or visible per-source opacity (66A has no fader) |
| M10 | **Text and titles as a first-class, editable source** | Resolume text, VDMX text, Millumin dynamic text, QLab text cue, MadMapper text | ◐ | ● | ◐ | Core Text CG node exists but is not reachable; Now Playing and the Scala titler are |
| M11 | **Presets and snapshots** for effects, transitions and whole layers | Resolume, VDMX (everywhere), MadMapper scenes, Millumin Auto States | ● | ● | ● | single-chain preset keys still open; Setlists/E-MEM idea covers banks |
| M12 | **A performance codec with alpha (HAP, DXV)** | VDMX (HAP), Resolume (DXV), Millumin, MadMapper | ● | ◐ | ● | Videoboy optimizes to MPEG-2 for the wedge — right for its core, but alpha overlays need a second path |

● essential · ◐ useful · ○ rarely needed

### 3.2 Minor — expected by someone, not a reason to choose another app

| # | Missing | Who has it | Notes |
|---|---|---|---|
| m1 | Trigger styles on pads: **momentary (piano) and toggle** | Resolume | Clip Pads fire on press only |
| m2 | **Random / shuffle** play and autopilot after N loops | Resolume | beat shuffle is planned in 0.5.0 tags |
| m3 | **Reverse key** and scratch on a source | Resolume, DJ apps | reverse only via Ping-Pong |
| m4 | **Envelopes / keyframed parameter curves** | Resolume envelopes, Millumin, MadMapper | LFOs and beat sweeps exist |
| m5 | **More blend modes** (VDMX lists 20+ blend modes and transitions) | VDMX, Resolume | 13 + Key today |
| m6 | **LUTs** | Resolume | Colour card covers basic grading |
| m7 | **Notes panel, remaining-time clock** for scripted shows | Resolume | TC overlay exists; no countdown |
| m8 | **Scripting / API** (JavaScript, Python, REST, MCP) | Millumin, Isadora, TouchDesigner, Resolume | Settings ▸ Macros & AI reads "Not built yet" |
| m9 | **Vision features**: background removal, face/body/hand tracking, object masks | VDMX, Premiere (Object Mask) | trendy; not core |
| m10 | **Web / HTML / slide sources** | Millumin (web), vMix (PowerPoint) | — |
| m11 | **Projector control** (PJ-Link), ATEM control, Stream Deck / Companion | Millumin, Isadora | follows OSC (M5) |
| m12 | **10-bit / HDR output** | Resolume, Millumin | SD-first app; matters only on other canvases |
| m13 | **Multi-output mapping**: warping, edge blending, slices | Resolume Arena, MadMapper, Millumin, QLab Video | out of scope by design (SPEC), listed for completeness |
| m14 | **Audio playback with the picture** | QLab, Millumin, Resolume, VDMX | **deliberately excluded** (SPEC §21: the app is silent) |
| m15 | **3-D, particles, generative scenes** | TouchDesigner, Notch, Smode, Synesthesia | not this product |

### 3.3 Where Videoboy is ahead of all of them

| Videoboy | Nearest competitor |
|---|---|
| **Live datamosh on a real H.264 bitstream** (MOSH / HEAL / bloom, beat-timed) | none live; offline tools only |
| **NTSC composite signal model** (dot crawl, chroma bleed, TBC wobble, generation loss) | shader approximations in ISF packs |
| **AVE-5 wipe block emulated from the manual** (31 patterns, MULTI, edge, joystick) | none |
| **Real vintage titler (Scala MM400 on Amiberry) as a live source** | none |
| **Automatic beat detection with a neural tracker (BeatNet), from any app's audio** | VDMX detects BPM; Synesthesia analyses audio for beat-synced scenes; Resolume does not detect (tap / Link / DJ sync) |
| **Discrete ISO recording of Program + A/B/C/D in one take** | ATEM ISO hardware; most VJ apps record one output |
| **Lightroom-style import and catalog** (Add / Move / Copy, linked optimized media) | no Add / Move / Copy importer found in the VJ tools reviewed (Resolume has a Media Manager and the Alley converter; Millumin a Synced Library) |
| **Broadcast idioms on a performance surface**: Hot Punch, A/B ROLL, ADV, bus keys, tally | vMix/ATEM, not VJ apps |
| **Stable param codes and hand-editable show files** | competitors' project files are not designed for hand edits (not verified in depth) |
| **NTSC-legal scopes** (WFM, RGB, HIST, VEC, IRE legality) | Resolve, vMix; not VJ apps |

---

## 4. If only five things get built from this list

1. **Syphon out (M4) and OSC (M5).** Cheap, and they turn Videoboy from an island into a
   module other rigs can use and control — VJs, theatre and video artists all need it.
2. **Hot cues (M1).** The single biggest performance gap, shared with every DJ tool.
3. **Undo (M8).** The owner has already called the lack of it "a consistent bug".
4. **Presets / snapshots (M11)**, done as the Setlist and E-MEM work.
5. **MIDI clock + Ableton Link (M6)**, so Videoboy follows the booth when audio
   detection is not wanted.

Theatre (M2, M7, M10) is the largest new audience and the largest amount of work; it
should wait for a decision on whether that audience is wanted (see the deck's
"what I would do" pages).

---

## Sources

Resolume: https://resolume.com/support · https://resolume.com/support/en/clips · https://resolume.com/support/en/video · https://resolume.com/support/en/layers · https://resolume.com/support/en/bpm · https://resolume.com/support/en/avenue-arena-difference · https://www.resolume.com/shop · https://resolume.com/support/en/updates
VDMX: https://vdmx.vidvox.net/ · https://www.vidvox.net/?action=versionDetails · https://vdmx.vidvox.net/tutorials/workspace-inspectors-layers
Millumin: https://www.millumin.com/v5/ · https://help.millumin.com/docs/playback/dashboard/
QLab: https://qlab.app/docs/v5/video/video-cues/ · https://qlab.app/shop/ · https://www.capterra.com/p/146969/QLAB/
MadMapper: https://cdm.link/madmapper-6-brings-timelines-markers-clips-more/ · https://docs.madmapper.com/madmapper/6/what's-new · https://madmapper.com/madmapper/software
TouchDesigner: https://derivative.ca/UserGuide/TouchDesigner_Products
Isadora: https://troikatronix.com/isadora/ · https://support.troikatronix.com/support/solutions/articles/13000106556-isadora-4-release-notes
Synesthesia: https://synesthesia.live/features · https://synesthesia.live/pricing
Modul8 / CoGe / Magic / HeavyM: https://en.wikipedia.org/wiki/Modul8 · https://imimot.com/blog/farewell-from-coge/ · https://en.wikipedia.org/wiki/Magic_Music_Visuals · https://www.heavym.net/
DJ video: https://serato.com/dj/pro/pricing · https://store.serato.com/us/video · https://virtualdj.com/products/virtualdj/price.html · https://virtualdj.com/products/virtualdj/features.html · https://dj.studio/blog/professional-dj-software-price-guide
vMix: https://www.vmix.com/purchase/ · https://www.vmix.com/software/features.aspx
High-end (secondary): https://www.disguise.one/en/products/designer-starter-vs-pro · https://pixera.one/en/software/licenses/ · https://www.notch.one/pricing · https://www.dataton.com/about/special-offer
