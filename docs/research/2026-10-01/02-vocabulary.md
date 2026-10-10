# Videoboy's vocabulary — full update, compared with DJing and broadcast news (2026-10-01)

Every Videoboy term below was taken from the interface strings in `App/Sources` or from
the owner-set documents (`docs/SPEC.md`, `docs/PROPOSAL-2026-09-28-setlist.md`,
`docs/specs/*`), not from memory. DJ and broadcast meanings are sourced at the bottom.

**Fit key:** ✓ means the same thing in that world · ≈ close relative · ⚠ **false friend**
(the same word means something different there) · — no equivalent.

---

## 1. The system in one picture

```
 RIG (one show file, .vbt)
 ├─ BANK A/B ──────────────┐            ├─ BANK C/D ──────────────┐
 │  Source A ─┐            │            │  Source C ─┐            │
 │  Source B ─┴─ A/B Sub Mix ── ONE ─┐  │  Source D ─┴─ C/D Sub Mix ── TWO ─┐
 │  A/B FX (focus A · B · MIX)       │  │  C/D FX (focus C · D · MIX)       │
 │  Pads 1–4, Queue A, Queue B       │  │  Pads 5–8, Queue C, Queue D       │
 └───────────────────────────────────┘  └───────────────────────────────────┘
                         ONE ── Program row (1 · 2 · CUT · FADE) ── TWO
                                         │
                                      PROGRAM ─▶ OUTPUT (display) · REC · STREAM
 MEDIA:  Catalog ▸ Bins ▸ Clips (marks, optimized media) ── Asset Browser / Libraries
 TIME:   CLOCK (Internal · System Audio · Audio Input · an app) ▸ BPM ▸ DIV ▸ BEAT
 HANDS:  Learn (MIDI) · Detect (beat) · MIDI / AUD / LFO drivers · sweeps
 PLANNED: Playlist (saved Queue) · Setlist (a bank's state) · LOCK · Lists tab
```

---

## 2. Glossary — current terms

### 2.1 Signal path and switching

| Videoboy | What it means here | DJ | Fit | Broadcast news | Fit |
|---|---|---|---|---|---|
| **Source A / B / C / D** | A channel's input: a clip, generator, camera, window or emulator | deck | ≈ | input / source | ✓ |
| **Channel** | One of A–D, the source plus its effect copy | mixer channel | ✓ | input | ≈ |
| **Bank** (A/B, C/D) | A pair of channels and their sub-mix — new as a word (setlist proposal §1) | deck layer (1/3, 2/4 on a controller) | ≈ | **M/E bank** (mix/effects) | ✓ |
| **Sub Mix** (A/B Sub Mix, C/D Sub Mix) | A bank's mix of its two sources, with its own monitor | the two-deck mix | ≈ | M/E output | ≈ |
| **ONE / TWO** (bus one, bus two) | The two sub-mix buses | — | — | ME1 / ME2 | ✓ |
| **Program** | What leaves the app: ONE over TWO | master out | ≈ | **Program (PGM)** | ✓ |
| **Program row** | The 1 · 2 · CUT · FADE row and fader under Program | — | — | the PGM bus + T-bar | ✓ |
| **bus keys** (A B, C D, 1 2) | Take that source or bus to air | — | — | punch a source on the PGM bus | ✓ |
| **CUT** | Instant take to the other side ("Swap" and "CUT to ONE" are retired) | cut (crossfader slam) | ✓ | **CUT** | ✓ |
| **FADE** | An automatic fade at its rate, beat-quantised | crossfade / blend | ✓ | **AUTO** / MIX | ≈ |
| **BEAT** | Hold the next cut or fade until the beat (DIV sets which beat) | **quantize (Q)** | ≈ | — | — |
| **crossfader** | A↔B, C↔D and ONE↔TWO faders; DJ-style overhanging cap | crossfader | ✓ | **T-bar** | ≈ |
| **transition key** | Picks the shape a fader move takes (13 patterns) | — | — | transition style (MIX / WIPE / DVE) | ✓ |
| **AVE-5** | The Panasonic WJ-AVE5 wipe block, emulated | — | — | wipe patterns | ✓ |
| **blend key** | Blend mode of a composite (13 modes + Key) | — | — | key type / mix | ≈ |
| **Key** (blend mode) | Keys a layer's background out | — | — | **key** (luma/chroma) | ✓ |
| **Hot Punch (!)** | Armed, a pad press goes straight to Program | — | — | **hot punch**: cut directly on the program bus | ✓ |
| **ROLL** | A/B roll: roll the source you take, re-cue the one leaving | **loop roll** | ⚠ | **A/B roll** / "roll VT" | ✓ |
| **ADV** | Load the leaving source's next clip | auto-load next | ≈ | next item in the playlist | ≈ |
| **monitor** | A preview with scope keys (Sub Mix, Program) | headphone cue | ≈ | **multiviewer tile** | ✓ |
| **tally** (red outline) | Which monitors are on air | **ON AIR** light on a CDJ | ✓ | **tally** | ✓ |

