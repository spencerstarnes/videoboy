# Request backlog

Every outstanding thing asked for, with how many times it was asked. Written at the
start of the three-hour run, worked top to bottom.

Recovery point before this run: tag `v0.8.0-pre-backlog`, branch
`recovery/pre-backlog`, both at **a895d34**.
Restore with `git reset --hard refs/tags/v0.8.0-pre-backlog`.

## Where the run got to

**Done:** A/B/BOTH on every effect · fader dead space · TRANSFORM · app icon · library
bins, folders-as-bins and a search that searches · mini luma scope · CUT/FADE MIDI
learning · now-playing model, templates and research.

**Not done, and why:** the live Apple Music adapter needs an Automation permission
granted at the keyboard (probed: `AppleEvent timed out -1712`), and the Engine DJ
adapter cannot be verified without the hardware. Per-app audio beat detection is
probed and viable but not built — it was the largest remaining item and I stopped
rather than leave it half-wired.

---

## Asked more than once — these come first

### 1. A/B/BOTH selector on EVERY effect — **asked 3 times**

> "every effect needs teh A B BOTH selctor on it"
> "the toggle that DV DIF Corruptor has on it needs to be univerasl for all effects"
> "please add A / B / BOTH toggles TO ALL EFFECTS."

Only the DV corruptor has one, because only it is a per-CHANNEL effect. Every other
effect is one node per BUS, downstream of the mix, so there is no A or B left to
point at by the time it runs.

**This is an architectural change, not a UI one**, and that is why it has been asked
three times without landing. Doing it honestly means each effect existing once per
channel rather than once per bus. Cost: 5 effects × 4 channels = 20 full-frame passes
instead of 10, inside a 33.4 ms budget. Plan: instantiate per channel, have the
selector choose which instance the card edits, and BOTH write to both — the model the
corruptor already uses. Measure the frame cost before committing to it.

### 2. Dead space on the faders / libraries can be taller — **asked twice**

> "fix the dead space on the faders, the libraries can be taller."
> "theres too much extra room on the botton of the faders."

The fader panel has slack under its row that the library below could use.

### 3. CUT button — **asked ~10 times** — DONE (`13148eb`)

Recorded here because it went unbuilt for so long. The bus keys cut TO a named source;
there was no key that simply takes the other one.

---

## Asked once, clearly specified

### 4. TRANSFORM effect
Rotate, scale, flip horizontal, flip vertical. (Asked as "Scale", renamed to
TRANSFORM in a follow-up.)

### 5. Library bins
Right-click to add a bin, a `+ folder` button in the upper right, **folders dropped in
become bins automatically**, icons should fill the panel, and **search is broken**.

### 6. App icon
A simple test pattern in a circle, with "VB" in the camcorder face in the middle.

### 7. Mini LUMA scope
First click of Scopes shows a small luma scope overlaid in the lower-right of the
picture, rather than going straight to a full scope.

### 8. Shift-select MIDI for ACTION buttons
Shift-to-map currently reaches faders only. It should also reach CUT, FADE, FLIP,
FLOP — momentary actions, not continuous parameters, so the mapping stores a trigger
rather than a value.

### 9. Per-app audio beat detection — BUILT 2026-09-23
A third clock source: beat detection from ONE application's audio (Apple Music), the
way VDMX offers system hardware or a single app.
**Built** on Core Audio process taps (`SystemAudioTap`): CLOCK ▸ System Audio, Audio
Input, or any running app with audio open. The tracker was rewritten at the same time
(`BeatTracker`) and the unbuilt MIDI clock / Link choices removed from CLOCK.

### 10. Now-playing overlay + Engine DJ
Song title, album art, album title, progress bar, a few templates matching the app's
vibe, and an option to fade in and out only when the track changes. Plus: research
whether Engine DJ exposes a protocol over USB or Wi-Fi that could feed the same
overlay. **Needs research before building.**

---

## Open questions I will not guess at

- **"COLOUR should be defaulted to the first one"** — could mean its selector's first
  option (A) or first position in the chain. I defaulted it ON, which was the
  unambiguous half, and left the ordering alone.
- **In and out points on faders "not letting me set the second point"** — I could not
  reproduce it. Marking, colour-fader specifics and hit-testing all pass in the
  harness. Needs a look at the real app to see what differs.
