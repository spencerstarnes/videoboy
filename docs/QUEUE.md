# Task queue

The one queue for all work on Videoboy (rule set by the owner 2026-09-29). Every
request goes here before any work starts; nothing is worked outside it.

## Rules
1. **Every new request is appended** to *Queued* as its own numbered item, in the
   order received, before work begins. The owner's words are quoted verbatim.
2. **Worked top to bottom, one at a time.** Only the owner reorders or reprioritises.
3. **One item In progress at a time.** It moves to *Done* only when committed and
   pushed, with the commit hash and how it was verified. Work that could not be
   verified (no Mac build, no hardware) says so and goes to *Awaiting verification*.
4. Items are never deleted. A dropped item moves to *Done* marked "dropped by owner".

## In progress
_(none)_

## Queued
_(empty — next request goes here)_

## Awaiting verification
- **Q2 — Queue memory limit.** "video boy seems to be crashing if I load too many
  things into the queue. I think the queue needs a limit on how many clips it loads
  at once. Right now it seems to just load everything, maybe we have a number that's
  automatically set by how much memory is available at launch. We can have a setting
  in the settings menu where you can manually define it."
  Built in `adcf78f`. Cause found in code: queuing N clips was N full list rebuilds +
  N library re-sorts (quadratic). Fixed with one edit per gesture, in-place list
  updates, and a per-channel limit (Auto from RAM, or Settings ▸ Defaults). Not
  built or tested (Linux container, no Swift). Crash cause unconfirmed without a
  crash report. Needs on the Mac Studio: `scripts/verify.sh`,
  `scripts/selfqa.sh ab-roll` (step 4c), and a manual queue of 1,000+ clips.
- **Q1 — Up Next REPEAT.** "a toggle to allow repeating on the queue … default to
  move the clip to the bottom of the queue and have an easy to see toggle in the
  queue to stop it." Built in `ad8d1f8` on `claude/wonderful-knuth-7x6t6w`.
  Not built or tested (Linux container, no Swift). Needs on the Mac Studio:
  `scripts/verify.sh` and `scripts/selfqa.sh ab-roll`, then tick the BUILD-PLAN item.

## Done
- **Q3 — Design consult: Playlist / Set / Setlist, MIDI conflicts, where it lives.**
  Owner wants to perform song sections (e.g. King Gizzard "UQT": ~25 s movement,
  ~20 s build, ~1 min chorus, ~45 s bridge) with prepared clips per section, cuts on
  the beat within a section, and a manual hotkey (⌘→ / ⌘←) to advance to the next
  section, which cuts to the opposite bank, plays, and applies that section's
  settings. Proposed hierarchy: Playlist (clips) → Set (clips + automation +
  effects, one source pair, default A/B) → Setlist (ordered sets). Concern: MIDI
  mappings conflicting across sets. Pitch: a hidden-by-default panel under Program,
  maybe a pop-out from the Asset Browser like AVE-5. Asked for senior-dev feedback.
  Answer only; no code.
  Answered in chat 2026-09-29 (no code). Recommendation: keep the rig-addressed
  MIDI model; add a show-wide macro layer that each Set assigns; Sets side-relative;
  ⌘→ GO / ⌘← BACK; docked, not a popover. Next step if approved: fold the decisions
  into `docs/PROPOSAL-2026-09-28-setlist.md`.
  Follow-up (same day): owner asked for a critical review of that answer. Reviewed in
  chat; corrections: drop the 4th level, rename Set→Scene, BACK always re-preps (no
  grace window), ⌘←/⌘→ must yield to text fields, macros are a target type in the
  one mapping table (not a second system), a Scene's clip list deals into the
  existing Up Next queues.

