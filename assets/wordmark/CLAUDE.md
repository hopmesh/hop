# assets/wordmark

The hop cursive wordmark and its hand-drawn draw-on animation. The letterforms
are filled outline paths, so they can never be stroke-animated directly
(animating the outline points skews the shapes). Instead the artwork is cut
into real ink pieces (segments of the contiguous pen stroke, overlapping at
every joint) which are revealed sequentially in pen order.

## Files

- `hop-wordmark.svg` is the source lockup (3 letter paths + 5 node circles).
- `hop-wordmark-segments.svg` is the letterforms cut into 17 long ribbon
  pieces in pen order (`#stroke-segments`, ids like `h-stem--loop`,
  `p--descender`, each with `data-order`; plus `#nodes` with `node-1..5`).
  Every piece is a real filled shape rebuilt from medial-axis disks along
  its centerline span, so it stays a tight ribbon, passes straight through
  the letter crossings, and overlaps the next piece at the joint. The union
  is exactly the original letterforms (an exactness pass folds leftover
  taper-tip ink into the touching piece). Built by `segment.py`; cut
  landmarks and piece names live in its `CUTS` table. `segments-debug.svg`
  shows the cuts tinted.
- `hop-wordmark-drawon.json` is the built Lottie (1200x732, 60fps, ~3.5s),
  generated from the segments file by `build.py`.
- `preview.html` is a self-contained demo player (lottie-web inlined): open
  it in a browser, no server needed. Scrub, speed, loop, light/dark.
- `guides.json` is the traced centerline data (anchors, tangents, widths);
  it feeds `segment.py`.
- `trace.py`, `segment.py`, `build.py`, `make_preview.py` are the pipeline,
  in that order.

## Animation sequence

Act 1: the five nodes POP in (scale overshoot, no drop) in the order
4, 2, 5, 3, 1. Act 2: the 17 stroke pieces appear as sequential hard cuts in
pen order: h stem (node-1 to node-2), h hump and swash passing under node-3,
the o counterclockwise (entry and top-left quadrant first, then the bottom,
then the closing top arc), the link up to node-4, the p (descender, return,
over the crossing, bowl with inner loop, exit swash), and the arrowhead into
node-5. Later pen pieces stack above earlier ones, like ink. The final frame
is pixel-identical to the source lockup (raster-diff verified).

## Rebuilding

```
python3 -m venv venv
./venv/bin/pip install numpy pillow scipy scikit-image shapely
./venv/bin/python trace.py       # needs rsvg-convert (brew install librsvg)
./venv/bin/python segment.py
./venv/bin/python build.py
./venv/bin/python make_preview.py
```

`trace.py` rasterizes the letters, skeletonizes them (medial axis), and
threads hand-authored waypoints along the skeleton per component (BFS); edit
its `GUIDES_TABLE` if the artwork changes and check `overlay.png`.
`segment.py` cuts the ink into ribbon pieces (`CUTS` holds the landmarks and
names; verify with `segments-debug.svg` and a raster diff against the
source). `build.py` holds the timing knobs (`POP_ORDER`, `POP_EVERY`,
`PIECE_START`, `PIECE_EVERY`, `HOLD`).

## Rules

- Never animate the letter outline paths directly; only reveal the cut
  pieces (or matte them). Skewed letterforms are always a bug.
- Piece boundaries must stay off the letter crossings; both crossing pieces
  carry the shared crossing ink and stack cleanly.
- After any recut, re-verify: union of pieces vs the source render (zero
  missing ink) and the Lottie final frame vs the source render.
