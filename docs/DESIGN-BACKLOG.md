# DESIGN-BACKLOG.md

Owner requests captured verbatim in intent, ordered by what I'd build next and why.
Nothing here is started unless marked. `docs/TODO.md` covers what exists; this is
what was asked for and has not been built.

---

## Done in this pass

- **Preferences window** (§7) — six panes: Save, Defaults, Outputs, Inputs, Hot Keys,
  MIDI Mapping. Backed by `PreferenceStore` in Core, which is what §8's reminder
  suppressions and §6's destination list both need.
- **Shift-to-detect everywhere** (§5) — every enabled fader, not just FX parameters.
- **Collapse reflow** — folding sources gives the FX chain their height; folding the
  FX columns gives the libraries and browser their width.
- **Driven-parameter marks** — anything with a MIDI, audio or LFO driver outlines and
  breathes on the beat.
- **"Don't remind me again"** (§8) — save location on first open, save on quit, and
  the audio-clock warning. Reset from the Defaults pane.
- **Output routing** (§6, partly) — a send glyph under every preview, listing every
  display plus the destinations defined in preferences. Displays work, including the
  four-up tiled send. OBS, window, capture-card, IP and feedback-send destinations
  are listed greyed, each saying which specific piece is missing.
- **NTSC / DV output emulation** (§13) — two toggles on the output bar, three
  variables each behind a Look Up-style popover.
- **FCP X library behaviour** (§10) — hover-scrub with real decoded frames, in/out
  points that actually trim playback, drag-and-drop (which genuinely was not there),
  and double-click-to-channel with the A/B ↔ C/D auto-advance.

- **Scopes** (SPEC §19) — waveform, RGB parade, histogram, vectorscope; tab cycles
  quad-overlay → histogram → parade → quad-over-black → off.
- **NTSC broadcast safety** — legal range 7.5–100 IRE, illegal-level reporting.
- **Zebra** — diagonal, transport-animated, on ONE/TWO/PROGRAM, hides while scopes
  are up.

---

## Next — small, high value

### 1. Beat pulse on the interface chrome
Flash the window background subtly when tempo changes (tap, detection, or manual),
and pulse gently with the beat. Nothing inside panels moves. **The transport and
the pulse machinery already exist** (the record indicators do exactly this), so
this is mostly a chrome layer plus an easing curve.

### 2. Primary fader redesign
Thicker — as thick as the bar graphic — with no separator. Left and right halves
carry a subtle tint, echoed in the panel backgrounds of the bus they belong to, and
the fill reflects which side is winning as it travels.
*Note:* `VBFader` already supports `fillsFromCentre` and a per-fader accent colour,
so this is a geometry and tinting pass, not new machinery.

### 3. "Swap" → "Cut", with the destination named
Broadcast language throughout: **CUT TO ONE** / **CUT TO TWO**, the label changing
with what the cut would do.

### 4. Auto-fade rate control
Three-position slider with tick marks, turtle at one end and rabbit at the other,
monochrome to match. Depends on auto-fade itself, which is not built.

### 5. Shift-detect on *every* slider and option
Currently the M/S/C badges cover FX parameters only. Faders, shuttles and generator
controls have decorative badge columns.

---

## Medium — coherent subsystems

### 6. Output routing, macOS-style
An **AirPlay glyph under every preview**, opening a popover listing destinations
defined in preferences. Destinations: all external displays and OBS by default;
**+** adds individual windows or apps, feedback sends, IPTV sources, capture cards
(Black Magic), and **Generators** with an expanding arrow — selecting a generator
populates its sliders in the side panel.
Preferences pane: white box with **+ / −**, list on the left, settings for the
selected item on the right.
**Includes: send any individual window to an external display, and a four-up
preview to a monitor.** Also the scope send.

### 7. Preferences window
macOS model: thick tabs with icons on the left, settings on the right. Panes for
**Save/location, Defaults, Outputs, Inputs, Hot keys, MIDI mapping**. Save pane
carries auto-save cadence and location; Defaults sets default behaviours and resets
"don't remind me" dialogues.

### 8. "Don't remind me again" moments
- Remind to set a save location on first open.
- Remind to save on quit.
Needs the preference store from §7 to remember the suppressions.

### 9. Transport cluster, Logic Pro style
Centre the BPM and clock controls into a pseudomorphic cluster — behind glass,
grouped. **No dropdowns in the top pane**, especially for fewer than five choices:
instead a grid of text options in a centred info pane that reacts on click and
cycles clock and subdivision. Targeting pros.

### 10. FCP X library behaviour
- Hover a thumbnail to **scrub its frames** reactively.
- **In/out points**, shown FCP-style.
- **Drag and drop** (needs checking — likely not working).
- **Double-click sends a clip to a channel**, with an **A/B / C/D toggle** in the
  square blue-background switch style. If A is selected, double-click loads A then
  auto-advances to B.

### 11. Loading screen
Adobe/Logic style, listing modules as they load, with
**© NewVHS / Spencer Starnes 2026**.

---

## Larger

### 12. OBS streaming
Direct output to OBS. The `dvc100` tool already publishes NUT over UDP for OBS,
which is a working precedent for the transport.

### 13. NTSC / DV emulation toggles on the output
Two single toggles — NTSC (signal path, colour control) and DV (colour space and
rate only). **Subtle.** Three key variables each, in a popover like macOS Look Up.
*Note:* the CompositeCodec and the DV interchange path already do the heavy work;
this is a restrained preset face over them.

---

## Open question I'd want answered before building §6

"Feedback display send" — I read this as routing a bus back into the feedback
loop's external input as a destination, which fits the existing `FeedbackNode`
(it already accepts a captured frame as its history). Confirm that is what you
meant before I wire it that way.
