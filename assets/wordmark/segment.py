#!/usr/bin/env python
"""Cut the wordmark letterforms into contiguous, overlapping stroke segments.

Each pen chain (from trace.py) is cut at hand-picked landmarks on clean
stroke sections into a handful of long ribbon pieces. A piece's ink is
rebuilt as the union of medial-axis disks along its centerline span (the
local half-width comes from the distance map), intersected with the actual
letter fills, so pieces stay tight ribbons, pass straight through the
letter crossings, and overlap the next piece at every joint. A final
exactness pass merges any leftover ink (flared taper tips) into the piece
it touches, making the union exactly the original letterforms.

Outputs hop-wordmark-segments.svg (production, pieces in pen order) and
segments-debug.svg (alternating tints to inspect cuts and overlaps).
"""
import json
import re
from pathlib import Path

import numpy as np
from shapely.geometry import LineString, MultiPolygon, Polygon
from shapely.ops import unary_union

from trace import GUIDES_TABLE, HERE, SRC, build_context, trace_legs  # noqa: F401

GREEN = "#2BF0A0"
W, H = 1200, 732
OVER_FWD = 22.0   # how far each piece reaches into the next, svg units
OVER_BACK = 8.0   # how far each piece reaches back under the previous
RAD_MARGIN = 5.0  # extra disk radius before clipping to the ink

# Cut landmarks per chain: coordinates on clean stroke sections (never at a
# crossing). Pieces run cut-to-cut with the overlaps above. Names label the
# resulting pieces in order (one more name than cuts).
CUTS = {
    "h-stem": {
        "cuts": [(225, 155), (287, 272)],
        "names": ["entry-rise", "loop", "stem"],
    },
    "h-hump": {
        "cuts": [(330, 278), (322, 461), (495, 488)],
        "names": ["hump-rise", "hump-fall", "swash", "swash-tip"],
    },
    "o": {
        "cuts": [(507, 335), (590, 383)],
        "names": ["entry-topleft", "bottom", "close-top"],
    },
    "o-exit": {"cuts": [], "names": ["link"]},
    "p": {
        "cuts": [(643, 658), (690, 430), (845, 272), (940, 470)],
        "names": ["descender", "return-rise", "over-cross", "bowl-loop",
                   "swash-out"],
    },
    "arrowhead": {"cuts": [], "names": ["head"]},
}

