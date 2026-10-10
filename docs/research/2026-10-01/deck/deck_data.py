"""Data behind the Videoboy market report (2026-10-01).

Cell codes:  Y = offered · P = partial / indirect · N = not offered or not found in the
vendor documentation reviewed · U = not checked (unverified) · A = not applicable.
Every competitor value traces to a source in SOURCES (by key) or to the research
notes in ../03-competitors-and-gaps.md. Videoboy values trace to
../feature-inventory.md and are re-checked against it by build_deck.py.
"""

# ── Matrix A: live visual tools ────────────────────────────────────────────────
LIVE_PRODUCTS = [
    ("VB", "Videoboy 0.4.10"),
    ("RES", "Resolume Arena 7"),
    ("VDMX", "VDMX6 Plus"),
    ("MIL", "Millumin 5"),
    ("QLAB", "QLab 5 + Video"),
    ("MAD", "MadMapper 6"),
    ("TD", "TouchDesigner"),
    ("SYN", "Synesthesia Pro"),
]
LIVE_PLATFORM = {"VB": "Mac (Apple Silicon)", "RES": "Mac · Win", "VDMX": "Mac", "MIL": "Mac",
                 "QLAB": "Mac", "MAD": "Mac · Win", "TD": "Mac · Win", "SYN": "Mac · Win"}
LIVE_PRICE = {"VB": "not on sale", "RES": "€799", "VDMX": "$349", "MIL": "from €399",
              "QLAB": "$599–1,399*", "MAD": "from €399", "TD": "$600", "SYN": "$399"}

