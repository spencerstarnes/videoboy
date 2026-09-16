# Core

The headless half of Videoboy. No AppKit, no window, no hardware required.
`swift test` must pass here with nothing plugged in.

| Folder | What lives here |
|---|---|
| `Bitstream/` | DV demux and the pre-decode DIF corruptor — the wedge |
| `Clock/` | Transport, subdivisions, and the lookahead scheduler |
| `Control/` | Param codes, the mapping registry, virtual MIDI for self-tests |
| `Graph/` | The `Node` protocol (the one extension point) and the render graph |
| `Modules/` | `_Template/` plus concrete node implementations |
| `Persistence/` | Template read/write, device config |
| `SelfQA/` | Offscreen rendering, frame assertions, the capture seam |

Run `scripts/test.sh` after every change in here.