### 2.2 Clips, playback and loading

| Videoboy | What it means here | DJ | Fit | Broadcast news | Fit |
|---|---|---|---|---|---|
| **clip** | A file (or photo folder) in the catalog | track | ✓ | clip / **VO** / **SOT** / **PKG** | ≈ |
| **in / out marks** | One trimmed range per clip, stored in the catalog | loop in / out | ≈ | mark in / mark out | ✓ |
| **Loop · Ping-Pong · One Shot** | Play modes per source | loop | ≈ | loop / play once | ✓ |
| **STEP** | A frame per subdivision (8/1 … 1/16), locked to the beat | slicer | ≈ | jog | ≈ |
| **speed** | Playback rate on Source Controls | tempo / pitch fader | ✓ | lever (EVS) | ✓ |
| **FIT** | Fit · Fill · Stretch · Centre for a source | — | — | aspect ratio conversion | ✓ |
| **Queue** | A channel's live up-next list (renamed from Playlist / Up Next) | **queue** (djay), *Prepare* (Serato) | ✓ | clip-server playlist | ≈ |
| **Play Next / Play Last** | Put a clip at the front / end of the Queue | queue next / add to queue | ✓ | — | — |
| **AUTO** (library) | A clip starts playing when it lands in a channel | auto-play / auto-cue | ≈ | **AUTO** = run the transition | ⚠ |
| **Clip Pads 1–8** | Eight whole-clip launchers in the top bar | **sampler pads** | ≈ | — | — |
| | | **hot-cue pads** (points *inside* a track) | ⚠ | | |
| **pad side switch** (A/B, C/D) | Which bank pads 1–4 / 5–8 load into | deck layer switch | ✓ | — | — |
| **Source Controls** | A card at the top of each FX panel for the focused source | — | — | — | — |
| **Import** (mode) | ⌘1: bring media into the catalog (Add · Move · Copy) | analyse / import | ≈ | **ingest** | ✓ |
| **Optimize** | Write a linked, edit-friendly copy (MPEG-2 GOP 6 on SD) | — | — | proxy / transcode | ✓ |
| **catalog** | The SQLite library database | collection | ✓ | media asset management | ≈ |
| **bin** | A folder of clips in the catalog (nested) | **crate** | ✓ | bin | ✓ |
| **Asset Browser** | The centre browser: Sources · Generators · Graphics · Clips · Images · EMU | browser | ✓ | media pool | ≈ |
| **Library** (A/B, C/D) | A bank's own browser | — | — | — | — |

### 2.3 Effects and looks

| Videoboy | What it means here | DJ | Fit | Broadcast news | Fit |
|---|---|---|---|---|---|
| **FX panel** (A/B FX, C/D FX) | A bank's effect chain | FX unit | ≈ | DVE / effects | ≈ |
| **card** | One effect in the chain, with a switch and ✕ | effect slot | ✓ | — | — |
| **focus A · B · MIX** | Which copy every card edits (MIX = the sub-mix) | Beat FX **channel select** (1–4, MIC, MASTER) | ✓ | — | — |
| **MIDI · AUD · LFO** badges | What drives a parameter | MIDI map · — · — | ≈ | — | — |
| **driven** parameter | Has a MIDI, audio or LFO driver; outlines and breathes | — | — | — | — |
| **sweep** (⌥⌘-click) | Moves a fader or parameter over a beat rate | filter sweep | ≈ | auto transition | ≈ |
| **rate key** | How often a FADE / CUT / sweep taps; click faster, right-click slower | **beat select** (1/16 … 16 beats) | ✓ | transition **RATE** (frames) | ✓ |
| **Datamosh · H.264** — mosh, melt, bloom, bloom loop, bitrate, hold, **MOSH**, **HEAL**, heal every / time / shape | Live I-frame removal and P-frame bloom on a real H.264 stream | — | — | — | — |
| **Composite · NTSC** | Encode→decode signal model (dot crawl, chroma bleed, TBC wobble) | — | — | NTSC composite | ✓ |
| **Feedback** (gain, delay, zoom, rotate) | Frame-history loop | — | — | video feedback | ✓ |
| **Freeze** (hold) | Hold the picture | brake / freeze | ≈ | freeze frame | ✓ |
| **Echo / Trails** (decay, length, thresh) | Frame echo | echo | ≈ | — | — |
| **ISF** | Imported shader effects and generators | — | — | — | — |
| **wedge** | Internal: the bitstream manipulation that defines the app | — | — | — | — |
| **corruptor** | The MPEG bitstream damage card (currently switched off) | — | — | — | — |