# (group, feature, {product: code}, note, inventory-ids that justify the VB cell)
LIVE_ROWS = [
    ("Sources & media", "Video files, common codecs",
     dict(VB="Y", RES="Y", VDMX="Y", MIL="Y", QLAB="Y", MAD="Y", TD="Y", SYN="Y"),
     "all eight", ["B1", "B2"]),
    ("Sources & media", "GPU performance codec (HAP or DXV)",
     dict(VB="N", RES="Y", VDMX="Y", MIL="Y", QLAB="Y", MAD="Y", TD="Y", SYN="U"),
     "VB optimizes to MPEG-2 GOP 6 for the wedge; Resolume = DXV; hap.video list", []),
    ("Sources & media", "Cameras and capture cards",
     dict(VB="Y", RES="Y", VDMX="Y", MIL="U", QLAB="Y", MAD="Y", TD="Y", SYN="Y"),
     "QLab camera cues; Synesthesia webcams", ["B8"]),
    ("Sources & media", "Screen / window capture",
     dict(VB="Y", RES="U", VDMX="Y", MIL="Y", QLAB="U", MAD="U", TD="Y", SYN="U"),
     "VB: ScreenCaptureKit window capture", ["B9"]),
    ("Sources & media", "NDI in / out",
     dict(VB="N", RES="Y", VDMX="Y", MIL="Y", QLAB="Y", MAD="Y", TD="Y", SYN="Y"),
     "Synesthesia: Pro tier", ["B11", "I10"]),
    ("Sources & media", "Syphon in / out",
     dict(VB="N", RES="Y", VDMX="Y", MIL="Y", QLAB="Y", MAD="Y", TD="Y", SYN="Y"),
     "VB: optional backlog item", ["I10"]),
    ("Sources & media", "Built-in generators / scenes",
     dict(VB="Y", RES="Y", VDMX="Y", MIL="P", QLAB="N", MAD="Y", TD="Y", SYN="Y"),
     "VB: 13 native + ISF; Millumin: gradients, text, shader transitions", ["B5", "B6"]),
    ("Sources & media", "ISF shader import",
     dict(VB="Y", RES="Y", VDMX="Y", MIL="U", QLAB="U", MAD="Y", TD="U", SYN="Y"),
     "Resolume: Wire + 7.8; MadMapper materials are ISF-based", ["F8"]),
    ("Sources & media", "Text and titles as a live source",
     dict(VB="P", RES="Y", VDMX="Y", MIL="Y", QLAB="Y", MAD="Y", TD="Y", SYN="U"),
     "VB: Now Playing + Scala titler; Core Text CG built but not reachable", ["B14", "B15", "B16"]),

    ("Playback & cueing", "Loop · ping-pong · play once",
     dict(VB="Y", RES="Y", VDMX="Y", MIL="U", QLAB="P", MAD="U", TD="Y", SYN="U"),
     "QLab: loops + hold at end", ["C2"]),
    ("Playback & cueing", "Cue points / hot cues inside a clip",
     dict(VB="N", RES="Y", VDMX="U", MIL="P", QLAB="P", MAD="P", TD="P", SYN="U"),
     "Millumin cues recall a time; QLab start/end per cue; MadMapper markers", ["C10"]),
    ("Playback & cueing", "Beat-synced clip playback",
     dict(VB="Y", RES="Y", VDMX="Y", MIL="N", QLAB="N", MAD="Y", TD="Y", SYN="Y"),
     "VB: STEP ladder, BEAT, quantised pads; Millumin has no BPM follow", ["C4", "E2", "E7"]),
    ("Playback & cueing", "Speed control and reverse",
     dict(VB="P", RES="Y", VDMX="Y", MIL="U", QLAB="P", MAD="U", TD="Y", SYN="U"),
     "VB: speed; reverse only inside ping-pong", ["C5", "C11"]),
    ("Playback & cueing", "Clip launcher (grid / pads)",
     dict(VB="Y", RES="Y", VDMX="Y", MIL="Y", QLAB="P", MAD="Y", TD="P", SYN="Y"),
     "VB: 8 Clip Pads + library double-click; TD: build it yourself", ["E7"]),
    ("Playback & cueing", "Queue / autopilot (what plays next)",
     dict(VB="Y", RES="Y", VDMX="U", MIL="Y", QLAB="Y", MAD="Y", TD="P", SYN="U"),
     "VB: Queue, Play Next, ADV, ROLL; Resolume Auto Pilot", ["C8", "C9"]),
    ("Playback & cueing", "Cue list or timeline with GO",
     dict(VB="N", RES="N", VDMX="Y", MIL="Y", QLAB="Y", MAD="Y", TD="P", SYN="U"),
     "VDMX Cue List plugin; MadMapper 6 timelines; VB Setlists planned", ["D12", "G11"]),
    ("Playback & cueing", "Keyframes / envelopes",
     dict(VB="P", RES="Y", VDMX="P", MIL="Y", QLAB="Y", MAD="Y", TD="Y", SYN="U"),
     "VB: LFOs + beat sweeps; QLab fade cues", ["G5", "G7", "G11"]),

    ("Mixing & compositing", "Crossfader / A–B mix",
     dict(VB="Y", RES="Y", VDMX="Y", MIL="U", QLAB="P", MAD="U", TD="Y", SYN="U"),
     "VB: three faders (A↔B, C↔D, ONE↔TWO)", ["E1"]),
    ("Mixing & compositing", "Transition library",
     dict(VB="Y", RES="Y", VDMX="Y", MIL="Y", QLAB="P", MAD="U", TD="Y", SYN="U"),
     "VB: 13 patterns incl. AVE-5; QLab: fades", ["E5", "E6"]),
    ("Mixing & compositing", "Blend modes",
     dict(VB="Y", RES="Y", VDMX="Y", MIL="Y", QLAB="Y", MAD="U", TD="Y", SYN="U"),
     "VB 13 + Key; VDMX 20+ blend modes and transitions", ["E4"]),
    ("Mixing & compositing", "Masks and keys",
     dict(VB="P", RES="Y", VDMX="Y", MIL="Y", QLAB="Y", MAD="Y", TD="Y", SYN="U"),
     "VB: Key blend only; Layer Mask in backlog", ["E4", "E11", "E12"]),
    ("Mixing & compositing", "Per-layer geometry: position, scale, rotate, crop",
     dict(VB="P", RES="Y", VDMX="Y", MIL="Y", QLAB="Y", MAD="Y", TD="Y", SYN="U"),
     "VB Transform: scale/position/rotation/flip — no crop or anchor", ["F6", "E13"]),
    ("Mixing & compositing", "Unlimited layers",
     dict(VB="N", RES="Y", VDMX="Y", MIL="Y", QLAB="Y", MAD="Y", TD="Y", SYN="P"),
     "VB: 4 sources → 2 buses → Program, fixed by design", []),

    ("Look", "Live datamosh on a real H.264 bitstream",
     dict(VB="Y", RES="N", VDMX="N", MIL="N", QLAB="N", MAD="N", TD="N", SYN="N"),
     "look-alike shaders exist; none damage a live bitstream", ["F1"]),
    ("Look", "NTSC composite signal model",
     dict(VB="Y", RES="U", VDMX="P", MIL="N", QLAB="N", MAD="U", TD="P", SYN="U"),
     "VDMX: behavioural VHS-style ISF filters; TD: buildable", ["F2"]),
    ("Look", "Vision / AI features (tracking, background removal)",
     dict(VB="N", RES="U", VDMX="Y", MIL="P", QLAB="U", MAD="P", TD="Y", SYN="U"),
     "VDMX tracking + background removal; Mad AI materials; Millumin Kinect/Leap", []),

    ("Time & sync", "Tap tempo",
     dict(VB="Y", RES="Y", VDMX="Y", MIL="N", QLAB="N", MAD="Y", TD="Y", SYN="U"),
     "Millumin and QLab have no tempo concept", ["G3"]),
    ("Time & sync", "Automatic beat detection from audio",
     dict(VB="Y", RES="N", VDMX="Y", MIL="N", QLAB="N", MAD="Y", TD="P", SYN="P"),
     "VB: BeatNet from any app's audio; Resolume: tap / Link / DJ sync", ["G4"]),
    ("Time & sync", "Ableton Link",
     dict(VB="N", RES="Y", VDMX="Y", MIL="N", QLAB="N", MAD="Y", TD="Y", SYN="U"),
     "VB: removed from CLOCK as unbuilt", ["G10"]),
    ("Time & sync", "MIDI clock in",
     dict(VB="N", RES="Y", VDMX="Y", MIL="N", QLAB="N", MAD="Y", TD="Y", SYN="U"),
     "VDMX: Clock plugin (MIDI Follow)", ["G10"]),
    ("Time & sync", "Timecode (SMPTE / LTC / MTC)",
     dict(VB="N", RES="Y", VDMX="Y", MIL="Y", QLAB="Y", MAD="Y", TD="Y", SYN="U"),
     "Resolume: SMPTE in, Arena only", ["G13"]),
    ("Time & sync", "DJ hardware sync (Pro DJ Link / StageLinQ)",
     dict(VB="N", RES="Y", VDMX="U", MIL="N", QLAB="N", MAD="U", TD="P", SYN="U"),
     "Resolume Arena; VB plans Apple Music song links instead", ["G14"]),

    ("Control", "MIDI learn",
     dict(VB="Y", RES="Y", VDMX="Y", MIL="Y", QLAB="Y", MAD="Y", TD="Y", SYN="Y"),
     "VB: Shift-click any control", ["H2"]),
    ("Control", "OSC in / out",
     dict(VB="N", RES="Y", VDMX="Y", MIL="Y", QLAB="Y", MAD="Y", TD="Y", SYN="Y"),
     "VB status bar reads \"OSC: off\"", ["H7"]),
    ("Control", "Scripting or API",
     dict(VB="N", RES="Y", VDMX="U", MIL="Y", QLAB="Y", MAD="U", TD="Y", SYN="P"),
     "Resolume REST/WebSocket/MCP; Millumin JavaScript; TD Python", ["H9"]),
    ("Control", "Undo / redo",
     dict(VB="N", RES="Y", VDMX="P", MIL="Y", QLAB="U", MAD="U", TD="Y", SYN="U"),
     "VB: targeted take-backs only; VDMX limited", ["H8"]),

    ("Output & record", "Multiple outputs / displays",
     dict(VB="Y", RES="Y", VDMX="Y", MIL="Y", QLAB="Y", MAD="Y", TD="Y", SYN="U"),
     "VB: send to any display, four-up", ["I2"]),
    ("Output & record", "Mapping, warping, edge blending",
     dict(VB="N", RES="Y", VDMX="P", MIL="Y", QLAB="Y", MAD="Y", TD="Y", SYN="U"),
     "VB: out of scope by design; VDMX perspective correction", ["I9"]),
    ("Output & record", "Record the output (built in)",
     dict(VB="Y", RES="Y", VDMX="Y", MIL="P", QLAB="U", MAD="P", TD="Y", SYN="N"),
     "Millumin: Syphon Recorder or timeline export; Synesthesia: third-party only", ["J1"]),
    ("Output & record", "Program + every input recorded in one take (ISO)",
     dict(VB="Y", RES="U", VDMX="U", MIL="N", QLAB="U", MAD="N", TD="P", SYN="N"),
     "VB: ProRes / H.264 / HEVC, one folder per take", ["J1", "J2"]),
    ("Output & record", "Video scopes",
     dict(VB="Y", RES="N", VDMX="Y", MIL="U", QLAB="U", MAD="U", TD="P", SYN="U"),
     "VB: WFM/RGB/HIST/VEC + NTSC legality; Resolume: third-party FFGL", ["I4", "I5"]),
    ("Output & record", "SD / analog-first output tools (480i, safe, overscan, BFI, bars)",
     dict(VB="Y", RES="U", VDMX="U", MIL="U", QLAB="U", MAD="P", TD="P", SYN="N"),
     "MadMapper: calibration generators", ["I1", "I7"]),

    ("Library & show", "Media catalog with import (add / move / copy, duplicates, bins)",
     dict(VB="Y", RES="P", VDMX="P", MIL="P", QLAB="N", MAD="P", TD="N", SYN="P"),
     "VB: Lightroom-model catalog; Resolume Media Manager; Millumin Synced Library", ["D1", "D8"]),
    ("Library & show", "Linked optimized media (transcode on import)",
     dict(VB="Y", RES="P", VDMX="P", MIL="U", QLAB="N", MAD="U", TD="N", SYN="N"),
     "Resolume: Alley converter; VDMX: separate HAP converter", ["D9"]),
    ("Library & show", "Presets / snapshots",
     dict(VB="P", RES="Y", VDMX="Y", MIL="Y", QLAB="Y", MAD="Y", TD="Y", SYN="Y"),
     "VB: whole-show files + pads; Setlists planned", ["F14", "K1"]),
]