# ------------------------------------------------------- letters as polygons
def _cubic(p0, c1, c2, p1, n):
    t = np.linspace(0, 1, n)[:, None]
    return ((1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * c1
            + 3 * (1 - t) * t ** 2 * c2 + t ** 3 * p1)


def parse_subpaths(d, tx, ty):
    """Absolute M/C/L/Z path -> list of dense (N,2) rings, transforms baked."""
    tokens = re.findall(r"([MCLZ])|(-?\d*\.?\d+(?:e-?\d+)?)", d)
    cmds = []
    for cmd, num in tokens:
        if cmd:
            cmds.append((cmd, []))
        else:
            cmds[-1][1].append(float(num))
    subs, cur = [], None
    for cmd, nums in cmds:
        if cmd == "M":
            if cur is not None and len(cur) > 3:
                subs.append(np.asarray(cur))
            cur = [[nums[0] + tx, nums[1] + ty]]
            for k in range(2, len(nums), 2):
                cur.append([nums[k] + tx, nums[k + 1] + ty])
        elif cmd == "C":
            for k in range(0, len(nums), 6):
                p0 = np.asarray(cur[-1])
                c1 = np.asarray([nums[k] + tx, nums[k + 1] + ty])
                c2 = np.asarray([nums[k + 2] + tx, nums[k + 3] + ty])
                p1 = np.asarray([nums[k + 4] + tx, nums[k + 5] + ty])
                span = max(np.abs(p1 - p0).max(), 1.0)
                pts = _cubic(p0, c1, c2, p1, max(int(span / 0.9), 5))
                cur.extend(pts[1:].tolist())
        elif cmd == "L":
            for k in range(0, len(nums), 2):
                cur.append([nums[k] + tx, nums[k + 1] + ty])
    if cur is not None and len(cur) > 3:
        subs.append(np.asarray(cur))
    return subs


def letters_polygons():
    """Component polygons keyed like trace legs: h, o (path2), cy (path3)."""
    src = SRC.read_text()
    paths = re.findall(
        r'<g transform="matrix\(1,0,0,1,([-\d.]+),([-\d.]+)\)">\s*<path d="([^"]+)"',
        src)
    assert len(paths) == 3
    out = {}
    for key, (tx, ty, d) in zip(("h", "o", "cy"), paths):
        rings = parse_subpaths(d, float(tx), float(ty))
        rings = [r for r in rings if Polygon(r).area > 5]  # drop degenerates
        rings.sort(key=lambda r: -Polygon(r).area)
        poly = Polygon(rings[0], holes=rings[1:]).buffer(0)
        assert poly.is_valid and not poly.is_empty
        out[key] = poly
    return out


# ------------------------------------------------------------ chain assembly
def build_chains():
    """Pen chains to segment: name -> (polyline, clip components, width)."""
    ctx = build_context()
    build_chains.dist = ctx["dist"]
    legs = trace_legs(ctx)
    widths = {n: g["width"] for n, g in
              json.loads((HERE / "guides.json").read_text()).items()}

    def merged(name, idxs):
        pts = []
        for i in idxs:
            xy = legs[name][i][2].tolist()
            pts.extend(xy if not pts else xy[1:])
        return np.asarray(pts)

    return {
        # (chain polyline, components to clip against, stroke width)
        "h-stem": (merged("h-stem", [0, 1]), ("h",), widths["h-stem"]),
        "h-hump": (merged("h-hump", [0, 1]), ("h",), widths["h-hump"]),
        # o legs: entry walk, notch jump, counterclockwise ring walk, then
        # the exit spur as its own leg from the ring junction.
        "o": (merged("o", [0, 1, 2]), ("cy", "o"), widths["o"]),
        "o-exit": (merged("o", [3]), ("o",), widths["o"]),
        "p": (merged("p", [0]), ("o",), widths["p"]),
        "arrowhead": (merged("arrowhead", [0]), ("o",), widths["arrowhead"]),
    }


def resample(poly, step=2.0):
    p = np.asarray(poly, dtype=float)
    d = np.sqrt(((p[1:] - p[:-1]) ** 2).sum(axis=1))
    s = np.concatenate([[0], np.cumsum(d)])
    total = s[-1]
    n = max(int(total / step) + 1, 4)
    t = np.linspace(0, total, n)
    return np.stack([np.interp(t, s, p[:, 0]), np.interp(t, s, p[:, 1])],
                    axis=1), total


def cut_windows(pts, total, cuts, step=2.0):
    """Cut positions -> overlapping [i0:i1] windows along the chain.

    Landmarks snap to the chain monotonically (each searched only past the
    previous cut), which disambiguates points the pen passes twice.
    """
    idxs = []
    prev = 0
    for cx, cy in cuts:
        d = np.sqrt(((pts[prev + 5:] - [cx, cy]) ** 2).sum(axis=1))
        idxs.append(prev + 5 + int(d.argmin()))
        prev = idxs[-1]
    bounds = [0] + idxs + [len(pts) - 1]
    fwd, back = int(OVER_FWD / step), int(OVER_BACK / step)
    windows = []
    for a, b in zip(bounds, bounds[1:]):
        i0 = max(a - back, 0) if a > 0 else 0
        i1 = min(b + fwd, len(pts) - 1)
        windows.append((i0, i1))
    return windows


def ink_ribbon(pts_span, dist):
    """The ink of one stroke section: union of medial disks along its
    centerline, using the local half-width from the medial-axis distance
    map (px scale is 2x svg units)."""
    from shapely.geometry import Point
    disks = []
    last_r = 12.0
    h, w = dist.shape
    for x, y in pts_span:
        r_, c_ = min(max(int(y * 2), 0), h - 1), min(max(int(x * 2), 0), w - 1)
        r = dist[r_, c_] / 2.0
        if r < 2.0:
            r = last_r  # off-ink samples (jump tails) keep the last width
        last_r = r
        disks.append(Point(x, y).buffer(r + RAD_MARGIN, quad_segs=10))
    return unary_union(disks)


# ------------------------------------------------------------------ cutting
def poly_to_d(poly):
    def ring_d(coords):
        pts = [f"{x:.2f},{y:.2f}" for x, y in coords]
        return "M" + "L".join(pts) + "Z"
    d = ring_d(poly.exterior.coords)
    for hole in poly.interiors:
        d += ring_d(hole.coords)
    return d


def cut_segments():
    comps = letters_polygons()
    chains = build_chains()
    dist = build_chains.dist
    order = ["h-stem", "h-hump", "o", "o-exit", "p", "arrowhead"]
    shapes = []  # (chain, piece name, shapely geometry)
    for name in order:
        raw, clip_keys, width = chains[name]
        clip = unary_union([comps[k] for k in clip_keys])
        pts, total = resample(raw, step=2.0)
        spec = CUTS[name]
        windows = cut_windows(pts, total, spec["cuts"], step=2.0)
        assert len(windows) == len(spec["names"]), name
        for pname, (i0, i1) in zip(spec["names"], windows):
            span = pts[i0:i1 + 1]
            line = LineString(span)
            if name == "arrowhead":
                # solid glyph, not a ribbon: one wide wipe band
                fat = line.buffer(width / 2 + 1.0, quad_segs=16)
            else:
                fat = ink_ribbon(span, dist)
            shape = fat.intersection(clip)
            if shape.is_empty:
                continue
            pieces = (list(shape.geoms)
                      if isinstance(shape, MultiPolygon) else [shape])
            # keep only pieces the pen actually runs through; slivers of
            # parallel neighboring strokes belong to their own pieces
            pieces = [p for p in pieces if p.area > 2 and p.intersects(line)]
            if not pieces:
                continue
            shapes.append((name, pname, unary_union(pieces)))
        print(f"{name}: {len(windows)} pieces")

    # exactness pass: whatever ink the ribbons missed (tapered tips flare
    # wider than the local medial width) merges into the piece it touches,
    # so the union is exactly the letterforms
    everything = unary_union([comps[k] for k in comps])
    residual = everything.difference(unary_union([s for _, _, s in shapes]))
    slivers = (list(residual.geoms)
               if isinstance(residual, MultiPolygon) else [residual])
    merged_slivers = 0
    for sl in slivers:
        if sl.is_empty or sl.area < 0.5:
            continue
        grown = sl.buffer(0.6)
        best, best_a = None, 0.0
        for k, (_, _, s) in enumerate(shapes):
            a = grown.intersection(s).area
            if a > best_a:
                best, best_a = k, a
        if best is not None and best_a > 0:
            n, p, s = shapes[best]
            shapes[best] = (n, p, unary_union([s, sl]).buffer(0.02).buffer(-0.02))
            merged_slivers += 1
    print(f"residual slivers merged: {merged_slivers}")

    segments = []
    for name, pname, shape in shapes:
        merged = shape.simplify(0.12, preserve_topology=True)
        polys = (list(merged.geoms)
                 if isinstance(merged, MultiPolygon) else [merged])
        d = "".join(poly_to_d(p) for p in polys)
        segments.append((name, pname, d))
    return segments


def nodes():
    src = SRC.read_text()
    circles = re.findall(
        r'<g transform="matrix\(([\d.]+),0,0,[\d.]+,([-\d.]+),([-\d.]+)\)">\s*'
        r'<circle cx="([\d.]+)" cy="([\d.]+)" r="([\d.]+)"', src)
    out = []
    for s, tx, ty, cx, cy, r in circles:
        s, tx, ty, cx, cy, r = map(float, (s, tx, ty, cx, cy, r))
        out.append((round(s * cx + tx, 2), round(s * cy + ty, 2),
                    round(s * r, 2)))
    return out


def main():
    segments = cut_segments()
    node_list = nodes()

    head = (f'<svg width="100%" height="100%" viewBox="0 0 {W} {H}" '
            'version="1.1" xmlns="http://www.w3.org/2000/svg" '
            'xml:space="preserve" style="fill-rule:evenodd;clip-rule:evenodd;">')
    comment = ("<!-- hop wordmark cut into contiguous overlapping stroke\n"
               "     segments. Document order inside #stroke-segments is pen\n"
               "     order; each segment overlaps the next at the joint, so\n"
               "     revealing them sequentially reads as one continuous\n"
               "     hand-drawn stroke. The union of all segments is the\n"
               "     exact original letterforms. -->")

    svg = [head, comment, f'<g id="stroke-segments" style="fill:{GREEN};">']
    for order, (name, pname, d) in enumerate(segments, 1):
        svg.append(f'  <path id="{name}--{pname}" data-order="{order}" d="{d}"/>')
    svg.append("</g>")
    svg.append(f'<g id="nodes" style="fill:{GREEN};">')
    for n, (cx, cy, r) in enumerate(node_list, 1):
        svg.append(f'  <circle id="node-{n}" cx="{cx}" cy="{cy}" r="{r}"/>')
    svg.append("</g></svg>")
    out = HERE / "hop-wordmark-segments.svg"
    out.write_text("\n".join(svg))
    print(f"{out.name} written ({out.stat().st_size / 1024:.0f} KB, "
          f"{len(segments)} segments)")

    # debug: alternating tints, semi-transparent so overlaps darken
    tints = ["#ff5050", "#ffdc3c", "#3cdcff", "#ff9af0", "#7dff6e", "#ffa32a"]
    dbg = [head, '<g style="fill-opacity:0.72;">']
    for k, (name, pname, d) in enumerate(segments):
        dbg.append(f'<path d="{d}" style="fill:{tints[k % len(tints)]};"/>')
    dbg.append("</g>")
    for n, (cx, cy, r) in enumerate(node_list, 1):
        dbg.append(f'<circle cx="{cx}" cy="{cy}" r="{r}" '
                   'style="fill:#ffffff;fill-opacity:0.72;"/>')
    dbg.append("</svg>")
    (HERE / "segments-debug.svg").write_text("\n".join(dbg))
    print("segments-debug.svg written")


if __name__ == "__main__":
    main()