### 2.4 Time and control

| Videoboy | What it means here | DJ | Fit | Broadcast news | Fit |
|---|---|---|---|---|---|
| **CLOCK** | Where tempo comes from: Internal, System Audio, Audio Input, or one app | master / sync source | ✓ | reference / genlock | ≈ |
| **BPM**, tap | Tempo | BPM, tap | ✓ | — | — |
| **DIV** | Subdivision actions land on | quantize resolution | ✓ | — | — |
| **Detect** | Beat detection (BeatNet) | analyse / BPM detect | ✓ | — | — |
| **Learn** (Shift-click) | MIDI learn; Esc cancels, ⌫ unmaps | MIDI learn / map | ✓ | panel mapping | ≈ |
| **param code** (e.g. `24A`) | A control's stable address | — | — | — | — |
| **take-backs** | Targeted undo: eject cancels, ⌫ unmaps, LFO removal restores | undo | ≈ | — | — |

### 2.5 Output, monitoring and the show

| Videoboy | What it means here | DJ | Fit | Broadcast news | Fit |
|---|---|---|---|---|---|
| **OUTPUT** | The output switch and destination | master out | ≈ | line out / air | ✓ |
| **send** glyph | Route a monitor to a display (incl. four-up) | — | — | aux / router | ✓ |
| **REC** + **FMT** | Record Program and armed channels (ProRes / H.264 / HEVC) | record mix | ✓ | ISO recording | ✓ |
| **STREAM** | MPEG-TS over UDP for OBS | broadcast / stream | ✓ | — | — |
| **WFM · RGB · HIST · VEC** | Scopes | — | — | scopes | ✓ |
| **OVER** · **L3** | Scope over the picture · in the lower third | — | — | — | — |
| **FILE** · **TC** | File name / timecode over the monitor | — | — | **UMD** / TC | ✓ |
| **DATA BURN** | Burn the data into the output | — | — | **burn-in** / window burn | ✓ |
| **Safe · Overscan · BFI · Test Pat** | CRT-target toggles | — | — | safe area · overscan · — · **bars** | ✓ |
| **NTSC** (output) | Output signal emulation (switched off) | — | — | — | — |
| **show** (`.vbt`) | The whole rig saved as a plain-text file | set / collection | ≈ | **show file** | ✓ |
| **IMPORT · VJ · SETTINGS** | The mode bar (⌘1–⌘3) | — | — | — | — |
| **EMU** — START / STOP, **TAKE**, SAVE STATE | The emulated titler; TAKE repaints the page from the panel's text | — | — | **TAKE** = put the next element on air; CG **UPDATE** | ⚠ |
| **Now Playing** | Song title / artist / art over the picture (Music, Spotify) | track info | ✓ | **lower third / super** | ≈ |

---

## 3. Planned terms (owner-set 2026-09-29, not built)

| Videoboy | Meaning | DJ | Fit | Broadcast news | Fit |
|---|---|---|---|---|---|
| **Playlist** | A saved Queue (load: Append / Replace) | playlist | ✓ | playout playlist | ✓ |
| **Setlist** | Two Playlists + the bank's effects, automation and 4 pads | **setlist = the running order of songs** | ⚠ | **E-MEM** (a learned switcher state) | ≈ |
| **Start Up Sequence** — Punch · Cue · Crossfade | What happens when a Setlist loads | — | — | macro / **punch** · **cue** · mix | ✓ |
| **LOCK** | Freezes a bank's controls; Program still takes | CDJ **LOAD LOCK** (no loading while playing) | ✓ | panel lock / safe | ✓ |
| **Lists** tab | Playlists and Setlists in the Asset Browser | playlists pane | ✓ | rundown list | ≈ |
| **Link to Current Song** | A Setlist fires when its song starts in Apple Music | Pro DJ Link / timecode triggers | ≈ | — | — |

---

## 4. What changed since the last vocabulary (the record)

| Old | New | When / where |
|---|---|---|
| Playlist (live list), Up Next | **Queue** (Core: `ClipQueue`) | 2026-09-29, `feature/queue-names` |
| — | **Play Next / Play Last** | 2026-09-29 |
| "Swap", "CUT to ONE", "CUT to TWO" | **CUT** | owner, earlier rounds (`docs/FEATURE-LEDGER-2026-09-27.md` §5) |
| per-card A/B selectors | **focus A · B · MIX** on the panel title | 2026-09-28 |
| Sub Mix 1 FX / Sub Mix 2 FX | **A/B FX / C/D FX** | UI (panel titles) |
| M · S · C badges | **MIDI · AUD · LFO** | UI (cards) |
| DV, DV Stream, DIF corruptor | retired (DV removed) | 2026-09-28 |
| MX-1 set (mosaic, posterize, negative…) | retired; **Freeze** kept | 2026-09-23 |
| Zebra, DATA button (output bar), MIDI BPM clock | retired | ledger §5 |
| VJ mode only | **IMPORT · VJ · SETTINGS** modes | 0.4.8 |
| — | **Clip Pads**, **Hot Punch**, **ROLL**, **ADV** | 2026-09-27/28 |
| "Setlist" (run of show, 09-28 draft) | **Setlist** = a bank's state; run of show dropped | 2026-09-29 |