# ── Matrix B: adjacent tools ───────────────────────────────────────────────────
ADJ_PRODUCTS = [
    ("VB", "Videoboy"), ("SER", "Serato Video"), ("VDJ", "VirtualDJ Pro"), ("VMIX", "vMix 4K / Pro"),
    ("ATEM", "ATEM Mini ISO"), ("RV", "Resolve 21"), ("PR", "Premiere 26.5"), ("LP", "Logic Pro 12"),
]
ADJ_PRICE = {"VB": "—", "SER": "$499 or $14.99/mo (Suite)", "VDJ": "$19/mo", "VMIX": "$350–1,200 or $50/mo",
             "ATEM": "hardware", "RV": "free · $295", "PR": "$22.99/mo (annual)", "LP": "$199.99 or $129/yr"}
ADJ_ROWS = [
    ("Live switching of video sources", dict(VB="Y", SER="Y", VDJ="Y", VMIX="Y", ATEM="Y", RV="N", PR="N", LP="N"), ""),
    ("Picture follows the music clock", dict(VB="Y", SER="Y", VDJ="Y", VMIX="N", ATEM="N", RV="N", PR="N", LP="N"), "DJ apps tie video to the track's beatgrid"),
    ("Automatic tempo detection", dict(VB="Y", SER="Y", VDJ="Y", VMIX="N", ATEM="N", RV="U", PR="U", LP="Y"), "Logic: Smart Tempo"),
    ("Cue points / markers in media", dict(VB="N", SER="Y", VDJ="Y", VMIX="P", ATEM="N", RV="Y", PR="Y", LP="Y"), "vMix: replay marks"),
    ("Transitions and wipes", dict(VB="Y", SER="Y", VDJ="Y", VMIX="Y", ATEM="Y", RV="Y", PR="Y", LP="N"), "vMix: 13 + up to 8 stingers"),
    ("Overlay / downstream key layer", dict(VB="P", SER="P", VDJ="Y", VMIX="Y", ATEM="Y", RV="Y", PR="Y", LP="N"), "ATEM: USK + DSK; vMix: 8 overlay channels"),
    ("Titles / character generator", dict(VB="P", SER="Y", VDJ="Y", VMIX="Y", ATEM="P", RV="Y", PR="Y", LP="N"), "vMix: 100+ templates"),
    ("Program + every input recorded (ISO)", dict(VB="Y", SER="P", VDJ="P", VMIX="Y", ATEM="Y", RV="A", PR="A", LP="A"), "DJ apps record the mix"),
    ("Live cut exported as an editable timeline", dict(VB="N", SER="N", VDJ="N", VMIX="U", ATEM="Y", RV="A", PR="A", LP="A"), "ATEM ISO writes a Resolve project"),
    ("Video scopes", dict(VB="Y", SER="N", VDJ="N", VMIX="Y", ATEM="U", RV="Y", PR="Y", LP="N"), ""),
    ("Streaming out", dict(VB="P", SER="U", VDJ="U", VMIX="Y", ATEM="Y", RV="N", PR="N", LP="N"), "VB: MPEG-TS over UDP to OBS"),
    ("Plays audio", dict(VB="N", SER="Y", VDJ="Y", VMIX="Y", ATEM="Y", RV="Y", PR="Y", LP="Y"), "VB is silent by design (SPEC §21)"),
    ("AI features shipped in 2026", dict(VB="P", SER="Y", VDJ="Y", VMIX="U", ATEM="N", RV="Y", PR="Y", LP="Y"), "VB: neural beat tracking; others: stems, AI search, generative"),
]

