# Clip Pads

Designed with the owner 2026-09-28 ("Hot zones. Think of a better name."). Name chosen
by the owner: **Clip Pads**.

## What it is

Eight pads in the top bar, flanking the tempo cluster: **1–4 left of it, 5–8 right of
it**. Drag a clip from any library onto a pad and its thumbnail embeds, with the pad's
number. Pressing a pad puts its clip into a source at once — no stall, no glitch.

```
[Panels]   [A|B] (1)(2)(3)(4)   ‹ tempo cluster ›   (5)(6)(7)(8) [C|D]   [Detect][Panels]
```

- **Empty pads** are very subtle recessed wells — they read as texture until a clip
  is dropped, never as a row of empty buttons.
- **The side switch** at the outer end of each side chooses the source that side's
  pads load into: **A or B** on the left, **C or D** on the right.

## Pressing a pad

| Gesture | What happens |
|---|---|
| Click, or number key 1–8 | Loads the pad's clip into its side's source. Plays or stays paused per that source's AUTO (auto-play) setting. |
| Again, while that clip is the one loaded there | Resets playback to the head (the in point when trimmed). |
| ⌥-click, or ⌥ + number key | Loads, PLAYS, and CUTS that sub-mix to the source (A/B fader to A or B; C/D to C or D). Beat-sync cut if BEAT is on for the bus. |
| ⌥⌘-click | Arms the pad on the beat (same gesture as CUT/FADE): the blue rate box appears on the pad and it fires at that rate, locked to the clock. ⌥⌘ again disarms. |
| Shift-click | Learns the pad to a MIDI key, like every other control. |
| Right-click | Clear Pad. |

Number keys act in VJ mode only, and never while typing in a field. ⌘ and ⌃ combinations
pass through untouched (⌘1–3 are the mode keys).

## Hot Punch — the (!) key (owner, 2026-09-28)

A toggle in the toolbar's right group, captioned **Punch**, just inside Detect. The
broadcast name for "a source press goes straight to air" is a *hot punch*; "Push" was
avoided because Push is already a transition on the Program fader.

- **Off** (grey (!)): pads behave as in the table above.
- **Armed** (solid red (!), like record): every pad press — click, number key or MIDI
  press — is a take AND a Program cut: load, play, cut the sub-mix to the source (A/B
  to A or B, C/D to C or D), and cut Program to that bus (1 for A/B, 2 for C/D). Always a
  hard cut, whatever CUT/FADE says: the point is the picture now.
- Pads firing on the beat (⌥⌘) never punch — no hand pressed them.
- Shift-click learns it to a MIDI note; a note toggles it (6BJ).
- Settings ▸ Defaults ▸ **Hot Punch armed at launch** (off by default). The armed state
  is not saved in the show.
- It sits at the inner end of the right group, which is pinned to the window edge, so
  Detect and Panels do not move. The pad strips hide ~40 pt sooner in a narrow window;
  the (!) key never hides.

## Ready in memory

Each loaded pad keeps its clip **opened and decoding ahead** (the same pre-open ADV
uses), for the source its side currently targets. A press swaps it in (~1 ms on the
main thread); the pad immediately opens a fresh copy in the background so the next press
is instant too. Flipping a side switch re-opens that side's pads for the new source in
the background. If a press ever beats the background open, it falls back to the normal
off-main-thread load — never a blocking one.

## Control codes (ParamCode 6xJ / 6xK, slot `clipPads`)

- 61J–68J — pad 1–8 press (momentary): load / reset.
- 61K–68K — pad 1–8 take (momentary): load, play, cut — MIDI's ⌥-press.
- 69J — left side switch (0 = A, 1 = B). 6AJ — right side switch (0 = C, 1 = D).
- 6BJ — Hot Punch (momentary): toggles it.

## Saved with the show

The pads' clips (path, in/out), side switches and beat arming save in the show template
(`clipPads`), so a set loads with its pads.

## Not in this version

Rearranging pads by dragging one onto another; pads on a second bank/page.
