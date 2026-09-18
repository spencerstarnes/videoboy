# Blocked: Scala MM300 will not start under AROS

**Status:** everything around the titler works. The titler itself does not run, and the
one remaining variable is a Kickstart ROM, which is copyrighted and has to come from
you.

**What you need to do:** put a Kickstart 3.1 ROM in
`~/Documents/FS-UAE/Kickstarts/`. The app looks there, uses it without being asked, and
falls back to AROS when it is absent. Nothing else needs changing.

---

## The failure

```
Error 4: Can't open device: scalamm.gfx
```

`scalamm.gfx` is Scala's graphics engine — a 1995 Amiga device that `scalamm.sys` loads
on startup. Under AROS it is found and refuses to initialise.

## What has been ruled out

Each of these was tested, not reasoned about. Please do not spend time on them again.

| Suspected | Result |
|---|---|
| The file is corrupt, or the copy off the ISO mangled it | No. Valid Amiga HUNK binary (`0x000003F3`), and **byte-identical** to the copy inside the disc's own `Scala.lha` installer. The CD's `Scala/` directory *is* a real install. |
| It is not on `DEVS:` | It is. `OpenDevice` searches `DEVS:` by name and does not look in sub-drawers, so the modules are copied there at boot. An earlier `Assign DEVS: SYS:Scala/System ADD` was actively wrong — it resolved to `System/System/scalamm.gfx`. |
| The working directory is wrong | No. The startup does `CD SYS:Scala`, so the relative `System/scalamm.gfx` inside `scalamm.sys` resolves. |
| The copy protection dongle | Scala MM300 is dongle-protected and this error is what that protection looks like when it fails — so this was the strongest lead. FS-UAE 3.2 knows eight dongle types and Scala is not among them, so its `dongle_type` was silently ignored. **Amiberry's WinUAE 4.x core has `scala green`, it is configured, and the error is unchanged.** Necessary, not sufficient. |
| The chipset | Tried AGA and ECS. No difference. It is 1993 software, so ECS is the better default and is what the config now uses. |
| AROS being old | FS-UAE ships a 2015 AROS, Amiberry a 2025 one. Identical failure on both. |
| **The Scala version** | **Tested. MM400 (1996) fails identically to MM300 (1993): `Error 4: Can't open device: scalamm.gfx`.** MM400 was the strongest remaining lead, because it is reported to be far less fussy about OS version — and it makes no difference. Two releases three years apart, failing the same way, isolates the variable to the ROM. |
| The wrong program | `ScalaMM` (the editor) and `ScalaMMPlayer -rexx` (the runtime) both fail the same way. The Player is now the default anyway — see below. |
| Display modes not installed | The disc's own startup executes `DEVS:Monitors` to register them. Doing the same **aborts the boot** under AROS, so that path is closed. |

## MM400 was tried, and it is the proof

Scala MM400 is now installed alongside MM300 and mounts correctly as its own volume
(`SCALA-MM400`, confirmed by the machine's own `Info` output). Its launcher needs no
DEVS work at all — just two font assigns and a `cd`, which is the first sign it is a
tidier release than MM300.

**It uses the same ARexx port**, `rexx_ScalaMM`, verified in its binary. That is why it
was worth trying: the translation layer, the command vocabulary and all nineteen
controls work against it unchanged. It is in `TitlerLibrary` as a program.

And it fails on exactly the same line. Two Scala releases, three years apart, one
tidier than the other, both stopped by `scalamm.gfx` — that is not a Scala problem.

## TV Text Professional is not a substitute

Also tried: TV Text Professional 1.0 (Zuma Group, 1989), a genuine broadcast titler,
cracked so no protection, and old enough that AROS would very likely run it.

**It has no ARexx port at all** — nothing matching `rexx` anywhere in the disk image.
1989 predates ARexx shipping with the OS. Without a script port there is nothing for
the translation layer to talk to, and driving it would mean synthesising keystrokes,
which is the fragile approach this whole design exists to avoid.

## Why a Kickstart is the answer

A forum thread on this exact error records MM300 failing on **real AmigaOS 3.2** and
working on 3.1. Software that notices the difference between two versions of the real
operating system was never likely to accept a reimplementation. AROS gets the machine to
a shell and runs ARexx perfectly well; this one program is beyond it.

## What works today, without Scala

Everything else, and it is all proved by checks rather than claimed:

- A machine boots (AROS, no copyrighted ROM needed) with ~37MB of your disc as a
  writable system drive.
- The **command link is live**: `selfqa/out/emu/port-received.log` is what an ARexx port
  inside the emulated Amiga received when two faders were moved in Videoboy.
- The **picture reaches the app**: `scripts/selfqa.sh emu` starts the emulator, captures
  its window and asserts frames arrive at 720×480 — it passes with 522 frames.
- Nineteen controls, each mapped to a command Scala really has, each with a stable param
  code so it can be learned to MIDI, swept on the beat or saved in a template.

The moment `scalamm.gfx` loads, all of that is already pointed at it.

## If you want to try harder

- **A real Kickstart 3.1** is the direct answer.
- **Scala MM400** is reported to be far less fussy about OS version. If you have it, the
  translation layer needs no changes — the port name and the command vocabulary are the
  same family.