# ── Market: who's who ──────────────────────────────────────────────────────────
WHO = [
    # name, maker, lane, platform, latest (2026), price, model, src
    ("Videoboy", "NewVHS · Spencer Starnes", "Analog/glitch live mixer", "Mac (Apple Silicon)", "0.4.10", "—", "private", "repo"),
    ("Resolume Avenue / Arena 7", "Resolume (NL)", "VJ · LED · mapping", "Mac · Win", "7.x", "€299 / €799", "perpetual + renewals €79 / €219", "resolume"),
    ("VDMX6 / Plus", "VIDVOX (US)", "VJ · video art", "Mac", "6 (1.3.8)", "$199 / $349", "perpetual", "vdmx"),
    ("Millumin 5", "Anomes (FR)", "Theatre · installation", "Mac", "5.14 (Jul)", "€29/wk · €199/yr · from €399", "rental + perpetual", "millumin"),
    ("QLab 5", "Figure 53 (US)", "Theatre show control", "Mac", "5", "free core · $599–1,399*", "perpetual · rent-to-own", "qlab"),
    ("MadMapper 6", "GarageCube (CH)", "Mapping · LED · laser", "Mac · Win", "6.0.x", "€39/mo · from €399", "rental + perpetual", "madmapper"),
    ("TouchDesigner", "Derivative (CA)", "Generative · interactive", "Mac · Win", "—", "free NC · $300 · $600 · $2,200", "perpetual keys", "td"),
    ("Synesthesia", "Gravity Current (US)", "Audio-reactive VJ", "Mac · Win", "—", "$199 / $399", "perpetual (+$60/yr)", "syn"),
    ("Isadora 4", "TroikaTronix (DE)", "Theatre · interactive", "Mac · Win", "4", "not verified", "—", "isadora"),
    ("Serato Video (DJ Suite)", "Serato (NZ)", "DJ video", "Mac · Win", "—", "$499 or $14.99/mo", "perpetual or subscription", "serato"),
    ("VirtualDJ 2026", "Atomix (FR/US)", "DJ · karaoke video", "Mac · Win", "2026", "$19/mo Pro", "subscription (+ lifetime*)", "vdj"),
    ("rekordbox 7 (Creative)", "AlphaTheta (JP)", "DJ video", "Mac · Win", "7.2.8 (Apr)", "~$180/yr*", "subscription", "rekordbox"),
    ("vMix", "StudioCoast (AU)", "Live production", "Win", "—", "$60–1,200 · $50/mo", "perpetual + subscription", "vmix"),
    ("DaVinci Resolve 21", "Blackmagic (AU)", "Post · grading", "Mac · Win · Linux", "21 (Apr beta)", "free · $295", "free + perpetual", "resolve"),
    ("Premiere Pro 26.5", "Adobe (US)", "Post · editing", "Mac · Win", "26.5 (Sep)", "$22.99/mo", "subscription", "premiere"),
    ("Logic Pro 12 · Final Cut Pro", "Apple (US)", "DAW · editing", "Mac · iPad", "12.3.1", "$199.99 · $299.99 · $129/yr bundle", "perpetual + Creator Studio", "apple"),
    ("Watchout · disguise · Pixera · Smode · Notch", "various", "Media servers · real-time", "mostly Win", "—", "~€3,200 · $159/mo · free tiers*", "mixed", "highend"),
]

