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
- **Q2 — Queue memory limit.** "video boy seems to be crashing if I load too many
  things into the queue. I think the queue needs a limit on how many clips it loads
  at once. Right now it seems to just load everything, maybe we have a number that's
  automatically set by how much memory is available at launch. We can have a setting
  in the settings menu where you can manually define it."

## Queued
_(empty — next request goes here)_

## Awaiting verification
- **Q1 — Up Next REPEAT.** "a toggle to allow repeating on the queue … default to
  move the clip to the bottom of the queue and have an easy to see toggle in the
  queue to stop it." Built in `ad8d1f8` on `claude/wonderful-knuth-7x6t6w`.
  Not built or tested (Linux container, no Swift). Needs on the Mac Studio:
  `scripts/verify.sh` and `scripts/selfqa.sh ab-roll`, then tick the BUILD-PLAN item.

## Done
_(none yet)_
