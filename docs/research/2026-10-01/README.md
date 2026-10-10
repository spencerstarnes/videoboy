# Research, 2026-10-01

Asked for by the owner on 2026-10-01, in this order:

1. A deep dive into broadcast editing and DJing, to expand and refine the app for a wider
   range of creatives → [`01-broadcast-and-dj-deep-dive.md`](01-broadcast-and-dj-deep-dive.md)
2. A full update on the system's vocabulary, compared with DJing and broadcast news →
   [`02-vocabulary.md`](02-vocabulary.md)
3. The big competitors, their inspectors, and the major and minor features absent from
   Videoboy (VJ, theatre visual designer, video artist; not DMX) →
   [`03-competitors-and-gaps.md`](03-competitors-and-gaps.md)
4. A PDF report comparing feature sets and interfaces (Logic Pro, DaVinci Resolve,
   Premiere Pro, VDMX), with a checked feature list, the owner's roadmap and pages on what
   Claude would do → [`deck/Videoboy-Market-Report-2026-10-01.pdf`](deck/Videoboy-Market-Report-2026-10-01.pdf)

Supporting evidence: [`feature-inventory.md`](feature-inventory.md) — every Videoboy
feature checked against the code, with a status and an evidence path.

Nothing here changes the app. These are research and recommendations; the scope guard
in `CLAUDE.md` still governs what gets built.

## How it was checked

- **Inventory:** statuses read from the source on `feature/queue-names` (a92f464); counts
  are machine counts; every evidence path is tested for existence. Re-run:

  ```sh
  cd docs/research/2026-10-01/deck && python3 build_deck.py
  ```

  The build prints the row count, the status counts, any evidence path that does not
  exist, and the result of cross-checking every Videoboy cell in the comparison matrix
  against the inventory rows it cites. It stops if any cell disagrees.

- **Competitors:** vendor documentation, support and price pages fetched on 2026-10-01;
  secondary sources marked `*`; anything unverified shown as `?`. Sources are listed in
  each document and on the deck's last pages.

## Rebuilding the deck

`deck/build_deck.py` reads `feature-inventory.md` and `deck/deck_data.py`, writes
`deck/deck.html`, prints it to PDF with headless Chrome, and renders PNG previews into
`deck/preview/` (needs ImageMagick + Ghostscript). Fonts: the system font (SF) and Bebas
Neue from `~/Library/Fonts`.
