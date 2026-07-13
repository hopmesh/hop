#!/usr/bin/env python
"""Trace centerline pen guides for the hop wordmark.

Renders the letter fills (no dots), skeletonizes them (medial axis), then
threads hand-authored waypoint sequences along the skeleton via BFS to get
dense, accurate centerlines. Jump legs cross gaps (dot halos, piece notches,
counters) as straight lines. Outputs guides.json (anchors + tangents +
suggested matte widths, in SVG user units) and overlay.svg for visual QA.
"""
import json
import re
import subprocess
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage
from scipy.spatial import cKDTree
from skimage.morphology import medial_axis

HERE = Path(__file__).parent
SRC = HERE / "hop-wordmark.svg"
SCALE = 2  # raster px per SVG unit
W, H = 1200, 732


def build_context():
    """Rasterize the letter fills and build the medial-axis skeleton."""
    letters_svg = HERE / "letters-only.svg"
    src = SRC.read_text()
    src_letters = re.sub(
        r'<g transform="matrix\(1\.267053[^>]*>\s*<circle[^>]*/>\s*</g>', "", src)
    letters_svg.write_text(src_letters)
    png = HERE / "letters-mask.png"
    subprocess.run(
        ["rsvg-convert", "-w", str(W * SCALE), "-b", "white",
         str(letters_svg), "-o", str(png)],
        check=True,
    )
    rgb = np.asarray(Image.open(png).convert("RGB")).astype(int)
    mask = (np.abs(rgb - np.array([43, 240, 160])).sum(axis=2) < 150)

    skel, dist = medial_axis(mask, return_distance=True)
    labels, nlab = ndimage.label(skel, structure=np.ones((3, 3)))
    print("skeleton px:", skel.sum(), "components:", nlab)

    sk_pts = np.argwhere(skel)
    trees, comp_pts = {}, {}
    for lab in range(1, nlab + 1):
        pts = sk_pts[labels[sk_pts[:, 0], sk_pts[:, 1]] == lab]
        comp_pts[lab] = pts
        trees[lab] = cKDTree(pts)

    all_tree = cKDTree(sk_pts)

    def probe(x, y):
        _, i = all_tree.query([y * SCALE, x * SCALE])
        return int(labels[tuple(sk_pts[i])])

    ctx = {
        "src": src, "mask": mask, "skel": skel, "dist": dist,
        "labels": labels, "trees": trees, "comp_pts": comp_pts,
        "LAB_H": probe(300, 65), "LAB_O": probe(560, 280),
        "LAB_CY": probe(470, 330),
    }
    print("labels: h", ctx["LAB_H"], "o/p", ctx["LAB_O"], "cyan", ctx["LAB_CY"])
    return ctx


def snap(ctx, p, lab):
    x, y = p[0] * SCALE, p[1] * SCALE
    _, i = ctx["trees"][lab].query([y, x])
    return tuple(ctx["comp_pts"][lab][i])


def bfs(ctx, a, b):
    skel = ctx["skel"]
    if a == b:
        return [a]
    seen = {a: None}
    q = deque([a])
    while q:
        cur = q.popleft()
        if cur == b:
            path = [cur]
            while seen[cur] is not None:
                cur = seen[cur]
                path.append(cur)
            return path[::-1]
        r, c = cur
        for dr in (-1, 0, 1):
            for dc in (-1, 0, 1):
                if dr == 0 and dc == 0:
                    continue
                n = (r + dr, c + dc)
                if 0 <= n[0] < skel.shape[0] and 0 <= n[1] < skel.shape[1] \
                        and skel[n] and n not in seen:
                    seen[n] = cur
                    q.append(n)
    return None


def straight(a, b):
    n = int(max(abs(b[0] - a[0]), abs(b[1] - a[1]))) + 1
    rr = np.linspace(a[0], b[0], n)
    cc = np.linspace(a[1], b[1], n)
    return list(zip(rr, cc))