---

## 5. Where the vocabulary works against us

1. **"Setlist" is a false friend for every DJ and band.** To them a setlist is the
   running order of songs; Videoboy's Setlist is the state of one bank. The closest
   broadcast idea is the E-MEM. The owner set the name on 2026-09-29, so this is a flag,
   not a change: keep it, and say "a bank's look" in its tooltip, or consider **Scene**,
   **Look** or **Memory** if the confusion shows up in use.
2. **AUTO means "run the transition" to anyone from a switcher.** In the library it means
   autoplay on load. **AUTOPLAY** (or a ▶ glyph) would stop a broadcast user pressing it
   to take a shot.
3. **TAKE on the EMU panel repaints the page; in broadcast TAKE puts the next element
   on air.** **UPDATE** (the CG word for exactly this) or **SEND** would be honest.
4. **ROLL** is right for broadcasters (A/B roll, "roll VT") and wrong for DJs, whose
   *loop roll* is a momentary stutter. Keep it — but if loop roll ever ships (deep dive
   §5.9), call that one **STUTTER** or **RETRIGGER**, not roll.
5. **Clip Pads launch whole clips.** DJs will expect pads to be hot cues inside a track.
   If hot cues ship (deep dive §5.1), the pads should gain a **mode** (Clips · Cues), the
   way DJ pads have Hot Cue / Sampler / Roll modes, rather than a second set of pads.
6. **"Detect" names two things in the documents.** In the UI, Detect is beat detection
   and Learn is MIDI learn — clear. But `docs/SPEC.md` §7 and `DetectSession` still call
   MIDI learn "shift-to-detect". The docs should say Learn.
7. **The main mode is called VJ** while `CLAUDE.md` says Videoboy is not a VJ tool, and
   the owner now wants a room for many kinds of creative. **LIVE** (or **SHOW**) would
   name the mode by what happens in it rather than by one audience, and sits naturally
   beside IMPORT and SETTINGS.
8. **FADE vs AUTO.** Broadcast users look for AUTO next to CUT. FADE is clearer for
   everyone else, so keep it — the tooltip can say "(AUTO on a switcher)".

### Cheap fix for all of them
Add the other worlds' words to the tooltips, the way the AVE-5 popover quotes the
hardware manual: *"FADE — an automatic transition at the FADE rate (AUTO on a switcher,
a blend on a DJ mixer)."* Nothing moves, nobody relearns anything, and a DJ or a TD
finds their own word under the pointer.

---

## Sources (outside Videoboy)

- DJ glossaries: https://www.thedjrevolution.com/dj-terms/ · https://dj.studio/blog/dj-mixing-terms · https://vibesdj.io/glossary/beatgrid
- Pioneer DJ, DJM-A9 (Beat FX channel select, Color FX, Center Lock): https://www.pioneerdj.com/en/news/2023/djm-a9-4-channel-professional-dj-mixer/
- CDJ-3000 manual (LOAD LOCK): https://www.bhphotovideo.com/lit_files/630695.pdf
- Serato expansions (Prepare, Video): https://support.serato.com/hc/en-us/articles/223365767-Serato-Expansions
- Blackmagic ATEM manual (CUT, AUTO, RATE, DSK): https://www.fullcompass.com/common/files/83524-ATEMSDIUserGuide.pdf
- Grass Valley Kayenne concepts (M/E, E-MEM): https://wwwapps.grassvalley.com/docs/Manuals/switchers/kayenne/071-88-3400_Kayenne_Karrera_Concepts_Manual.pdf
- Hot punching / punch up (Videomaker; Zettl, *Video Basics*): https://www.videomaker.com/article/f1/17834-how-to-use-a-live-switcher/ · https://www.cengage.com/resource_uploads/static_resources/0495569437/17449/ch10.html
- News script terms (reader, VO, SOT, PKG): https://www.nyfa.edu/student-resources/the-ultimate-list-of-broadcast-journalism-terms/
- CasparCG (PLAY / NEXT / STOP / UPDATE): https://chrisryanouellette.gitbook.io/casparcg-html-template-guide/amcp-commands-review
- EVS LSM (mark, cue points, lever): https://www.manualslib.com/manual/1224276/Evs-Multicam-Lsm.html
