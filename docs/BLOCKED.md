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

## Four real bugs found on the way, all mine

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

**The commands were dropped while the machine booted.** Videoboy sends the whole panel
the instant the emulator starts. Scala does not open its ARexx port for about twenty
seconds after that. The listener checked, found the port closed, and *dropped* the
batch — the one carrying `SCREEN`, `PALETTE`, `FONT`, the wipe and the first line of
text. Nothing re-sent it, so the machine sat on the boot console for ever, with the link
alive and the port open, because nothing had told it to draw.

It now **holds** an undeliverable batch instead: the file stays in the drawer, no
acknowledgement is written, and the next poll delivers it. Files are processed oldest
first, so a held file blocks the ones behind it — which is what `SCREEN`-before-`TEXT`
needs anyway.

The acknowledgement now carries Scala's own return code. It used to say `ok` whether the
program ran the command or refused every one of them. That single change is what found
this bug: the first ack read `dropped - rexx_ScalaMM not open`, where it now reads
`ok 9 sent`.

**The self-QA passed on a blank window, which is worse than the bug it hid.** "The
machine has drawn something" measured *brightness* — written to catch a machine still
showing black, and blind to white. Amiberry's window is blank white for the first
seconds after launch: it scored 96% lit and passed, so the check reported a healthy
machine while the operator watched nothing happen. Colour variety was the second wrong
answer: mid-launch the window is white above and black below, two flat colours, 18%.

The measure that separates a drawn screen from an undrawn one is **local detail**, now
`PictureVariety` in Core, with the white frame, the black frame and the two-band frame
pinned as tests. The panel uses the same measure to show "Booting the machine…" instead
of the emulator's empty window.

## If it does not start

Work down this list; each item is a thing that actually went wrong here.

1. **Give it twenty-five seconds.** A cold boot is Kickstart, Workbench, RexxMast, then
   Scala. The panel says "Booting the machine…" until there is a picture.
2. **Check what Scala answered.** `~/Library/Application Support/Videoboy/amiga/VB/ack/`
   — each `.ack` file holds `ok N sent`, or `REFUSED` with the return code and the line
   that caused it.
3. **Check the link.** `VB/ack/link.status` says `alive` plus `port open` or
   `port closed`. Closed after half a minute means Scala did not start; `VB/ack/` also
   holds `versions.txt`, `volumes.txt` and `devs-proof.txt` from the boot.
4. **Run the check.** `scripts/selfqa.sh emu` drives the whole path and writes
   `selfqa/out/phase-4/emu-capture/titled.png`. If that PNG has your text on it, the
   app works and the problem is in front of it.
5. **Screen Recording.** Only if the panel says so — it asks macOS before it blames the
   permission now. Videoboy is ad-hoc signed, so a rebuild can void a grant while the
   switch stays ON in System Settings. `scripts/fix-permissions.sh` resets it so macOS
   asks again.

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