ONE_TIME = [  # label, value, currency symbol, note  (no FX conversion)
    ("TouchDesigner Pro", 2200, "$", ""), ("QLab 5, all features*", 1399, "$", ""), ("vMix Pro", 1200, "$", ""),
    ("Resolume Arena", 799, "€", ""), ("vMix 4K", 700, "$", ""), ("TouchDesigner Commercial", 600, "$", ""),
    ("QLab 5, one feature set*", 599, "$", ""), ("Serato DJ Suite", 499, "$", "incl. Video"),
    ("MadMapper (from)", 399, "€", ""), ("Millumin (from)", 399, "€", ""), ("Synesthesia Pro", 399, "$", ""),
    ("VDMX6 Plus", 349, "$", ""), ("Final Cut Pro", 299.99, "$", ""), ("Resolume Avenue", 299, "€", ""),
    ("DaVinci Resolve Studio", 295, "$", ""), ("Logic Pro", 199.99, "$", ""), ("VDMX6", 199, "$", ""),
    ("Synesthesia", 199, "$", ""),
]
PER_YEAR = [  # label, value per year, currency, how annualised
    ("disguise Designer Pro*", 1500, "$", "yearly plan"), ("Notch Builder Base*", 1188, "£", "£99 × 12"),
    ("vMix Max", 600, "$", "$50 × 12"), ("MadMapper rental", 468, "€", "€39 × 12"),
    ("Premiere Pro", 275.88, "$", "$22.99 × 12"), ("VirtualDJ Pro", 228, "$", "$19 × 12"),
    ("Resolume Arena renewal", 219, "€", "updates only"), ("Millumin (1 yr rental)", 199, "€", "yearly"),
    ("rekordbox Creative*", 180, "$", "approx."), ("Serato DJ Suite", 179.88, "$", "$14.99 × 12"),
    ("Apple Creator Studio", 129, "$", "FCP + Logic + 4 apps"), ("Resolume Avenue renewal", 79, "€", "updates only"),
    ("Synesthesia renewal", 60, "$", "updates (currently free)"),
]

# ── Gaps (from ../03-competitors-and-gaps.md) ───────────────────────────────────
MAJOR = [
    ("M1", "Cue points / hot cues inside a clip", "Resolume, QLab, Millumin, MadMapper, all DJ apps", "●●●", "deep dive §5.1"),
    ("M2", "Cue list or timeline with GO (numbered cues, timed fades, auto-follow)", "QLab, Millumin, MadMapper, Isadora, VDMX", "○●◐", "Setlists cover part"),
    ("M3", "Masks (shape, chroma, layer)", "VDMX, Resolume, Millumin, MadMapper, QLab", "●●●", "Layer Mask in backlog"),
    ("M4", "Syphon and NDI, in and out", "every live competitor", "●●●", "Syphon out is the cheapest step"),
    ("M5", "OSC in / out", "every live competitor", "●●●", "ControlEvent bus was designed for it"),
    ("M6", "MIDI clock + Ableton Link", "Resolume, VDMX, MadMapper, TouchDesigner, DJ apps", "●○◐", "removed from CLOCK as unbuilt"),
    ("M7", "Timecode (SMPTE LTC / MTC)", "Resolume Arena, VDMX, MadMapper, Millumin, Isadora, QLab", "○●◐", "theatre and broadcast run on a clock"),
    ("M8", "Undo / redo", "Resolume, Millumin, TouchDesigner, every editor", "●●●", "owner: \"a consistent bug\""),
    ("M9", "Per-source geometry: crop, anchor, opacity fader, keyframes", "QLab, VDMX, Resolume, Millumin", "◐●●", "Transform has scale/position/rotate/flip"),
    ("M10", "Text and titles as an editable source", "Resolume, VDMX, Millumin, QLab, MadMapper", "◐●◐", "Core Text CG built, not reachable"),
    ("M11", "Presets and snapshots for effects, transitions, layers", "Resolume, VDMX, MadMapper, Millumin", "●●●", "Setlists / E-MEM idea"),
    ("M12", "A performance codec with alpha (HAP / DXV)", "VDMX, Resolume, Millumin, MadMapper, QLab", "●◐●", "MPEG-2 stays right for the wedge"),
]
MINOR = [
    ("m1", "Pad trigger styles: momentary and toggle", "Resolume"),
    ("m2", "Random / shuffle play; autopilot after N loops", "Resolume (beat shuffle planned 0.5.0)"),
    ("m3", "Reverse key and scratch", "Resolume, DJ apps"),
    ("m4", "Envelopes / keyframed parameter curves", "Resolume, Millumin, MadMapper"),
    ("m5", "More blend modes", "VDMX (20+), Resolume"),
    ("m6", "LUTs", "Resolume"),
    ("m7", "Notes panel, remaining-time clock", "Resolume"),
    ("m8", "Scripting / API (JS, Python, REST, MCP)", "Millumin, Isadora, TouchDesigner, Resolume"),
    ("m9", "Vision: background removal, tracking, object masks", "VDMX, Premiere"),
    ("m10", "Web / HTML / slide sources", "Millumin, vMix"),
    ("m11", "Projector / ATEM / Stream Deck control", "Millumin, Isadora"),
    ("m12", "10-bit / HDR output", "Resolume, Millumin"),
    ("m13", "Mapping: warping, edge blending, slices", "Arena, MadMapper, Millumin, QLab — out of scope"),
    ("m14", "Audio playback with the picture", "QLab, Millumin, Resolume — excluded (SPEC §21)"),
    ("m15", "3-D, particles, generative scenes", "TouchDesigner, Notch, Smode — not this product"),
]
AHEAD = [
    ("Live datamosh on a real H.264 bitstream (MOSH / HEAL / bloom, beat-timed)", "none live"),
    ("NTSC composite signal model (dot crawl, chroma bleed, TBC wobble)", "shader approximations"),
    ("AVE-5 wipe block emulated from the operating manual (31 patterns)", "none"),
    ("Real vintage titler (Scala MM400 on Amiberry) as a live source", "none"),
    ("Neural beat detection (BeatNet) from any app's audio", "VDMX detects BPM; Resolume taps"),
    ("Program + A/B/C/D recorded in one take", "ATEM ISO hardware"),
    ("Lightroom-model import and catalog with linked optimized media", "none in VJ software"),
    ("Broadcast idioms: Hot Punch, A/B ROLL, ADV, bus keys, tally", "vMix / ATEM, not VJ apps"),
    ("NTSC-legal scopes: WFM, RGB, HIST, VEC, IRE legality", "Resolve, vMix, VDMX Scopes"),
    ("Stable param codes and hand-editable plain-text shows", "XML project files"),
]

