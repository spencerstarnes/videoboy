# ADD-A-MODULE.md

How to add a source, effect, or output. There is one extension point: the render-graph
`Node` protocol. If you find yourself building a second plugin mechanism, stop.

## The recipe

1. **Copy the template.** `Core/Sources/VideoboyCore/Modules/_Template/` is the
   canonical skeleton. Copy the folder, rename it.
2. **Fill in the four members** the protocol requires (see `Node.swift`):
   `identifier`, `parameters`, `latencyInFrames`, and `render(into:context:)`.
3. **Declare your param codes.** Use existing codes from `ParamCode` wherever the
   parameter is a common one — opacity is always `01A`, scale is always `11A`. Only
   invent a new code for something genuinely module-specific, and never reuse a
   retired one.
4. **Drop in a manifest** so the module is discoverable.

That is the whole procedure. A module that needs anything else is a sign the
protocol is wrong, not the module.

## Worked example: the DV DIF corruptor

The corruptor is the best example because it is the app's reason to exist.

- It lives in `Core/Sources/VideoboyCore/Bitstream/`.
- Its transforms are **pure functions over byte buffers** — `[UInt8] -> [UInt8]`,
  deterministic given a seed. That is what makes them unit-testable with no
  hardware, no GPU and no window.
- It declares three codes: `corruptAmount` (`31B`), `corruptMode` (`32B`) and
  `corruptRate` (`33B`), plus `corruptSeed` (`34B`) so a performance repeats.
- It runs **before** decode. This is the part that is easy to get wrong: a node that
  manipulated pixels after decode would be an ordinary effect, and would look
  nothing like the real thing.

## Rules that are not negotiable

- **Fail visibly.** A missing file, device or dependency degrades to a labelled,
  greyed state. Never a crash, never a silent no-op. Log with your subsystem tag.
- **Feature-flag work in progress.** Add a case to `FeatureFlag` and ship the module
  disabled until it is finished. Half-built modules must not destabilise the app.
- **Test the fragile bones.** Pure byte transforms and anything touching the clock
  get unit tests. UI does not.
- **Prefer duplication to the wrong abstraction.** Two modules that rhyme today are
  not a shared base class.


## Adding support for another video container

A new container is a new `ClipDecoding`, not a new source module. Conform to it in
`Core/Sources/VideoboyCore/Modules/Sources/`, report the frame count, the clip's own
frame rate, and the data-effect family the codec can carry, then choose it by
extension in `ClipSourceNode.load(url:)`.

Everything about WHEN a frame is shown — the playhead, loop modes, ping-pong,
one-shot, musical step playback, in and out points — stays in `ClipSourceNode` and is
then true of the new format immediately. This is deliberate: those rules were written
once and every playback bug fixed in them is fixed for every format at once.

Report `.none` for `dataEffectFamily` unless the codec can genuinely be damaged before
decode. The interface reads that value to decide whether to offer the bitstream
controls at all, so claiming a family the decoder cannot honour puts a control on
screen that does nothing.
