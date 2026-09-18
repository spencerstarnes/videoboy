# Not blocked any more — Scala MM400 runs

**Status: WORKING.** Scala MM400 boots on real Kickstart 3.1 and takes commands from
Videoboy. Evidence: `selfqa/out/emu/scala-TITLE.png` — "VIDEOBOY" in Franklin 64pt on a
640×512 interlaced Amiga screen, drawn by Scala from commands this app sent.

## What it needed

One file: **a Kickstart 3.1 ROM**, in `~/Documents/Amiberry/ROMs/` or
`~/Documents/FS-UAE/Kickstarts/`. The app searches both and prefers a 3.1 (v40.68 /
"3.1" / "310" in the name) when several are present — version matters, because MM300 is
reported to fail on 3.2 and work on 3.1.

The one in use here is `kickstart-3.1-a500_a600_a2000.rom` (v40.63, 512K, ECS), which
matches the ECS chipset the config asks for. Cloanto's encrypted Amiga Forever ROMs are
also supported — drop `rom.key` beside the ROM and it is picked up automatically.

## What the ROM changed

Under AROS, with everything else correct, `scalamm.gfx` refused to initialise:

```
Error 4: Can't open device: scalamm.gfx
```

On real Kickstart 3.1 the same file loads and Scala starts. The difference is visible in
what the machine reports about itself:

| | AROS | Kickstart 3.1 |
|---|---|---|
| Kickstart | 51.51 | **40.63** |
| graphics.library | 45.1 | **40.24** |
| intuition.library | 50.8 | **40.85** |

Note that AROS reports *higher* version numbers, so this was never a version check
failing — `scalamm.gfx` is a display driver and it leans on the real graphics and
intuition implementations in ways AROS's do not satisfy.

## Two real bugs found on the way, both mine

**The assign was wrong and the fix never applied.** The installer emitted
`Assign DEVS: SYS:Scala/System ADD`, which resolves the relative `System/scalamm.gfx`
to `System/System/scalamm.gfx`. I diagnosed that early, wrote a patch, the patch failed
with "anchor not found", and I moved on — so every experiment afterwards ran against a
machine that could not find the file. A test was *pinning* the mistake, too.

The modules are now copied flat into the drawers exec actually looks in, which is read
out of their romtags rather than guessed:

```
scalamm.gfx   NT_DEVICE    "scalamm.gfx"   v51.31 (16.4.96)  ->  DEVS:
scalamm.sys   NT_LIBRARY   "scalamm.sys"   v51.31            ->  LIBS:
```

**The generator wiped the MM400 mount.** MM400 lives on its own volume and its launcher
says `cd SCALA-MM400:Scala`; its preferences store absolute paths starting with that
name. I mounted it by hand, the config generator regenerated the file without it, and
the machine booted and asked to "insert volume SCALA-MM400". Application volumes are a
first-class part of the configuration now (`ApplicationDrive`).

## Setup, start to finish

1. `brew install --cask amiberry` — preferred over FS-UAE: its core has the Scala
   protection dongle, its AROS is newer, and it restores save states from the command
   line.
2. A Kickstart 3.1 ROM in `~/Documents/Amiberry/ROMs/`.
3. A Scala MM400 disc, and an Amiga system disc (CU Amiga Super CD-ROM 19 supplies
   AmigaOS 3.1 files, ARexx and RexxMast).
4. `scripts/amiga.sh setup` — mounts the disc, builds a ~37MB writable system drive,
   writes both emulator configs and the Amiga-side ARexx listener.
5. EMU tab → SET UP → START.

MM300 remains in the library and is still worth a Kickstart 3.1 too; it is identical to
MM400 as far as this app is concerned — same ARexx port, same vocabulary, same nineteen
controls.
