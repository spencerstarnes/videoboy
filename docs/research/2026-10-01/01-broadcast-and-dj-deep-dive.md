# Deep dive — what broadcast and DJing know that Videoboy should (2026-10-01)

Asked by the owner: *"a deep dive into the world of both broadcast editing and DJing.
Let's ignore some of the VJ conventions for now, but I want to expand the feature set,
refine the behavior of the app, and ultimately, make this a room that a wide variety of
creatives can use."*

This is research and recommendation only. Nothing here is built, and nothing here
overrides `CLAUDE.md`'s scope guard (the bitstream wedge + clean SD output come first).
§6 says how the two fit together. Every Videoboy claim below is checked in
`feature-inventory.md` (same folder); every outside claim is sourced at the bottom.

---

## 0. The short version

Videoboy already sits between the two worlds: it has a **DJ's clock** (BPM, beat
detection, quantised actions) and a **switcher's routing** (four sources, two buses,
Program). What it lacks from each is mostly **memory and preparation**, not more effects:

| | DJs have | Broadcast has | Videoboy has today |
|---|---|---|---|
| **Inside a clip** | 8 hot cues, memory cues, loops, beat jump, slip | cue points marked on the fly (EVS) | one in/out pair per clip |
| **Before it airs** | headphone CUE / PFL on any channel | Preview bus + multiviewer | sub-mix monitors only |
| **Taking it** | crossfader + curve, quantise | CUT / AUTO / T-bar, a RATE per style, stingers | CUT / FADE / 13 patterns, beat-quantised ✓ |
| **On top** | — | keyers (USK) + downstream keyers (DSK) with their own CUT/AUTO | Key blend mode on a fader |
| **Remembering a look** | — | E-MEM: learn the whole switcher state, recall it with one press | whole-show files only |
| **Running order** | playlists, history, smart crates | rundown (reader / VO / SOT / PKG), back-timing, MOS automation | per-channel Queue (new); Setlists planned |
| **After the show** | recording of the mix | ISO recordings + an editable project of every cut | discrete recordings ✓, no cut list |
| **Talking to other gear** | Pro DJ Link, StageLinQ, Link, MIDI clock, SMPTE | tally, GPI, timecode, MOS | MIDI in only |

The five highest-value borrowings, in order: **hot cues per clip**, **a cut list with
the discrete recordings** (so a performance can be re-edited in Resolve/Premiere),
**E-MEM-style look memories** (which the Setlist plan already half-designs), **a
downstream key layer** for titles and Now Playing, and **beat/tempo sync with DJ gear**.

---

## 1. How broadcast production works (the live side)

### 1.1 The vision mixer (production switcher)
- **Program / Preview.** A switcher has a Program bus (on air) and a Preview bus (next).
  Blackmagic's ATEM even offers both styles: *cut bus* (pressing a source takes it at
  once) and *program/preview* (select on Preview, then take). **CUT** performs an
  immediate take, overriding the chosen transition style. [ATEM manual]
- **Transitions have a RATE per style.** MIX, DIP, WIPE, DVE and STING each keep their
  own rate, shown in the RATE window; **AUTO** runs the selected style at its rate, the
  **T-bar** does it by hand. [ATEM manual]
- **Keyers.** *Upstream* keyers (four on an ATEM SDI Extreme ISO) composite inside a
  mix/effects bank; **downstream keyers (DSK)** sit after everything, with **their own
  CUT and AUTO buttons and their own rate**, so a logo or lower third goes on and off
  independently of the shot underneath. [ATEM manual]
- **Macros and E-MEMs.** Macros record a sequence of button presses. Grass Valley's
  **E-MEM** ("effects memory") *learns* the whole state of an M/E into a register and
  *recalls* it with one press; modern versions keyframe partial "sub-levels" (one key,
  one channel) and load+play clips as keyframes. Each Kayenne panel holds **1,000 E-MEMs
  and 999 macros**. [GV Kayenne concepts manual]
- **Multiviewer + tally.** Every source is visible at once, labelled, with red (on air)
  and green (preview) tally borders.