# ── Interface paradigms ────────────────────────────────────────────────────────
UI_PRODUCTS = ["Videoboy", "Logic Pro 12", "Resolve 21", "Premiere Pro 26", "VDMX6"]
UI_ROWS = [
    ("Layout model", ["fixed 5×5 grid; panels collapse, never move", "one window; areas shown/hidden",
                      "fixed page layouts; panels toggled", "dockable panels, saved workspaces", "free-floating plugin windows, user layouts"]),
    ("Modes / pages", ["IMPORT · VJ · SETTINGS (⌘1–3)", "Tracks ↔ Live Loops views", "Media · Cut · Edit · Fusion · Color · Fairlight · Deliver · Photo",
                       "workspaces (Editing, Color, Audio, Graphics…)", "workspaces; no modes"]),
    ("Time model", ["live, beat-clocked (BPM · DIV · BEAT)", "timeline + quantised cell grid", "timecode timeline", "timecode timeline", "live; Clock plugin + Cue List"]),
    ("Where properties live", ["on the surface: cards, Source Controls, keys", "Inspector (region, track, channel strips)",
                               "Inspector panel (tabs)", "Effect Controls + Properties panel", "Workspace + UI Inspector windows"]),
    ("Media", ["Asset Browser + 2 libraries + Import mode catalog", "browsers (files, loops) + Library", "Media Pool, bins, smart bins",
               "Project panel + Media Browser", "Media Bin with pages"]),
    ("Monitors", ["7: four sources, two sub-mixes, Program", "movie window", "source + timeline viewers", "Source + Program monitors", "preview windows per layer"]),
    ("Transport", ["central glass cluster: BPM, CLOCK, DIV, FMT, record", "control-bar LCD", "viewer transport", "monitor transport", "Clock plugin"]),
    ("Hardware learn", ["Shift-click any control; MIDI · AUD · LFO badges", "Controller Assignments (learn)", "dedicated panels (Speed Editor…)",
                        "shortcuts; third-party surfaces", "detect on any control; any data source"]),
    ("Undo", ["targeted take-backs", "full history", "full history", "History panel", "limited"]),
    ("Customisation", ["none by design (collapse only)", "moderate", "low", "high", "total"]),
]
UI_BORROW = [
    ("Logic Pro", "Key Commands editor; Smart Controls (one knob → many params); Live Loops scenes; Logic Remote on iPad; full undo history",
     "density and the LCD transport cluster"),
    ("DaVinci Resolve", "a tabbed Inspector drawer per source (geometry, crop, opacity); smart bins and keywords; dedicated control hardware",
     "the page bar (⌘1–3) and linked optimized media"),
    ("Premiere Pro", "the contextual Properties panel; Essential Graphics-style title templates with live data; a visual shortcut editor",
     "two-monitor source/program thinking"),
    ("VDMX", "any data source on any control (OSC, clock, step sequencer); Cue List; Scopes plugin; Syphon / NDI",
     "Shift-detect, ISF, VDMX-style echo"),
]

# ── Roadmap, as the owner has written it ───────────────────────────────────────
ROADMAP = [
    ("SHIPPED", "Sep 2026", [
        "0.4.6 decode fixes · 0.4.7 SQLite catalog + background import",
        "0.4.8 mode bar + setup assistant · 0.4.9 Import mode",
        "0.4.10 Copy + Optimize (linked optimized media)",
        "A/B ROLL + ADV · Clip Pads · Hot Punch · FX focus A·B·MIX",
        "take-backs · one rule for every beat-rate key · nested bins",
        "BeatNet beat detection · DV removed (MPEG-family wedge)"]),
    ("NOW", "1 Oct 2026", [
        "Queue names: Playlist → Queue, Play Next / Play Last",
        "Queues saved with the show (template v5)",
        "branch feature/queue-names (setlist plan, phase 0)"]),
    ("NEXT", "setlist plan", [
        "1 · LOCK per bank (~1½ days)",
        "2 · Playlists + Lists tab, Append / Replace (~1½ days)",
        "3 · Setlists: bank state, Start Up Sequence Punch / Cue / Crossfade (~3½ days)",
        "4 · Song linking to Apple Music (~1½ days)"]),
    ("THEN", "0.4.11 → 0.5.0", [
        "0.4.11 any canvas: SD PAL, HD, square, vertical; 23.976–30 fps; ½-res fallback",
        "0.5.0 tags: tag pools → Queues, tag pads, beat shuffle, energy fader, smart bins"]),
    ("ALSO ASKED FOR", "backlog", [
        "WeatherStar 3000/4000 under EMU · Amiberry IPC save states",
        "retro emulation library + TAS · custom shader injection",
        "Colour Ctrl + Layer Mask cards · generator colour wells",
        "beat ×2 / ÷2, downbeat, nudge · MIDI clock + Link · Syphon out",
        "Copy+Optimize Custom preset · ROLL/ADV on Program · Macros & AI"]),
    ("OPEN", "decisions", [
        "Lists tab name · Setlists copy or point to Playlists",
        "pads hide first, LOCK never · Hot Punch show-wide?",
        "bitstream corruptor stays off until judged on an analog chain",
        "1.0 / public beta plan exists only in chat"]),
]


