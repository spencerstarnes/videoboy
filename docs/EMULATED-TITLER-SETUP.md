# Emulated titler — what you need to supply

The architecture is built and tested. It cannot be *finished* from here, and this
says exactly why and exactly what unblocks it.

## Why I stopped short of a running Broadcast Titler

Three things are needed, and all three are yours to supply rather than mine to fetch:

| What | Why I cannot provide it |
|---|---|
| A libretro Amiga core (`puae_libretro`) | **GPL.** CLAUDE.md requires cores run out-of-process and never linked; linking one would relicense this whole app. It is installed, not shipped. |
| An Amiga Kickstart ROM | **Copyrighted.** Must come from an Amiga you own, or a licensed copy such as Cloanto's Amiga Forever. |
| Broadcast Titler II disk images (`.adf`) | **Copyrighted.** Same — supplied by whoever owns the software. |

None are present on this machine: no core, no emulator installed, no ROM, no disks.
That is a genuine blocker for the end-to-end path, and per the repo's own rules I have
written it down rather than thrashing at it.

## What IS built and tested

- **A core system, on libretro's model** (`CoreLibrary`). Discovers what is installed,
  reports what each core still needs, and says what to DO about it rather than only
  that something is wrong. 6 tests.
- **The emulator as a graph SOURCE** (`EmulatedTitlerNode`), so once it runs it can be
  assigned to a channel and overlaid like anything else — which is the point.
- **Boot recipes as data** (`TitlerBootStep`), for Broadcast Titler II, Deluxe Paint IV
  and Scala. Recipes rather than scripts, so they can be edited by someone who does not
  write Swift and checked without an emulator.
- **The translation layer** — a modern text box driving vintage software, tested by
  asserting typed text arrives at the program. 11 tests.
- **Graceful absence.** Every path degrades to a labelled state. Typing at an emulator
  that is not there does nothing and says why; it never crashes.

## Setting it up

1. Put the core in `vendor/cores/` (`puae_libretro.dylib`; a `.so` copied from another
   machine's RetroArch folder is accepted too).
2. Put the Kickstart in `vendor/system/` as `kick34005.A500.rom`.
3. Put the Broadcast Titler `.adf` files somewhere and point the program entry at them.
4. The EMU tab will then list Broadcast Titler II as runnable instead of blocked.

## The one design decision worth knowing

**Boot recipes land via a SAVE STATE, not timed keystrokes.** Driving a boot by waiting
and pressing keys is fragile — a disk that loads a second slower puts every later step
in the wrong place, and you get a program sitting at the wrong screen with text being
typed into nothing.

So the intended flow is: boot the software once by hand, get it to the text-entry
screen, save a state, and land there every time after. That is what
`.loadState(named:)` is for, and there is a test asserting every program uses one.

## What I have NOT verified, and will not claim

No part of the actual emulation has been run. I have no core, so I have never seen
Broadcast Titler boot, never confirmed a save state lands where it should, and never
seen a frame come out of a real emulator. The mock proves the plumbing; it proves
nothing about the emulator.

When you supply the three assets, the first thing to check is whether a frame reaches
the preview at all — everything else is downstream of that.
