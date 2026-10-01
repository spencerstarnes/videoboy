# Proposal — Queues, Playlists and Setlists (2026-09-28, revised 2026-09-29)

Status: **DRAFT.** Set by the owner on 2026-09-29 and normative: the names and rules
(§1–§4, including the Start Up Sequence), song linking (§6), LOCK with the top-bar
Setlist strips (§7) and the Asset Browser Lists tab (§8). The questions in §10 are still open. Nothing is built.

Owner's brief: "prepare workspaces and loaded settings, clips, queue, generators … how do
we seamlessly transition from one set to another … a setting for binding playlists to
songs in iTunes. Playlists can also contain BPM info."

Revision note: the 09-28 draft's "Set" (one bank's look) and "Setlist" (run of show)
are gone. What that draft called a Set is now a **Setlist**. A run-of-show list is not
part of this design unless song linking needs one (§6).

---

## 1. The names

| Name | What it is | Scope |
|---|---|---|
| **Queue** | The live list of what a channel plays next. **Play Next** drops files here. | One per channel (A, B, C, D) |
| **Playlist** | A saved, pre-configured Queue. | Loads onto one channel |
| **Setlist** | Two Playlists plus that bank's effects and punch-bar pads. | Loads onto one bank |
| **Bank** | A pair of channels and their sub-mix: **A/B** (bus one) or **C/D** (bus two). | — |

Each word has one meaning. In the UI and in new code, "playlist" never means the live
queue, and "setlist" never means a run of show.

---

## 2. Queue

- Every channel has exactly one Queue.
- **Play Next** (library context menu, drag) puts a clip at the **front** of the Queue.
  It plays after the current clip and before anything already queued.
- **Play Last** (the existing "add" gesture) puts a clip at the **end** of the Queue.
- Playing an item takes it out of the Queue, so the front of the Queue is always the
  next clip to play (the existing rule in `Playlist.swift`).
- A channel in ONE SHOT pulls from its Queue when its clip ends. ADV takes from the
  Queue first. Loop and ping-pong ignore the Queue (unchanged).
- The Queue is part of the live rig. It is saved with the show file, which it isn't
  today.

## 3. Playlist

- A Playlist is a named, ordered list of clips (with in/out marks) saved for reuse.
- **Save Queue as Playlist…** captures a channel's current Queue.
- **Loading a Playlist onto a channel** fills that channel's Queue. The clip currently
  playing is left alone.
  - If the Queue is **empty**, the Playlist fills it. Nothing is asked.
  - If the Queue is **not empty**, an alert asks **Append** or **Replace** (or Cancel).
    The alert has a **"Do not remind me again"** box (a standard `NSAlert` suppression
    button). Ticking it saves the choice as the default for future loads.
  - Suppressing the alert must be reversible. The choice is saved as **Settings ▸
    Defaults ▸ Loading a playlist into a queue: Ask · Append · Replace**, and "Ask"
    brings the alert back.

## 4. Setlist

A Setlist is everything one bank needs for one section of a show:

| In a Setlist | Not in a Setlist |
|---|---|
| **Two Playlists**, one per channel (first and second) | **MIDI mappings and settings** |
| The bank's **effects**: which cards are loaded, their order, every value, on/off, and their **automation** (LFOs, sweeps, beat-armed moves) | Program chain (NTSC emulation), DATA BURN |
| The bank's **4 punch-bar pads** (the top bar's Clip Pads: 1–4 for A/B, 5–8 for C/D), with marks and flip rates | Output routing, canvas, displays |
| Name | Clock source, preferences, Hot Punch armed state |

- **Setlists are relative to the bank.** A Setlist stores "first channel / second
  channel / this bank's effects / this bank's pads", not letters. It loads onto the bank
  you load it **from**. Loaded from the A/B side, it fills A, B, bus one's effects and
  pads 1–4. Loaded from the C/D side, it fills C, D, bus two's effects and pads 5–8.