### 1.2 The running order
- A **rundown** lists every element in order with its length: a **reader** (anchor on
  camera), a **VO** (anchor reads over video), a **SOT** (a sound bite), a **PKG** (a
  reporter's finished story, 1:30–2:00), a **live shot**, **teases** and **bumps** into
  breaks. [NYFA]
- **Back-timing** starts from the show's END time and subtracts lengths upward, so every
  line shows the wall-clock time it must start for the show to end on time. [Rundown
  Creator, NewsLab]
- The newsroom system (ENPS, iNEWS) drives the gear over **MOS** (Media Object Server),
  and an automated production control system — Ross **OverDrive** integrates "220+
  devices" — lets one operator run the switcher, cameras, servers, audio and graphics
  from the rundown. [MOS, Ross]

### 1.3 Clips, replay and graphics
- **Replay (EVS LSM):** a lever plays 0–100% slow motion (or ±100/±200%); the operator
  marks **cue points** on the recording while playing a different replay; **Last Cue**
  steps back through them; playlists carry a preset speed per clip that the lever
  overrides. [EVS LSM manual]
- **Graphics (CG):** a template is loaded and then **PLAY** animates it in, **NEXT**
  steps it, **STOP** animates it out, and **UPDATE** changes its data on air. That is
  the CasparCG model, and every broadcast CG works the same way. [CasparCG AMCP]
- **Software switchers** bring the same ideas to one computer: vMix has an input list,
  **8 overlay channels each with its own transition**, **4 transition buttons**, **up
  to 8 custom stingers**, data-driven titles, 8-camera replay, multiview layers, NDI and
  SRT in and out. [vMix]

### 1.4 Recording that can be re-edited
The ATEM ISO models record **the program plus every input separately** and, when they
stop, write **a DaVinci Resolve project containing every cut and dissolve** on a
timeline linked to the ISO files, so the live edit can be changed afterwards.
[Blackmagic, RedShark]

## 2. How broadcast editing works (the post side)

- **Three-point editing:** set two of in/out on the source and in/out on the record
  side; the third point is implied. **Splice-in** (insert, `V` in Avid) pushes the rest
  of the sequence later; **overwrite** (`B`) replaces what is there. **Lift** leaves a
  gap, **extract** closes it. [Emerson/Avid, ProVideo Coalition]
- Source and record monitors, **J/K/L** shuttle, **match frame**, markers, bins,
  multicam, and interchange (EDL / XML / AAF) with timecode on everything.

Videoboy already shares the source-monitor half: every source has a preview, a scrub,
in/out marks in the catalog and J/K/L in Import mode's viewer. What it lacks is the
record-side half (a cut list), which §5.6 proposes in the lightest possible form.

## 3. How DJing works

### 3.1 The mixer
- **Channel faders** and a **crossfader with a selectable curve** (sharp for cutting,
  smooth for blending). **EQ** (3-band, often with full kills), a **filter** on one knob,
  **trim/gain**, and **CUE / PFL**: a button per channel that sends it to the headphones
  without touching the master. [DJ glossaries]
- **Two kinds of effects:** *Sound Color FX* — one knob per channel (Space, Crush, Noise,
  Dub Echo, Sweep, Filter) — and *Beat FX* — one effect routed to a chosen channel, timed
  in beats. Pioneer's DJM-A9 adds **Center Lock**, so a colour knob stops at noon
  instead of swinging past into the opposite effect. [Pioneer DJ]

### 3.2 The decks
- **Cue** (hold to preview, release to return), **8 hot cues** (coloured, named),
  **memory cues** (markers that do not fire), **loops** (auto loop, loop roll that
  carries on "underneath"), **beat jump**, **slip mode** (the track keeps its place while
  you loop or scratch), **quantise** (everything snaps to the beatgrid), **key lock**,
  **sync** (tempo and phase). [DJ glossaries]
- **Preparation is half the job.** rekordbox 7's **CUE Analysis** places hot and memory
  cues from **phrase analysis** (intro / verse / chorus / outro) and can learn a DJ's
  style from a playlist they have already cued; **stems** split vocals / instruments /
  bass / drums (4 stems since 7.2.8, April 2026). [rekordbox, Digital DJ Tips]

### 3.3 Video DJing (what DJ software does with pictures)
- **Serato Video:** video FX and transitions, **audio-linked FX** (an audio echo makes a
  visual echo), images and text over the mix, FX saved per file, transitions on the DJ
  hardware, recording with audio, karaoke. [Serato]
- **VirtualDJ:** an HD/4K video engine, video FX and transitions, text-to-screen, a song
  titler, camera and screen grab, a **video crossfade that follows the audio mix**,
  karaoke, real-time stems. [VirtualDJ]

### 3.4 Talking to the booth
- Pioneer **PRO DJ LINK** (Ethernet, 2009) shares tempo and track data; **Beat Link
  Trigger** joins that network as a virtual CDJ and fires MIDI/OSC when a player goes on
  air, changes tempo or loads a song. Denon's **StageLinQ** does the same for Engine DJ
  and is wired into SoundSwitch and Resolume. AlphaTheta added SoundSwitch to rekordbox
  and the PRO DJ LINK Bridge in September 2026. [DJWORX, Deep Symmetry, EDMTunes]
- Resolume syncs to Denon and Pioneer gear and to **SMPTE**; with the ProDJLink bridge,
  **a specific video can start when a specific song plays**, via timecode offsets.
  [Resolume, ProDJLink]

---

## 4. Mapping both worlds onto Videoboy

| Concept | DJ | Broadcast | Videoboy now | Gap |
|---|---|---|---|---|
| Next shot / next track | CUE/PFL in headphones | Preview bus | the off-air sub-mix monitor | no per-source "cue to preview" key |
| Take | crossfader | CUT / AUTO / T-bar | CUT / FADE / fader ✓ | no rate per *style*; one rate per key |
| Transition shapes | — | MIX / DIP / WIPE / DVE / STING | 13 patterns incl. AVE-5 ✓ | DIP, stinger, soft-edge wipes |
| Points inside media | 8 hot cues, memory cues | EVS cue points, Last Cue | one in/out | **hot cues** |
| Looping | auto loop, roll, beat jump, slip | loop in replay | loop / ping-pong / one-shot, STEP | loop length in beats, roll, slip |
| Overlay | — | USK + DSK with own CUT/AUTO | Key blend on a fader | **a DSK layer** |
| Look memory | — | E-MEM learn/recall | show files; Setlists planned | **snapshots per bank** |
| Running order | playlists, history | rundown, back-timing, MOS | Queue (new), Setlists planned | durations + back-time |
| Graphics | song titler (VirtualDJ) | CG PLAY / NEXT / STOP / UPDATE | Now Playing, Scala titler, CG node unwired | one PLAY/STOP model for all titles |
| Sync | Link, Pro DJ Link, StageLinQ, MIDI clock | timecode, genlock, tally | audio beat detection ✓ (BeatNet) | **MIDI clock / Link / Pro DJ Link** |
| After the show | mix recording | ISO + project of every cut | discrete recordings ✓ | **cut list export** |
| Safety | — | panel lock, tally | LOCK planned | — |

---

## 5. What to build or refine, ranked

Each item names the world it comes from, why it matters, how big it is, and whether it
serves the wedge. "Size" is a rough feel: S ≈ a day, M ≈ a few days, L ≈ a week or more.

### 5.1 Hot cues per clip (DJ) — **M, top priority**
Eight coloured cue points per clip, stored in the catalog like in/out marks. On a source:
pads 1–8 (or a hot-cue row on Source Controls) jump to a cue, **quantised to the beat**
like every other action. Shift-learnable like everything else. With them, one long clip
becomes many shots, which is how DJs think and how a live editor would cut. Later, the
same CUE Analysis idea (rekordbox places cues by phrase) could place cues by **shot
change**, which is easy to detect in video.

### 5.2 A cut list with every recording (broadcast) — **S–M**
Videoboy already records Program plus discrete A/B/C/D into one folder per take. Add
**one more file per take: the cut list** — every take, bus key, CUT, FADE and transition
with its timecode — as a **CMX 3600 EDL** (Premiere Pro, DaVinci Resolve and Avid import
it) and **FCPXML** (Final Cut Pro and Resolve). That is the ATEM ISO idea without writing
a `.drp`. Cuts, dissolves and simple wipes survive in both formats; effects travel in
neither, so the timeline carries the edit and the Program recording stays the reference
for the finished look. (The recorder writes the same textures the previews show —
`ShellController`, "Recording reads the same textures the previews do".)
It turns a performance into an editable timeline, which is what a "broadcast editor"
would value most, and it costs nothing at show time (text written at the end).

### 5.3 Look memories (broadcast E-MEM) — **M, extends the Setlist plan**
The Setlist proposal already captures a bank's effects, automation and pads. E-MEM adds
two things worth copying: **learn with one press, recall with one press**, many slots
(a numbered row like the Clip Pads), and **partial recall** (only the effects, only the
transition, only the pads). Recall must obey LOCK and land on the off-air bank by
default, exactly as Setlists will.

### 5.4 A downstream key layer (broadcast DSK) — **M**
One layer after Program with its own **CUT / AUTO / rate**, holding titles, Now Playing,
the Scala titler or a logo, so graphics go on and off without touching the mix
underneath. Today a title has to occupy a source and a bus. This also gives the unwired
Core Text character generator (inventory B15) its home.

### 5.5 One title model: PLAY / NEXT / STOP / UPDATE (broadcast CG) — **S once 5.4 exists**
Make every text-like source behave the same way: PLAY animates in, NEXT steps (the
next line or page), STOP animates out, UPDATE swaps the data. Now Playing already does
the UPDATE part (it fades on a track change).

### 5.6 Beat and tempo from DJ gear (DJ) — **M each**
Audio detection (BeatNet) stays the default and the differentiator. Add **MIDI clock
in** first (smallest, works with every DJ app and drum machine), then **Ableton Link**
(rekordbox, Serato, Traktor and Engine all speak it), and consider **Pro DJ Link /
StageLinQ** only for track metadata (which song is on air, for song linking beyond
Apple Music). `docs/BUILD-PLAN.md` already lists MIDI clock and Link as wanted.

### 5.7 Preview discipline (both) — **S–M**
- A **CUE key per source** (DJ PFL): routes that source to the Program monitor's corner
  or a dedicated preview output without touching air.
- An optional **Program/Preview mode** for the ONE↔TWO row (broadcast): select the next
  bus, then AUTO/CUT. Keep today's direct mode as default — performers like cut-bus.
- **Tally out** over MIDI (an LED on the controller for whatever is on air).

### 5.8 Transition rate per style, DIP, stingers, soft edges (broadcast) — **S–M**
Each transition pattern remembers its own rate (as ATEM does); add **DIP** (through black
or a colour), **soft-edge/border** on the ordinary wipes (already noted as missing in
BUILD-PLAN), and a **stinger** (a clip with alpha played over the cut point) — the most
requested broadcast-style transition in software switchers (vMix allows 8).

### 5.9 Loops in beats, roll and slip (DJ) — **M**
Loop lengths in beats (1/4 … 16) quantised to the clock, **loop roll** (loop while held,
then continue where the clip would have been) and **slip** for any momentary action.
These fit the existing STEP ladder and the beat-rate key rule.

### 5.10 A rundown view with back-timing (broadcast) — **M, after Setlists**
Setlists will exist; give them **lengths** (planned song length or clip total) and a
**rundown** list that back-times from a show end time. Useful for theatre and broadcast
users with a fixed running time; invisible to anyone who never opens it.

### 5.11 Controller ergonomics (DJ) — **S each**
- **Center lock** for bipolar knobs (hue, offset) so a fast twist cannot pass zero.
- **Crossfader curve** per fader (sharp cut ↔ slow blend), as on every DJ mixer.
- **Kill switches**: momentary hold-to-bypass on any effect card (the card's switch
  held, not toggled).
- **MIDI out / LED feedback**, so a controller shows what is on and armed.

### 5.12 Audio-linked FX (DJ video) — **S**
Serato's best video idea: audio events make visual events. Videoboy's audio-reactivity
bus already lets any parameter follow RMS, bands and onsets; what is missing is a
**preset** that pairs them (onset → Freeze pulse, low band → Feedback zoom) so it works
in one click.

### Things deliberately not recommended
- **Audio output** (playing clip audio). `docs/SPEC.md` §21 says the app is silent, and
  DJ software already owns audio. A DJ will always have their own mixer.
- **A full NLE timeline.** The cut list (5.2) gets the benefit without the weight.
- **A newsroom/MOS integration.** Real, but a different product.

---

## 6. "A room many creatives can use" without losing the wedge

`CLAUDE.md` says Videoboy "is NOT a general VJ tool and must not grow into one". The
owner now asks for a room many creatives can use. Both can hold if the expansion follows
three rules:

1. **Borrow behaviours, not effect libraries.** Everything ranked above is about *how a
   performer cues, takes and remembers*, not about more looks. The look stays analog,
   bitstream and NTSC.
2. **Profiles, not clutter.** The layout is fixed and that is a strength. New behaviour
   should arrive as modes the existing mode bar already supports (⌘1 Import · ⌘2 VJ ·
   ⌘3 Settings), or as states of existing keys (a preview mode for the Program row, a
   hot-cue page on the pads), never as new floating panels.
3. **The wedge stays the reason to choose it.** The bitstream corruptor is currently
   switched off (`bitstreamCorruptor`); the MPEG datamosh and the NTSC chain are what no
   competitor has. A wider audience is only worth having if they arrive for those.

Who arrives, and what each needs first:

| Creative | Comes from | Needs first (from §5) |
|---|---|---|
| DJ who wants visuals | rekordbox / Serato | 5.6 sync, 5.1 hot cues, 5.12 audio-linked presets |
| Broadcast / livestream TD | ATEM, vMix | 5.7 preview mode + tally, 5.4 DSK, 5.8 rates and stingers |
| Live editor / video artist | Resolve, Premiere | 5.1 hot cues, 5.2 cut list, 5.3 look memories |
| Theatre video designer | QLab, Millumin | 5.10 rundown, 5.3 memories, LOCK |
| Music video / installation | VDMX, TouchDesigner | the wedge itself, plus Syphon out (backlog) |

---

## Sources

- Blackmagic ATEM SDI manual (July 2022): https://www.fullcompass.com/common/files/83524-ATEMSDIUserGuide.pdf
- Grass Valley Kayenne/Karrera concepts manual (E-MEM): https://wwwapps.grassvalley.com/docs/Manuals/switchers/kayenne/071-88-3400_Kayenne_Karrera_Concepts_Manual.pdf
- NYFA, broadcast journalism terms: https://www.nyfa.edu/student-resources/the-ultimate-list-of-broadcast-journalism-terms/
- Rundown Creator, Timing 101: https://www.rundowncreator.com/how-it-works/timing-101/
- NewsLab, back-timing: https://newslab.org/backtiming-the-day-a-guide-for-producers/
- Media Object Server: https://en.wikipedia.org/wiki/Media_Object_Server
- Ross OverDrive: https://www.rossvideo.com/products/automation-and-control/overdrive/
- EVS Multicam LSM manual: https://www.manualslib.com/manual/1224276/Evs-Multicam-Lsm.html
- CasparCG AMCP / template guide: https://chrisryanouellette.gitbook.io/casparcg-html-template-guide/amcp-commands-review
- vMix features: https://www.vmix.com/software/features.aspx
- Blackmagic ATEM Mini editing (ISO + Resolve project): https://www.blackmagicdesign.com/products/atemmini/editing
- RedShark News on ATEM Mini Pro ISO: https://www.redsharknews.com/atem-mini-pro-iso-take-your-live-edits-right-into-davinci-resolve
- Three-point editing in Avid (Emerson): https://support.emerson.edu/hc/en-us/articles/21709364842011-Three-Point-Editing-in-Avid
- ProVideo Coalition, Avid basics: https://www.provideocoalition.com/the_basics_of_avid_media_composer_for_a_final_cut_pro_editor/
- DJ glossaries: https://www.thedjrevolution.com/dj-terms/ and https://dj.studio/blog/dj-mixing-terms
- Pioneer DJ, DJM-A9: https://www.pioneerdj.com/en/news/2023/djm-a9-4-channel-professional-dj-mixer/ and https://thedjhookup.com/blog/reviews/pioneer-djm-a9-review/
- rekordbox 7 overview: https://rekordbox.com/en/feature/overview/
- Digital DJ Tips, rekordbox 7.2.8 four stems: https://www.digitaldjtips.com/rekordbox-v7-2-8-adds-4-stem-separation-new-cloud-setup-wizard/
- Serato Video: https://store.serato.com/us/video and https://support.serato.com/hc/en-us/articles/223365767-Serato-Expansions
- VirtualDJ features and video manual: https://virtualdj.com/products/virtualdj/features.html and https://virtualdj.com/manuals/virtualdj/interface/mixer/video.html
- DJWORX on StageLinQ, SoundSwitch and Resolume: https://djworx.com/stagelinq-soundswitch-resolume-denon-djs-visual-trinity/
- Beat Link Trigger: https://github.com/Deep-Symmetry/beat-link-trigger
- EDMTunes, AlphaTheta adds SoundSwitch (Sep 2026): https://www.edmtunes.com/2026/09/alphatheta-adds-soundswitch-support-to-rekordbox-pro-dj-link/
- Resolume, Sync with a DJ: https://resolume.com/support/en/sync-with-dj
- ProDJLink, Resolume: https://www.prodjlink.com/help/resolume