# ------------------------------------------------------------------- guides
# legs: ("walk", component key, [pts]) follow skeleton; ("jump", None, [pts])
# straight. Component keys resolve against the context at trace time.
GUIDES_TABLE = {
    # h: entry from node1 -> junction A -> up the ascender loop -> down the
    # right side -> junction B -> stem terminal toward node2
    "h-stem": [
        ("walk", "h", [(95, 332), (125, 328), (148, 338), (168, 378),
                         (176, 320), (195, 240), (225, 150), (258, 85),
                         (290, 60), (318, 68), (338, 95), (332, 150),
                         (310, 220), (280, 278), (250, 325), (218, 368),
                         (192, 390), (188, 425), (187, 456)]),
        ("jump", None, [(187, 456), (172, 470)]),
    ],
    # h: hump springs at junction B, arcs over, down to the U-turn, then the
    # exit swash passes under node3 and sweeps the crescent beneath the o
    "h-hump": [
        ("walk", "h", [(192, 394), (212, 362), (240, 325), (270, 290),
                         (300, 268), (325, 275), (343, 300), (352, 340),
                         (347, 390), (334, 440), (323, 462), (350, 460),
                         (378, 447), (402, 441), (424, 455), (452, 468),
                         (485, 485), (520, 493), (553, 480), (582, 453),
                         (600, 434)]),
        ("jump", None, [(600, 434), (613, 421)]),
    ],
    # o: entry above node3 (the cyan sliver), over the notch to the tip, then
    # counterclockwise: down the left side (top-left quadrant first), around
    # the bottom to the junction, up the right side closing the top. The exit
    # spur to the notch under node4 is its own leg from the junction.
    "o": [
        ("walk", "cy", [(452, 362), (470, 335), (490, 305), (508, 278)]),
        ("jump", None, [(508, 278), (516, 279)]),
        ("walk", "o", [(517, 282), (520, 305), (522, 335), (528, 362),
                         (542, 378), (568, 385), (596, 382), (611, 374),
                         (607, 350), (606, 320), (598, 296), (575, 282),
                         (545, 272), (522, 269)]),
        ("walk", "o", [(611, 375), (635, 350), (658, 330), (678, 317),
                         (696, 328), (702, 334)]),
    ],
    # p: continues from the under-node4 junction: down the descender loop,
    # back up crossing the stem, over the bowl, counterclockwise around the
    # inner loop, exit swash rising to the arrow notch
    "p": [
        ("walk", "o", [(702, 334), (712, 352), (722, 378), (725, 395),
                         (718, 425), (700, 478), (678, 540), (658, 600),
                         (645, 645), (636, 630), (638, 580), (652, 520),
                         (670, 470), (690, 420), (714, 378), (740, 345),
                         (770, 308), (805, 282), (840, 272), (872, 282),
                         (900, 305), (916, 335), (922, 368), (916, 400),
                         (898, 432), (868, 452), (857, 470), (852, 495),
                         (815, 502), (775, 498), (759, 478), (760, 458),
                         (772, 447), (798, 442), (826, 441), (852, 446),
                         (880, 456), (915, 468), (950, 472), (985, 462),
                         (1012, 442), (1030, 412), (1037, 382), (1032, 352)]),
    ],
    # arrowhead: straight directional wipe from the shaft notch to the tip
    "arrowhead": [
        ("jump", None, [(1005, 350), (1118, 260)]),
    ],
}


def leg_pixels(ctx, kind, comp_key, pts):
    out = []
    if kind == "walk":
        lab = {"h": ctx["LAB_H"], "o": ctx["LAB_O"], "cy": ctx["LAB_CY"]}[comp_key]
        snapped = [snap(ctx, p, lab) for p in pts]
        for a, b in zip(snapped, snapped[1:]):
            seg = bfs(ctx, a, b)
            if seg is None:
                seg = straight(a, b)
                print(f"  note: unreachable, straight bridge {a}->{b}")
            out.extend(seg if not out else seg[1:])
    else:
        px = [(p[1] * SCALE, p[0] * SCALE) for p in pts]
        for a, b in zip(px, px[1:]):
            seg = straight((int(a[0]), int(a[1])), (int(b[0]), int(b[1])))
            out.extend(seg if not out else seg[1:])
    return out


def trace_legs(ctx):
    """Per-guide list of (kind, comp_key, polyline) with polylines in SVG
    units (x, y), dense at raster resolution."""
    out = {}
    for name, legs in GUIDES_TABLE.items():
        out[name] = []
        for kind, comp_key, pts in legs:
            pix = np.asarray(leg_pixels(ctx, kind, comp_key, pts), dtype=float)
            xy = np.stack([pix[:, 1] / SCALE, pix[:, 0] / SCALE], axis=1)
            out[name].append((kind, comp_key, xy))
    return out


def resample(poly, step=4.0):
    p = np.asarray(poly, dtype=float)
    d = np.sqrt(((p[1:] - p[:-1]) ** 2).sum(axis=1))
    s = np.concatenate([[0], np.cumsum(d)])
    total = s[-1]
    n = max(int(total / step), 8)
    t = np.linspace(0, total, n)
    rr = np.interp(t, s, p[:, 0])
    cc = np.interp(t, s, p[:, 1])
    return np.stack([rr, cc], axis=1), total


