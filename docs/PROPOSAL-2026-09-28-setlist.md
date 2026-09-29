# Proposal — Sets and the Setlist: preparing and changing over a show (2026-09-28)

Status: **DRAFT for the owner.** Nothing here is built. Open questions are in §11.

Owner's brief: "prepare workspaces and loaded settings, clips, queue, generators … how do
we seamlessly transition from one set to another, what's the changeover look like, how
does it work? … a setting for binding playlists to songs in iTunes. Playlists can also
contain BPM info."

---

## 1. What exists today (the parts this builds on)

| Piece | Where | What it already does | Gap for a run of show |
|---|---|---|---|
| **Show file** (`.vbt`, `TemplateDocument` v4) | Core/Persistence | Saves and opens the WHOLE rig: both effect chains + every value, MIDI mappings, tempo/subdivision, what each channel holds (clip + marks, generator, camera), Clip Pads | One show per file. Opening is a **hard replace of everything at once** — clips re-open, chains rebuild, on air, mid-frame. There is no "next". |
| **"Playlist"** (`Playlist.swift`) | Core | Per-CHANNEL Up Next queue; a ONE SHOT clip pulls the next item | Not saved in the show file. Name collides with what you're asking for (see §9). |
| **ADV / A/B ROLL** | Engine | Pre-opens the next clip off the main thread; takes are instant | Clip-level, not set-level — but it is exactly the pre-open machinery a changeover needs. |
| **Clip Pads** | top bar | 4 pads per SIDE (1–4 → A/B, 5–8 → C/D), pre-opened, saved with the show | Already side-shaped: a set's pads map straight onto its side's strip. |
| **Program fader** | fader row | 1 · 2 · CUT · FADE · rate, wipes/AVE-5 patterns, beat-quantised cuts | This IS the changeover fader (§3). |
| **Two sub-mixes, two FX chains** | graph | A/B → bus ONE with its own chain; C/D → bus TWO with its own | Each side is a complete, independent rig. That is the key fact of this design. |
| **Now Playing watcher** | Platform | Polls Music/Spotify over AppleEvents once a second (title, artist, album, position, duration, artwork); Automation permission already requested | Doesn't read the track's **persistent ID** or **BPM** — both are one line of AppleScript each. |
| **Tempo** | Transport, BeatNet | Internal clock, tap, audio beat detection (BeatNet) | No per-set tempo. |

Verified in code: `Engine.rebuildChain(bus)` only touches that bus's nodes and edges, and
clip opening is off the main thread (`ClipSourceNode.prepare`, `Engine.loadAsync`). So
**one side can be rebuilt while the other is on air** — the property the changeover rests on.

---

## 2. The concepts

- **Set** — one prepared "look": everything a performer sets up for one song or section.
  It lives on **one side** of the rig (a pair of channels and their sub-mix), but is
  stored **side-relative** ("first channel / second channel / mix") so it can load onto
  whichever side is free.
- **Setlist** — the run of show: an ordered list of Sets, saved in the show file.
- **On air / off air side** — at any moment Program shows one sub-mix (bus 1 = A/B or
  bus 2 = C/D). The OTHER side is off air: its monitor (the sub-mix preview) is your
  **preview** of what's next, exactly like a switcher's Preview/Program.
- **Changeover** — preparing the next Set on the off-air side, then taking Program across.

### What a Set contains

| In the Set (per side) | Not in the Set (show-wide) |
|---|---|
| Both channels' sources: clip + in/out, loop mode, framing, playing; or a generator / ISF generator / camera with its parameters | Output routing, canvas, displays |
| Both channels' **Up Next queues** (and ADV/ROLL state, fallback) | Program chain (NTSC emulation), DATA BURN |
| The side's **effect chain** — cards, order, every copy's values and on/off, FX focus | Clock source (Internal / audio) |
| The side's 4 **Clip Pads** | Hot Punch, preferences |
| **BPM** (optional) and subdivision | MIDI mappings — global by default (§8, Q2) |
| **Song binding** (optional, §6) | |
| **Changeover** in: transition, length in beats, quantise (§3) | |
| Name, colour, notes ("drop at 2:10") | |

---

## 3. The changeover — how it works, step by step

The rig already has two complete sides and a fader between them. A changeover is a DJ
deck swap:

```
            ON AIR                          OFF AIR
  Set 3 ── A/B ── bus 1 ──┐          C/D ── bus 2   ← Set 4 loads here, in the background
                           ├─ PROGRAM
                           │  (fader on 1)
```

1. **NEXT is known.** When Set 3 goes on air, Set 4 becomes NEXT.
2. **Prep, in the background, on the off-air side** (C/D here). Nothing on Program
   changes, and nothing waits on the tick:
   - clips open with the existing pre-open path (like ADV and the pads) — off the main thread;
   - the bus-2 chain is rebuilt to Set 4's cards (`rebuildChain(.two)` — bus 1 untouched);
   - values, switches, pads, queues and generators are written to bus 2's slots;
   - missing media is reported, not fatal: the Set shows ⚠ and which file.
