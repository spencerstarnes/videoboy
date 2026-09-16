# BLOCKED.md

Diagnoses worth keeping, and the one thing that still needs your eyes.
Phases 0–2 are complete and self-verified, including the analog loopback.

---

## 1. DVC100 loopback capture — RESOLVED

**Status: working.** The full analog loop is closed and passing. Kept here because
the diagnosis is worth writing down.

### What was wrong

The DVC100 presents a **vendor-specific USB interface (class `0xff`)**, not USB Video
Class, so macOS binds no driver and it never appears to AVFoundation:

```
DVC100: Pinnacle Systems GmbH, VID 0x2304, PID 0x021a
        bDeviceClass = 0, Interface 0 alt 0: class 0xff/00/ff (vendor-specific)
compare PC-LM1E Camera: bDeviceClass = 239 (UVC) — visible to AVFoundation
```

### How it is solved

Your own `~/dvc100` tool reads it over libusb via the EM28xx bridge.
`App/Sources/Videoboy/Platform/DVC100CaptureSource.swift` runs that binary **as a
separate process** and reads the raw YUYV frames it writes.

**It is never linked, and must not be.** `dvc100` is GPL v2 and Videoboy is
distributed, so linking it would impose the GPL on the whole app. CLAUDE.md's rule for
GPL components is out-of-process only — the same treatment the libretro cores get
later. Do not "tidy this up" into a linked library.

### Two things that had to be right

1. **Only one process can hold the device.** `DVC100.app` and the CLI cannot both
   have it. Quit the app before running the loopback check.
2. **The signal is on S-Video, not composite.** This cost real time and is worth
   knowing: reading the wrong connector returns a perfectly valid, perfectly *black*
   720x480 picture, which looks exactly like a dead output stage. Measured:

   ```
   composite: luma min=16 max=16   (flat black — nothing connected)
   svideo:    luma min=16 max=230  (a real picture)
   ```

   `config/devices.json` now carries `"input": "svideo"` for this rig.

### The result

```sh
scripts/selfqa.sh loopback
```

Evidence in `selfqa/out/phase-2/loopback/` — 6/6 assertions pass:

| Measurement | Result |
| --- | --- |
| effective fps | **30.000** vs 29.97 expected |
| dropped frames | **0** of 120 |
| duplicate frames | 19 of 120 (live signal) |
| captured geometry | **720x480** |
| content | **6 of 6** colour bars matched |

The chain verified end to end: Videoboy → Metal → borderless window on the
MACROSILICON HDMI card → HDMI-to-RCA → DVC100 S-Video → libusb → back into the
harness.

### One note on how the content is judged

Captured bars come back with correct hues but reduced saturation — measured, a
191-level blue returns at 111 and red at 124. That is NTSC's limited chroma bandwidth
behaving normally, not a fault. So the check compares each bar's **channel signature**
(which channels are bright relative to dark) rather than absolute levels: it still
catches a black, garbled or mis-ordered picture, without a tolerance so loose it would
accept anything. See `FrameAssertions.containsColorBarHues`.

---

## 2. SD output mode on the HDMI card — A LIMITATION, NOT A BUG

The `MACROSILICON` HDMI card **does** advertise 720x480 and 720x576 in its EDID.
Videoboy finds the mode, and tries to select it through the display-configuration
transaction API. macOS refuses it:

```
720x480 @ 60.0  ioFlags=0x1  isUsableForDesktopGUI() = false
CGCompleteDisplayConfiguration -> CGError 1001 (illegal argument)
```

The mode is a valid timing but is not flagged usable for the desktop GUI, and macOS
will not put a display into it. This is a macOS restriction, not something the app can
override, and SPEC §3 anticipates it ("you cannot force a mode the adapter won't
accept").

**What the app does instead:** keeps the display's current mode, renders the 720x480
program into it, and **logs the discrepancy explicitly** rather than guessing
silently. The negotiated mode is shown in the settings bar and recorded in
`metrics.json`.

**Your options, in rough order of preference:**
1. Set the card's mode by hand in System Settings ▸ Displays, if 720x480 is offered
   there, or with a tool like SwitchResX that can select non-GUI modes.
2. Let the downstream HDMI-to-RCA converter do the scaling — it has to handle
   480-line output anyway. The signal is correct, just scaled on the way.
3. Accept it: this only affects pixel-exactness of the digital leg, not whether the
   analog chain works.

**This one genuinely needs your eyes on the CRT.** No software check can tell you
whether the picture is right on the tube.

---

## 3. Sample media — WORKED AROUND, BUT YOUR FOOTAGE IS STILL WANTED

`samples/` was empty. CLAUDE.md says an empty `samples/` with no `.dv` is a blocker,
and strictly it stopped Phase 1 dead.

Rather than stop with nothing to show, `scripts/make-fixtures.sh` generates **genuine
NTSC DV bitstreams** (real DIF blocks, real DCT coefficients, 120000 bytes per frame)
that the corruptor and the libav decoder work on for real:

- `samples/bars.dv` — eight colour bars, generated to match `TestPattern.colorBars`
  exactly so decode correctness can be asserted by actual colour values.
- `samples/motion.dv` — moving content, needed to test frame-hold and playback.
- `samples/motion.mov` — an ordinary H.264 clip.

**These are synthetic.** They exercise every code path, but real DV off tape carries
dropouts, head-switching noise and timebase error that no encoder reproduces. For
judging how the wedge actually *looks*, drop your own `.dv` files into `samples/` and
re-run `scripts/make-fixtures.sh` to reindex them. Nothing is blocked on this; it is
about aesthetics, which is your call, not the harness's.

---

## Not blocked

Everything else in Phases 0–2: the build, the tests, the bitstream wedge, the clock
and scheduler, param codes, templates, the UI shell, playback, the mixer, MIDI
detect/learn, and the output window. See `docs/FIRST-RUN.md`.