# ── Additions after the first review pass (2026-10-01) ─────────────────────────
# Author's market map: x = live (0) → post-production (1); y = fixed instrument (0) → open toolkit (1).
# Judgement, not measurement — labelled as such on the page.
MAP_POINTS = [
    ("Videoboy", 0.10, 0.10, "red"),
    ("DJ video", 0.06, 0.24, "cy"), ("Live VJ", 0.20, 0.48, "am"), ("Live production", 0.30, 0.28, "cy"),
    ("Show control", 0.44, 0.52, ""), ("Mapping & servers", 0.55, 0.64, ""), ("Generative", 0.42, 0.93, ""),
    ("DAW", 0.66, 0.56, ""), ("Post: edit & grade", 0.90, 0.44, ""),
]
LANES = [
    ("Live VJ performance", "Resolume · VDMX · Synesthesia · Modul8 · Magic", "clip grids, layers, effects, BPM", "$199–€799 once", "high"),
    ("DJ video", "Serato Video · VirtualDJ · rekordbox", "video tied to the track's beatgrid", "~$180/yr – $499", "medium"),
    ("Live production", "vMix · ATEM · OBS · TriCaster", "PGM/PVW, keyers, ISO, streaming", "$60–$1,200 · hardware", "medium"),
    ("Show control & theatre", "QLab · Millumin · Isadora", "cue lists, GO, timecode, fades", "free core – $1,399", "low–medium"),
    ("Mapping & media servers", "MadMapper · HeavyM · Watchout · disguise · Pixera", "warping, blending, LED, scale", "€399 – ~€3,200+", "low"),
    ("Generative & real-time", "TouchDesigner · Notch · Smode", "node graphs, 3-D, interactivity", "free NC – $2,200", "low"),
    ("Post: edit & grade", "Resolve · Premiere Pro · Final Cut Pro", "timelines, markers, inspectors", "free – $295, or $22.99/mo", "hand-off"),
    ("Music: DAW", "Logic Pro · Ableton Live", "the musical clock, Link, controllers", "$199.99 or $129/yr bundle", "clock"),
]
WHO_EDGE = {  # what they do better · what Videoboy does better (from the matrices)
    "Videoboy": ("—", "—"),
    "Resolume Avenue / Arena 7": ("clip grid at scale, mapping, Link / SMPTE / DJ sync, OSC", "bitstream looks, broadcast takes, beat detection, ISO"),
    "VDMX6 / Plus": ("any data on any control, masks, vision FX, cue list", "a fixed performance surface, ISO record, catalog"),
    "Millumin 5": ("timelines, cues, warping, theatre control", "beat clock, live looks, ISO record"),
    "QLab 5": ("cue list + GO, timecode, show reliability", "beat, mixing, looks"),
    "MadMapper 6": ("mapping, LED, lasers, timelines", "broadcast-style mixing, ISO record"),
    "TouchDesigner": ("anything you can build", "ready to play in minutes"),
    "Synesthesia": ("100+ audio-reactive scenes", "footage-first mixing, recording"),
    "Isadora 4": ("scene-based interactivity, Python", "beat, looks"),
    "Serato Video (DJ Suite)": ("video glued to tracks, DJ hardware", "independent picture, looks, scopes"),
    "VirtualDJ 2026": ("video + karaoke + stems, any controller", "looks, broadcast takes"),
    "rekordbox 7 (Creative)": ("phrase-aware cueing, stems, booth standard", "picture-first mixing"),
    "vMix": ("overlays, titles, replay, streaming", "the beat, the looks, macOS"),
    "DaVinci Resolve 21": ("edit, grade and audio, free tier", "live"),
    "Premiere Pro 26.5": ("editing ecosystem, AI tools", "live"),
    "Logic Pro 12 · Final Cut Pro": ("musical timeline, Apple bundle", "live picture"),
    "Watchout · disguise · Pixera · Smode · Notch": ("scale, multi-projector shows", "price, intimacy, the analog look"),
}
TRIAL_TERMS = [
    ("Resolume", "fully functional demo with a watermark; Avenue → Arena by paying the difference; education 50%; 1–60 machines per licence", "resolume.com"),
    ("Millumin 5", "30-day trial with every feature, then watermarked output; education pricing; extra seats from the account page", "millumin.com/v5"),
    ("MadMapper", "free version with every feature: watermarked video, DMX blackout every 30 s, scanner at ¼ resolution", "madmapper (CDM / store)"),
    ("Synesthesia", "unlimited trial, watermarked; Standard on 1 device, Pro on 2; renewals $60/yr (currently free)", "synesthesia.live/pricing"),
    ("TouchDesigner", "Non-Commercial free: 1280×1280, not for paid work, 10 keys per account", "derivative.ca"),
    ("QLab 5", "free tier with audio, video and lighting cues; rent-to-own after 110 days*; site licence $299 per activation (10+)*", "qlab.app · Capterra*"),
    ("VDMX6", "educational, hobbyist and upgrade discounts", "vidvox.net"),
]
SIGNAL_VB = [
    "Param codes are already stable addresses: an OSC / MCP surface over them is a small step, and Settings ▸ Macros & AI is waiting.",
    "Hand off to editors rather than compete: a cut list makes every ISO take searchable and re-cuttable there.",
    "The video twin of phrase analysis is shot-change detection: auto-placed hot cues.",
    "Song linking via Apple Music is the light path; Pro DJ Link / StageLinQ for track data can follow.",
    "Setlists plus a rundown view are the right size; don't build a keyframe timeline.",
    "Syphon in and out lets TouchDesigner feed Videoboy and the reverse, without hosting it.",
    "Price against the specialist band ($199–$399), never against a $129 bundle.",
    "Stay Metal-native, LGPL-only, GPL out of process. Avoid deprecated frameworks.",
]
GAP_SIZE = {"M1": "M", "M2": "L", "M3": "M", "M4": "S–M", "M5": "S–M", "M6": "M", "M7": "M", "M8": "M–L",
            "M9": "M", "M10": "M", "M11": "M", "M12": "M"}
