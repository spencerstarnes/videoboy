# ARCHITECTURE.md

How Videoboy is put together. One diagram, two clocks, one extension point.

## The split

```
Core/   SwiftPM library, no AppKit. Bitstream engine, clocks, param codes,
        templates, render-graph model, self-QA harness.
        Builds and passes `swift test` headlessly.

App/    Thin AppKit + Metal shell. Windows, output, UI, MIDI, capture.
        Links Core. Owns nothing that could live in Core.
```

If a type does not need a window, it belongs in `Core`. This is what keeps the
wedge testable without hardware.

## The signal path

Everything is a node on a render graph, evaluated once per output frame. The routing
is fixed and never remaps (SPEC 2): **A+B always feed ONE, C+D always feed TWO.**

```
  A ──▶[ch FX]──┐
                ├──▶ SUB-MIX ONE ──▶[bus FX]──┐
  B ──▶[ch FX]──┘   (A over B)                │
                                              ├──▶ PRIMARY ──▶ display out
  C ──▶[ch FX]──┐                             │    (ONE over TWO)   recorder
                ├──▶ SUB-MIX TWO ──▶[bus FX]──┘                     scopes
  D ──▶[ch FX]──┘   (C over D)
```

For a DV source the interesting work happens *before* that diagram starts:

```
  .dv file ──▶ DIF demux ──▶ [BITSTREAM CORRUPTOR] ──▶ libav decode ──▶ MTLTexture
                              ^^^^^^^^^^^^^^^^^^^^
                              the wedge: drop / duplicate / shuffle DIF blocks and
                              zero or flip DCT coefficients on the compressed bytes,
                              so the decoder itself produces the artefacts
```

Corrupting compressed bytes and then decoding them is the whole point. A shader that
imitates the look afterwards is not the same thing and is not what this app does.

## The two clocks

They are separate on purpose (SPEC 4).

| | Render clock | Musical clock |
|---|---|---|
| Source | `CVDisplayLink` per output | transport: BPM, phase, PPQN |
| Drives | frame production and present | *when parameters change* |
| Rate | the display's refresh | the music's tempo |
| Never | carries musical meaning | produces frames |

The musical clock schedules events in the future: "beat N occurs at host time T".
A module that must *act on* beat N schedules its action for `T − its own latency`, so
the visible result lands on T. A global `maxLatency` aligns everything to the longest
path — the same approach Ableton uses.

## The one extension point

The render-graph `Node` protocol. Adding a source, effect or output means
implementing that protocol and dropping in a manifest. There is no second plugin
system, and there should never be one. See `ADD-A-MODULE.md`.

## Parameter addressing

Every adjustable parameter has a stable code (`31B`, `61A`, …) defined in
`Core/Sources/VideoboyCore/Control/ParamCode.swift`. Mappings and saved templates
target the **code**, never a pointer, so swapping the effect in a slot preserves every
mapping whose code still exists. Codes are permanent once shipped; never reuse one.

## How work gets verified

`docs/SELF-QA-HARNESS.md` describes three channels. In short: offscreen Metal renders
checked by arithmetic, real capture through the DVC100 loopback, and a virtual
CoreMIDI source. Evidence lands in `selfqa/out/<phase>/`.