- **Save Bank as Setlist…** (from that bank's FX panel or library menu) captures the
  bank's two Queues as its Playlists, plus its effects and pads.
- **Loading a Setlist onto a bank:**
  - the bank's effects are **replaced** by the Setlist's (cards, values, automation);
  - the bank's 4 pads are **replaced**;
  - each channel's Queue follows the **Playlist rule** (§3): Append or Replace, as asked or
    as the saved default;
  - the other bank, MIDI mappings and the Program chain are **not touched**.

### Changing over without a visible jump

Engine facts this rests on (verified 09-28): `Engine.rebuildChain(bus)` touches only
that bus, and clips open off the main thread.

- The seamless changeover is: **load the next Setlist onto the off-air bank**, check it
  on that bank's Sub Mix monitor, then take Program across with the fader (CUT, FADE or
  a wipe, beat-quantised as now).
- Loading onto the **on-air** bank is allowed, and the change is immediate and visible.
  It is the performer's choice, and LOCK (§7) is how to protect a bank from it.
- Loading must never cost a frame: clips open on the existing pre-open path, and the
  off-air chain rebuild is measured (if creating a node is expensive, creation moves off
  the main thread and only the edge swap happens on a tick).

### Start Up Sequence (owner-set 2026-09-29)

Each Setlist has a **Start Up Sequence**: what happens once it has loaded onto its bank.
You choose it from the Setlist's context menu: **Start Up Sequence ▸** is a submenu with
one ticked choice.

| Start Up Sequence | Once the bank is ready (clips decoding) |
|---|---|
| **Punch** *(default)* | Program **cuts** to the bank, as Hot Punch does for a pad. |
| **Cue** | Nothing on Program changes. The Setlist waits on its bank and shows on that bank's Sub Mix monitor. You take it with the Program row (1/2, CUT, FADE) as usual. |
| **Crossfade** | Program **fades** to the bank at the Program row's current FADE rate, beat-quantised as FADE already is. |

- The same sequence runs whether the Setlist was loaded by hand (Load to A/B / C/D) or by
  a linked song (§6.3).
- Punch and Crossfade onto the bank that's already on air have nothing to transition
  from, so the load shows immediately.

---

## 5. Data model (Core)

```
ClipQueue    { items: [QueueItem] }                     // today's `Playlist` struct, renamed
Playlist     { id, name, items: [PlaylistItem] }        // item: path + in/out marks
Setlist      { id, name,
               playlists: [first: Playlist, second: Playlist],
               effects: BankEffects,                    // chain, values, on/off, automation
               pads: [ClipPad?] (4),
               startUp: .punch | .cue | .crossfade,
               bpm: Double?,                            // nil = detect on song start (§6.3)
               song: MusicTrackRef? }                   // persistent ID + title/artist
BankMap      A/B/one/pads 1–4  ↔  C/D/two/pads 5–8      // "first/second/bank" ↔ letters, slots
```

- **Rename:** today's Core `Playlist` (the per-channel live list) becomes `ClipQueue`, and
  the UI says **Queue**. That frees `Playlist` for the saved kind.
- **`BankMap`** is the one new mechanism. It converts bank-relative addresses to real
  ones and back: channels, slots (`fx.a.colour` ↔ `fx.c.colour`) and pad indices. It is
  pure logic and unit-tested.
- `TemplateDocument` capture and apply are split so that one bank can be captured or
  applied on its own.
- The show file (template v5) starts saving the four Queues. v4 files open with empty
  Queues.

---

## 6. Song linking (owner-set 2026-09-29)

The design has two parts: Videoboy **listens** to Apple Music, and a Setlist can be
**linked** to a song.

### 6.1 Listening: Apple Music's track broadcast

- When Music is running, even in the background, it posts a distributed notification,
  `com.apple.Music.playerInfo`, every time a track starts, pauses or stops. Videoboy
  subscribes to it with `DistributedNotificationCenter`.
