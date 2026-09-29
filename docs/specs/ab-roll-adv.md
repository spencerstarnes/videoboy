# A/B ROLL + ADV — take-driven playout on the sub-mix faders

Design agreed with the owner 2026-09-24 (session 094bb650); built 2026-09-27.
Flag `FeatureFlag.abRoll` (ON: it only adds two keys, which start OFF).

## Behaviour
Two independent keys on the **A/B and C/D** faders (program fader later):
- **ROLL** (when): the incoming source rolls (plays) when a take STARTS (a fade
  dissolves in moving); the outgoing source pauses and re-cues to its head (in point
  when trimmed) once fully off air.
- **ADV** (what): when a source leaves air it loads its next clip — its **Up Next
  queue first**, then the library fallback (Settings ▸ Defaults ▸ "Up Next empty"):
  Off · In order (a cursor down the panel's current sort and search, wrapping) ·
  Shuffle bin (the outgoing clip's bin) · Shuffle all. Never the clip on air opposite;
  missing files skipped; shuffles deal every clip before repeating.
- **Up Next REPEAT** (added 2026-09-29, owner request): each queue view has a REPEAT
  key, **on by default**. On, a clip taken from the queue (by ADV or a one-shot end)
  goes to the BOTTOM, so the queue cycles and the library fallback is reached only
  when the queue is empty. Off, a taken clip leaves the queue (the original rule).
  Per channel; not yet saved in the show (neither are the queues).
- **Up Next limit** (added 2026-09-29): each channel's queue holds at most N clips.
  Settings ▸ Defaults ▸ Up Next limit: **Auto** (from the Mac's memory at launch —
  1% of RAM across the four queue lists at ~150 KB per row, clamped 50–1000) or a
  number by hand. A selection is queued in ONE edit (one redraw, one ADV re-plan);
  clips past the limit are not added and the status strip says how many.

| ROLL | ADV | Result |
|---|---|---|
| off | off | Today's behaviour. |
| on | off | The two clips alternate; each rolls when taken and re-cues when it leaves. |
| off | on | Off-air side gets the next clip; AUTO (play on load) decides if it runs off air. |
| on | on | Classic A/B roll: next clip waits paused at its head, rolls on take. |

A take = CUT, FADE, a bus key, or their MIDI triggers, moving the bus to the other side.
A hand on the fader is not a take. With BEAT on, a cut's take happens when it lands.
When ADV falls back to the library the status strip says so (information, not a
warning), once per dry spell; Settings can turn that off. A failed load is a strip
notice, never a modal. Loading runs on the next run-loop turn, never inside the tick.

## Code
Core `Control/ABRoll.swift` (`ABRoll.take`, `NextClipPicker`, `ABRollFallback`) + tests;
param codes 6CA / 6DA (MIDI toggles); `FaderPanelBody(includesABRoll:)` keys in the
right-pinned options row (CUT/FADE/BEAT never move); `ShellController` take hooks in
`beginMove`, `updateFadesAndCuts` and `onCutTo`; Defaults pane settings.

## Self-QA `ab-roll`
Keys on A/B and C/D only; no existing fader-panel control moves; the four combinations
by real CUT presses; FADE settles only after the fade; BEAT settles on the beat;
queue before fallback, In order order, notice once; MIDI toggles; 10 ADV cuts under
live render with 0 dropped frames beyond the no-cut baseline and no tick over a frame.

## Not in this version
Program-fader ROLL/ADV; the "Then from" key on the library row (it is in Settings);
blinking the linked play key when ROLL starts a source (the key state is kept in step).