def smooth(p, win=11):
    if len(p) < win + 2:
        return p
    kernel = np.ones(win) / win
    out = p.copy()
    for k in (0, 1):
        pad = np.pad(p[:, k], win // 2, mode="edge")
        out[:, k] = np.convolve(pad, kernel, mode="valid")
    out[0], out[-1] = p[0], p[-1]
    return out


def catmull_to_bezier(pts):
    n = len(pts)
    anchors, outs, ins = [], [], []
    for i in range(n):
        p0 = pts[max(i - 1, 0)]
        p1 = pts[i]
        p2 = pts[min(i + 1, n - 1)]
        tan = (p2 - p0) / 6.0
        anchors.append([round(v, 2) for v in p1])
        outs.append([round(v, 2) for v in tan])
        ins.append([round(v, 2) for v in -tan])
    return anchors, ins, outs


def path_d(g):
    a, i_, o_ = g["anchors"], g["in"], g["out"]
    d = f"M{a[0][0]:.1f},{a[0][1]:.1f}"
    for k in range(1, len(a)):
        c1 = (a[k-1][0] + o_[k-1][0], a[k-1][1] + o_[k-1][1])
        c2 = (a[k][0] + i_[k][0], a[k][1] + i_[k][1])
        d += f"C{c1[0]:.1f},{c1[1]:.1f} {c2[0]:.1f},{c2[1]:.1f} {a[k][0]:.1f},{a[k][1]:.1f}"
    return d


def main():
    ctx = build_context()
    legs = trace_legs(ctx)
    dist = ctx["dist"]

    guides_out = {}
    for name, leg_list in legs.items():
        pix = []
        for kind, comp_key, xy in leg_list:
            p = np.stack([xy[:, 1] * SCALE, xy[:, 0] * SCALE], axis=1)
            pix.extend(p.tolist() if not pix else p.tolist()[1:])
        dense, total_px = resample(pix, step=4.0)
        dense = smooth(dense, win=11)
        rr = np.clip(dense[:, 0].astype(int), 0, dist.shape[0] - 1)
        cc = np.clip(dense[:, 1].astype(int), 0, dist.shape[1] - 1)
        radii = dist[rr, cc]
        radii = radii[radii > 0]
        wmax = float(radii.max()) * 2 / SCALE if len(radii) else 30.0
        step_pts = max(len(dense) // max(int(total_px / SCALE / 24), 4), 1)
        key = dense[::step_pts]
        if not np.array_equal(key[-1], dense[-1]):
            key = np.vstack([key, dense[-1]])
        xy = np.stack([key[:, 1] / SCALE, key[:, 0] / SCALE], axis=1)
        anchors, ins, outs = catmull_to_bezier(xy)
        guides_out[name] = {
            "anchors": anchors, "in": ins, "out": outs,
            "length": round(total_px / SCALE, 1),
            "width": round(wmax + 14, 0),
        }
        print(f"guide {name}: len={total_px/SCALE:.0f}u anchors={len(anchors)} "
              f"wmax={wmax:.0f} matte_w={wmax+14:.0f}")

    # widths tuned after the raster coverage check (see CLAUDE.md)
    guides_out["h-stem"]["width"] = 90
    guides_out["o"]["width"] = 74
    guides_out["arrowhead"]["width"] = 215
    (HERE / "guides.json").write_text(json.dumps(guides_out, indent=1))

    colors = {"h-stem": "#ff5050", "h-hump": "#ff9a2a", "o": "#3cdcff",
              "p": "#ffdc3c", "arrowhead": "#ff50ff"}
    overlay = ctx["src"].replace("</svg>", "")
    # wide coverage preview under the thin centerlines
    for name, g in guides_out.items():
        overlay += (f'<path d="{path_d(g)}" style="fill:none;stroke:{colors[name]};'
                    f'stroke-opacity:0.35;stroke-width:{g["width"]};'
                    f'stroke-linecap:round;stroke-linejoin:round;"/>')
    for name, g in guides_out.items():
        overlay += (f'<path d="{path_d(g)}" style="fill:none;stroke:{colors[name]};'
                    f'stroke-width:5;stroke-linecap:round;"/>')
    overlay += "</svg>"
    overlay = overlay.replace("fill:rgb(43,240,160)", "fill:rgb(23,90,63)")
    (HERE / "overlay.svg").write_text(overlay)
    subprocess.run(["rsvg-convert", "-w", "1800", "-b", "#101418",
                    str(HERE / "overlay.svg"), "-o", str(HERE / "overlay.png")],
                   check=True)
    print("overlay.png written")


if __name__ == "__main__":
    main()