- The notification carries the track's name, artist, album, player state, total time and
  **persistent ID**. Videoboy doesn't poll or send AppleEvents to get these, and there is
  no Automation prompt. It reacts when the song starts, not up to a second later.
  *(The exact key names are checked against a real Music session in phase 3 before
  anything relies on them.)*
- If Music isn't running, nothing is heard and nothing happens. It's never an error.
- The existing AppleEvent poll stays for what the broadcast doesn't carry: the play
  position and artwork for the Now Playing generator, and Spotify.
- The broadcast is published through `NowPlayingHub`, so self-QA can post a fake song
  change without Music.

### 6.2 Linking: the Setlist's context menu

Right-clicking a Setlist in the Asset Browser shows:

| Item | Does |
|---|---|
| **Load to A/B** | Loads the Setlist onto bank A/B (§4 rules). |
| **Load to C/D** | Loads the Setlist onto bank C/D. |
| **Link to Current Song** | Links the Setlist to the song Music is playing now (see below). Greyed when Music isn't playing anything. |
| **Start Up Sequence ▸** | Punch · Cue · Crossfade: what happens once it has loaded (§4). |
| **Rename** | Renames the Setlist in place. |
| **Copy** | Makes a copy named "<name> copy". |
| **Delete** | Deletes the Setlist after asking for confirmation. |

**Link to Current Song** opens an alert before it links anything:

> **Link “<Song>” by <Artist> to “<Setlist>”?**
> Linking a song to a setlist makes the setlist play as soon as that song starts in
> Apple Music.
> [Cancel] [Link]

- The link is stored by the track's **persistent ID**, so renaming the song in Music
  doesn't break it. Title and artist are kept for display.
- A linked Setlist shows its song in the Asset Browser (for example ♪ “Song” — Artist).
- **Linking is reversible.** On a linked Setlist, the menu item reads **Unlink “<Song>”**.
- One song links to one Setlist. Linking a song that's already linked elsewhere moves the
  link, and the alert says so.

### 6.3 When a linked song starts (owner-set 2026-09-29)

1. **Destination: whichever bank is off air** at that moment. If Program is on 1 (A/B),
   the Setlist goes to C/D, and the other way round.
2. **Load.** The Setlist loads onto that bank by the §4 rules. Clips open off the main
   thread, and the effects and pads are replaced there. Program doesn't change.
3. **Beat.** If the Setlist has a **BPM programmed in**, the transport takes it. If it
   doesn't, Videoboy **rechecks the beat**: it runs the existing Detect (BeatNet) on the
   new song, as if Detect had been pressed.
4. **Start Up Sequence.** Punch (the default) **cuts** Program to the bank. Cue and
   Crossfade behave as in §4.

The picture on air doesn't change until step 4, and the audience sees only that
transition.

**Detect doesn't hold up the cut** (owner, 2026-09-29). The cut happens as soon as the
bank is ready, well under a second after the song starts. Detect keeps listening, and
things tied to the beat (pads, sweeps, LFOs) settle when it locks.

**When nothing happens.** The off-air bank is **locked** (§7): the song is skipped, the
Setlist strip (§7) shows "Locked — skipped ‘Song’", and a `[setlist]` log line is written.
Locking both banks therefore works as the off switch for when the DJ goes off-script.

### 6.4 BPM

A Setlist's BPM is optional. **Save Bank as Setlist…** has a "Save tempo (120.0 BPM)"
checkbox, which is off by default. A Setlist with no BPM detects the beat when its song
starts (§6.3 step 3). Music's broadcast doesn't carry Music's BPM field, so that field
isn't used.

---

## 7. Top bar: the Setlist strips and LOCK (owner-set 2026-09-29)

Each side of the top bar gets a small **Setlist strip** between its Clip Pads and the
centre cluster:

```
[Panels]   [A|B] 1 2 3 4   [🔒 LOCK │ Setlist name ♪]   (● ▶ 120.0 BPM …)   [♪ Setlist name │ 🔒 LOCK]   5 6 7 8 [C|D]   [Punch] [Detect] [Panels]
```

