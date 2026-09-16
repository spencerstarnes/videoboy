# App

The thin AppKit + Metal shell. Windows, output, UI, MIDI, capture. It links `Core`
and should contain nothing that could live there.

| Folder | What lives here |
|---|---|
| `Output/` | Display enumeration and the borderless output window |
| `Platform/` | Real capture (AVFoundation) and the `--selfqa` entry points |
| `Render/` | The live render loop and Metal-backed previews |
| `UI/` | The canonical shell: theme tokens, the 5x5 grid, panels, controls |

The layout in `UI/` is normative — see SPEC 14 and `docs/mockups/layout-v6.html`.
Do not redesign it.

Build with `scripts/build.sh`, launch with `scripts/run.sh`.