UI_RATINGS = [  # author's opinion, 1–5: Videoboy, Logic, Resolve, Premiere, VDMX, and why for Videoboy
    ("Readable on stage", [5, 3, 3, 2, 2], "fixed grid, big faders, tally, nothing moves"),
    ("Information density", [5, 4, 4, 3, 4], "seven monitors and every control in one window"),
    ("Learnability, first hour", [3, 4, 3, 4, 2], "dense, custom keys, no manual yet"),
    ("Safety: undo and lock", [2, 5, 5, 5, 2], "take-backs only; LOCK planned"),
    ("Hardware integration", [3, 4, 5, 3, 5], "learn on everything; no MIDI out or templates"),
    ("Keyboard depth", [2, 5, 4, 5, 3], "hot keys pane and pad numbers only"),
    ("Customisation", [1, 3, 2, 5, 5], "none, by design"),
]
GANTT = [  # (track, label, start week, end week inclusive)
    ("Safety & reach", "LOCK", 1, 1), ("Safety & reach", "Undo: parameters + loads", 1, 2),
    ("Safety & reach", "Syphon out", 2, 2), ("Safety & reach", "OSC in → param codes", 2, 3),
    ("Preparation", "Hot cues + Cues mode on pads", 3, 4), ("Preparation", "Cut list per take (EDL, FCPXML)", 4, 5),
    ("Preparation", "MIDI clock in, then Link", 5, 5),
    ("Owner's plan", "Playlists + Lists tab", 6, 6), ("Owner's plan", "Setlists + Start Up Sequence", 6, 7),
    ("Owner's plan", "Song linking", 8, 8),
    ("The wedge", "Analog judging rig in the app", 9, 9), ("The wedge", "Corruptor back as Experimental", 10, 10),
    ("The wedge", "VJ → LIVE; tooltip synonyms", 10, 10),
    ("Ready to show", "1.0 bar + manual", 11, 11), ("Ready to show", "Distribution decision (signing)", 11, 11),
    ("Ready to show", "20-user paid beta", 12, 12),
]
CUE_SHEET = [  # illustrative — fictional songs
    ("1 · Opener", "128", "Neon (A/B)", "Punch", "A: tunnel loop · B: crowd plates · pads: logo, strobe",
     "bar 1 Punch in · bar 17 FADE 1→2 · drop (bar 33): MOSH 1 bar, HEAL on the downbeat"),
    ("2 · Ballad", "84", "Tape (C/D)", "Cue", "C: home movies · D: photo folder, STEP 1/2",
     "Composite NTSC heavy · 4-bar FADE · Now Playing lower third on entry"),
    ("3 · Closer", "174 (½-time 87)", "Glitch (A/B)", "Crossfade", "A: datamosh source · B: performance cam",
     "check ×2 / ÷2 · Hot Punch pads on hits · AVE-5 wipe into the last chorus · keep recording"),
]
RECHECK_LOG = [
    ("Inventory rows", "code read · grep counts · path test", "3 rows corrected (Transform position, Colour controls, Settings panes); 3 absent features added; first hand-count of totals replaced by a machine count"),
    ("Matrix: Videoboy cells", "rule check against cited inventory rows", "undo ◐→–; 4 rows re-cited; 45 cells, 0 disagreements"),
    ("Matrix: competitor cells", "vendor docs, then a targeted second round", "Link, MIDI clock, NDI, Syphon, recording, undo, HAP, cue lists, scopes resolved; ATEM scopes –→?; the rest shown as ?"),
    ("Research documents", "second read against sources", "Premiere doesn't import FCPXML (fixed); recording-effects claim made neutral; Synesthesia BPM and Resolume blend count softened"),
    ("Deck headlines and copy", "page-by-page review of the rendered PDF", "\"everyone else rents\", VirtualDJ \"subscription only\", \"only Resolve\", scoreboard leaders, roadmap quote attribution, product count 15→14"),
]