- **LOCK**: a push-on/push-off key with an SF Symbol (`lock.open` / `lock.fill`).
  It's red when locked, like Record and Hot Punch, and can be learned to a MIDI key with
  Shift-click like every other control.
- **Setlist name**: which Setlist is on this bank, its state (CUED while a Cue Setlist
  waits; nothing extra once on air), ♪ when it is linked to a song, and messages such as
  "Locked — skipped ‘Song’". Read-only; you manage Setlists in the Asset Browser.

### What LOCK freezes

LOCK on the A/B side freezes **everything that can change the A/B side's picture**:

| Locked (ignores clicks, keys and MIDI) | Keeps working |
|---|---|
| Sources A and B (play, loop, marks, FIT, shuttle, what's loaded) | The picture: clips keep playing, and effect automation (LFOs, sweeps, beat-armed moves) keeps running |
| The A/B FX panel (cards, values, add/remove, A · B · MIX focus) | The **Program** row (1/2, CUT, FADE, fader), so you can still take the locked bank to air or away from it |
| The A/B Sub Mix row (A, B, CUT, FADE, ROLL, ADV, the fader) | The transport, clock, Detect |
| Pads 1–4 and the A/B pad switch | The C/D side, unless it is locked too |
| Loading into A or B (library drag or double-click, Play Next, Queue changes, pads) | Monitors and their scope toggles (WFM, RGB …), which change only the view |
| Setlist loads onto A/B, both by hand (menu items greyed) and by linked songs (skipped, §6.3) | Settings and MIDI mapping |

- **How locked controls look** (owner, 2026-09-29): controls keep their normal look, so you can still read
  them. The locked panels' title bars show a padlock, and touching a locked control
  blinks that side's LOCK key to say why nothing happened. Controls aren't greyed out,
  because greyed-out already means "not available".
- The locked state isn't saved: Videoboy always launches unlocked. It's never part of a
  Setlist.
- Rules live in Core (`BankLock`: which slots and codes a locked bank refuses), so they
  are unit-tested. The App asks it before acting on a click and before applying MIDI.

### Layout consequences (the owner has asked for this move)

- The pads are anchored to the cluster, so each strip pushes its pads **outward by the
  strip's width** (about 140 pt with LOCK and a short name). This is the one deliberate
  move of existing controls, and `docs/specs/clip-pads.md`, SPEC §14 and
  `layout-v6.html` are updated to match.
- Nothing else moves. Record, Play, the tempo display, Punch, Detect and Panels stay put.
- In the 1460 pt `wide.png` window, the right side has only about 60 pt to spare, so the
  pads would hide at roughly **1,650 pt** instead of 1,460 (an estimate, to be measured).
  When space runs out the **pads hide first. LOCK never hides**, because it is a safety
  control.

---

## 8. Asset Browser: the Lists tab (owner-set 2026-09-29)

Playlists and Setlists share one category of their own, shown as a tab in the **middle
Asset Browser**. The A/B and C/D Library panels don't get it.

- **Storage:** both live in the **library catalog** (`Catalog`, SQLite), not in a show
  file. They can be reused in every show, just as clips are. `LibraryModel` writes them
  through on its own queue, as it does for clips, and never on the main thread.
- **The tab:** a new segment, **Lists** (name to confirm, Q1), added at the **end** of the
  tab row after EMU. The segmented control is anchored at its leading edge, so appending
  a segment moves no existing tab.
  - *Width to measure:* in the 1460 pt `wide.png` window, the six tabs already fill most
    of the browser's top row, and the control won't compress. Phase 2 measures whether a
    seventh fits. If it doesn't, the tab row gets the space it needs before anything
    else is changed.
- **Inside the tab:** one list with two **group rows**, **Setlists** and **Playlists**,
  in the standard `NSTableView` group-row style. Each row shows:
  - Setlist: name, ♪ linked song, Start Up Sequence (Punch / Cue / Crossfade), tempo if
    saved, ⚠ if a clip is missing;
  - Playlist: name, number of clips, total length, ⚠ if a clip is missing.
- **Context menus:**
  - Setlist: the §6.2 menu.
  - Playlist: **Load to A**, **Load to B**, **Load to C**, **Load to D** (§3 Append/Replace
    rule), **Rename**, **Copy**, **Delete**.
- **Drag:** a Playlist dragged onto a source loads it into that channel's Queue, following
  the same Append/Replace rule. Dropping onto a locked side is refused.
- **Search:** the browser's search field filters this tab by name and by linked song.
- Saving (**Save Queue as Playlist…**, **Save Bank as Setlist…**) selects the new item in
  this tab, so you can see where it went.

## 9. Build plan (each phase ships working, behind a flag until its gate passes)

| Phase | Scope | Gate |
|---|---|---|
| **0 — Names + Queue** | `Playlist` → `ClipQueue` in Core; UI says **Queue**; Play Next / Play Last wording; Queues saved in the show (v5) | Core tests; `selfqa template` round-trips Queues |
| **1 — LOCK** | `BankLock` in Core + tests; a LOCK key per side in the top bar; clicks, keys and MIDI refused on a locked side; padlock in locked panels' title bars; the LOCK key blinks when a locked control is touched | Core tests; `selfqa ui` through `hitTest`: every A/B control refuses while locked, Program still takes; the picture keeps running; no existing control moves except the pads (frames asserted) |
| **2 — Playlists + Lists tab** | Playlist model + catalog storage; the Asset Browser **Lists** tab (§8), with the tab-row width measured; Save Queue as Playlist; Playlist context menu and drag; load onto a channel; Append/Replace alert with suppression; Settings ▸ Defaults preference | Core tests for append/replace; `selfqa ui` drives the alert, suppression and the preference that restores it |
| **3 — Setlists** | `BankMap` + tests; bank capture/apply; Save Bank as Setlist (optional tempo); Asset Browser context menu (Load to A/B / C/D, Start Up Sequence ▸, Rename, Copy, Delete); Punch / Cue / Crossfade; Setlist name in the top-bar strip; locked banks refuse loads | `selfqa setlist`: an A/B Setlist loaded onto C/D lands on C, D, bus two, pads 5–8; each Start Up Sequence does what §4 says; 10 loads onto the off-air bank under the HD soak, **0 dropped frames** |
| **4 — Song linking** | `playerInfo` listener → `NowPlayingHub` (key names checked on a real Music first); Link to Current Song + alert; Unlink; song start → off-air bank → BPM or Detect → Start Up Sequence; skipped when locked | mocked hub: a fake song change puts the linked Setlist on air with **0 dropped frames**; locked off-air bank → skipped and shown; `selfqa ui` drives the menu and the alert through `hitTest` |

LOCK comes first because it doesn't depend on anything else, it's useful the day it
ships, and it's what makes an automatic song trigger safe to use.

Rough size: phase 0 ~½ day, 1 ~1½ days, 2 ~1½ days, 3 ~3½ days, 4 ~1½ days.

---

## 10. Questions for the owner

Decided 2026-09-29: the cut doesn't wait for Detect (§6.3); locked controls keep their
look (§7); Playlists and Setlists live in the catalog under their own Asset Browser tab
(§8).

1. **The tab's name.** "Lists" (recommended: short, and it covers both), or "Setlists",
   "Shows", or something else?
2. **Does a Setlist copy its Playlists or point to them?** A **copy**, frozen when the
   Setlist is saved, means later edits to a Playlist can't change a Setlist you've
   rehearsed (recommended). A **pointer** means editing a Playlist updates every Setlist
   that uses it.
3. **Narrow windows** (§7): pads hide first and LOCK never hides (recommended). Or keep
   today's rule, where the pads and everything beside them hide together?
4. **Hot Punch.** Its armed state is treated as show-wide, not per Setlist. Is that right?