3. **READY.** The GO key lights when everything is open and decoding. Set 4 is visible on
   the C/D Sub Mix monitor — you see the next look, live, before anyone else does. You
   can still touch it: it's a normal side.
4. **GO** (a key, a MIDI note, a song change — §6 — or a bar count): Program takes 1 → 2
   using Set 4's changeover-in: CUT, FADE or any Program transition, over N beats,
   quantised to the next bar (the beat-sync machinery CUT/FADE already have). At GO:
   - tempo changes to Set 4's BPM if it has one (at the downbeat, or ramped over the
     transition — Q4);
   - the FX panels, Source Controls and pads follow the new on-air side (so your hands
     land on what's on air);
5. **Swap roles.** When the fader lands, C/D is on air, A/B is off air. Set 5 starts
   prepping onto A/B. Repeat.

**BACK** re-preps the previous Set on the off-air side (a mistake is one GO away from
fixed). **HOLD** stops automatic triggers (§6) for when the DJ goes off-script.

### Full-rig Sets (all four channels)

A Set that needs A, B, C and D can't be prepared off air — there is no off-air side.
It gets a **bridge**: at GO, Program freezes on its current frame (or fades to a bridge
generator/black), both sides are rebuilt underneath, then Program reveals the new Set.
Not seamless, and the Setlist says so ("bridge") so it is a choice, not a surprise.
Recommended as phase 4; most Sets should be one side (Q1).

### Why not "open the next show file"

Opening a show today re-opens every clip and rebuilds both chains in one go, on air.
That is a scene change you watch happen. The side model means the audience only ever
sees a Program transition you chose.

---

## 4. Preparing a show — the workflow

1. **Build a look live** on either side as you do now.
2. **Capture → Set** (from the side's FX panel menu or ⌘-key): the side becomes a Set in
   the Setlist, named, coloured, with the current BPM.
3. In **Show mode** (a 4th mode, ⌘4, beside Import / VJ / Settings): the Setlist as a
   list — reorder, rename, notes, BPM, song binding, changeover-in per Set, what's
   missing. Select a Set and **Stage** it: it loads onto the off-air side for editing;
   **Update Set** writes your changes back. Rehearsal never touches the on-air side.
4. **In VJ mode**, the Setlist is an **Asset Browser tab ("Sets")** — no layout change:
   NOW / NEXT, ready state, a countdown when a trigger is armed, drag to reorder, double-
   click to make a Set NEXT. The GO key and a compact NOW › NEXT readout go in the bottom
   status strip (spare space; nothing moves). GO learns to MIDI with Shift-click.

---

## 5. BPM per Set

A Set's tempo comes from one of (Set setting):

1. **Fixed** — a number in the Set (captured from the transport, editable).
2. **From the song** — Music's own **BPM** field for the bound track (Music ▸ Get Info
   ▸ BPM; read over AppleEvents: `bpm of current track`). Empty in Music → falls back to 3.
3. **Detect** — BeatNet (existing) listens after the changeover.
4. **Keep** — leave the transport alone.

Applied at GO: at the downbeat of the changeover, or ramped across it (Q4). Beat-armed
things (pads, heal every, sweeps, LFOs) follow the transport as they do now.

---

## 6. Binding Sets to songs in Music ("iTunes")

Music is still scriptable as `Music.app`; the app already has the Automation permission.

- **Bind a Set to a song**: in Show mode, "Bind to Current Song" (the track playing in
  Music) or pick from Music's library. Stored as the track's **persistent ID** (stable
  across renames), with title/artist as a fallback and for display. One Set can be bound
  to several songs; one song to one Set.
- **Bind the Setlist to a Music playlist** (optional): the Setlist order follows the
  playlist; each playlist song ↔ a Set.
- **Follow Music** (toggle, with HOLD to suspend):
  - When Music starts a song bound to a Set, that Set is taken (if it isn't prepared yet,
    it becomes NEXT and is taken the moment it is READY).
  - **Landing on the song change**: the watcher knows position and duration. Near the end
    of a song (remaining < changeover length + margin) polling goes from 1 s to 4×/s,
    and GO fires early enough that the transition **completes on the new song's first
    beat**, not a second after Music has moved on.
  - Songs with no bound Set: nothing happens (or "advance to next Set" — setting).
- **Spotify**: title/artist binding only (no persistent ID over AppleScript that we rely
  on); same follow behaviour.
- **DJ software (Engine DJ, Rekordbox)**: out of scope here; the Now Playing hub is where
  such a source would plug in (docs/NOW-PLAYING-SOURCES.md).

The watcher changes are small: two more fields in the AppleScript (`persistent ID`,
`bpm`), and a faster poll while a follow trigger is armed.

---

## 7. Data model (Core)

```
Setlist            { sets: [SetItem], followsMusic: Bool, musicPlaylist: MusicRef? }
SetItem            { id, name, colour, notes,
                     footprint: .side | .fullRig,
                     snapshot: SideSnapshot,          // side-relative
                     bpm: BPMSource,                  // .fixed(Double) | .song | .detect | .keep
                     songs: [MusicTrackRef],          // persistentID + title/artist
                     changeoverIn: Changeover }       // transition, beats, quantise
SideSnapshot       { channels: [0: TemplateChannel, 1: TemplateChannel],
                     upNext: [0: Playlist, 1: Playlist],
                     chain: EffectChain, values: [relative slot: [code: value]],
                     pads: [ClipPad?] (4), focus }
```

- **Side-relative addressing** is the one genuinely new mechanism: a `SideMap` that turns
  "first channel / second channel / mix" into A/B/one or C/D/two, and back, for slots
  (`fx.a.colour` ↔ `fx.c.colour`), channel letters and pad indices. Pure logic, unit-tested.
- Saved in the show file as **template v5** (`setlist`). v4 files open with no Setlist.
  The Up Next queues also start saving (they don't today).
- `TemplateDocument` capture/apply is split so it can capture/apply ONE side.

---

## 8. What needs deciding in the engine

- **Prep must never cost a frame.** Clip opens are already off-thread. Chain rebuild on
  the off-air bus runs `makeChainNode` on the main thread — to be measured; if an ISF or
  datamosh node is expensive to create, creation moves off-thread and only the edge swap
  happens on a tick. Gate: `selfqa changeover` under the HD soak, 0 dropped frames.
- **MIDI mappings are slot-addressed today** (a knob → `fx.a.colour/…`). After a
  changeover your controller would still drive the now OFF-air side. Proposal: a mapping
  can be **"on-air side"** (ON-AIR.ch1.colour) as well as fixed — resolved at every GO.
  Phase 4, but it is what makes a two-sided show playable from one controller (Q2).
- **Library panels** (A/B Library, C/D Library) keep showing their own side; a Set can
  carry which bin each shows.

---

## 9. Naming

"Playlist" already means a channel's queue in the code and the library tabs. To keep
the words straight:

- the existing per-channel queue is labelled **Up Next** in the UI (the code already
  calls its semantics "Up Next");
- the new things are **Set** and **Setlist** ("Show" for the mode). "Playlist" is kept
  for Music's playlists, which is what it means to everyone else.

---

## 10. Build plan (each phase ships working, behind a flag until its gate passes)

| Phase | Scope | Gate |
|---|---|---|
| **0 — Groundwork** | `SideMap` + tests; side capture/apply of `TemplateDocument`; Up Next saved in the show (v5); rename the UI's "playlist" to Up Next; measure off-air `rebuildChain` | Core tests; `selfqa template` round-trips queues |
| **1 — Setlist + manual changeover** | Set model, Capture → Set, Show mode (list, reorder, notes, Stage/Update), Asset Browser "Sets" tab, prep NEXT on the off-air side, READY, GO/BACK (key + MIDI) with changeover-in, panels follow on-air side | `selfqa changeover`: 10 GOs under HD soak, 0 dropped, prep never on the tick, NEXT visible on the off-air monitor before GO |
| **2 — BPM per Set** | fixed / song / detect / keep; at downbeat or ramped | Core tests; tempo lands on the GO bar |
| **3 — Music binding** | persistent ID + BPM in the watcher; bind Set ↔ song(s), Setlist ↔ Music playlist; Follow Music, HOLD, landing on the song change; Spotify by title | mocked `NowPlayingHub` in self-QA: song change → Set on air within one beat of the new song |
| **4 — Full-rig Sets + on-air mappings** | 4-channel Sets with a bridge; mappings that follow the on-air side; auto-advance by bars/time | `selfqa changeover` full-rig case; controller follows the on-air side |

Rough size: phase 0 ~1 day, 1 ~3–4 days, 2 ~½ day, 3 ~2 days, 4 ~2–3 days.

---

## 11. Questions for the owner

1. **Footprint.** Do most of your sets fit on one side (two channels + their FX), with the
   other side free for the next? Or do you usually need all four? (Decides whether full-rig
   bridges are phase 4 or phase 1.)
2. **MIDI.** One controller layout for the whole show, and it should follow whatever is on
   air? Or different mappings per set?
3. **Music.** One song ↔ one set, or several songs per set? Do you build the show as a
   Music playlist already (so the Setlist can just follow it)?
4. **The changeover feel.** Default transition and length (e.g. FADE over 4 beats, on the
   bar)? Tempo: jump at the downbeat or glide across the transition?
5. **Names.** Set / Setlist / Show mode — or would you rather "Scene" / "Cue"?
