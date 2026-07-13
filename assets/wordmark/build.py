#!/usr/bin/env python
"""Build hop-wordmark-drawon.json (Lottie) from hop-wordmark-segments.svg.

Act 1: the five nodes POP in (scale overshoot, no drop) in the order
4, 2, 5, 3, 1. Act 2: the 16 ribbon stroke pieces appear sequentially in
pen order as hard cuts (each piece is real ink cut from the letterforms by
segment.py, overlapping the next, so the sequence reads as one continuous
hand-drawn stroke). Later pen pieces stack above earlier ones, like ink.
"""
import json
import re
from pathlib import Path

HERE = Path(__file__).parent
SEGMENTS = HERE / "hop-wordmark-segments.svg"
GREEN_RGB = [43 / 255, 240 / 255, 160 / 255]
W, H = 1200, 732
FR = 60

POP_ORDER = [4, 2, 5, 3, 1]   # node ids, pop sequence
POP_EVERY = 7                 # frames between node pops
POP_LEN = 11                  # frames for one pop
PIECE_START = 46              # first stroke piece appears here
PIECE_EVERY = 7               # frames between piece reveals
HOLD = 50                     # tail hold after the last piece

EASE_OUT = {"o": {"x": [0.25], "y": [0.9]}, "i": {"x": [0.4], "y": [1]}}
EASE_IN_OUT = {"o": {"x": [0.4], "y": [0]}, "i": {"x": [0.3], "y": [1]}}


def parse_pieces():
    """Segment paths in document (= pen) order: (id, [subpath vertex lists])."""
    svg = SEGMENTS.read_text()
    seg_block = svg.split('<g id="stroke-segments"')[1].split("</g>")[0]
    pieces = []
    for pid, d in re.findall(r'<path id="([^"]+)"[^>]* d="([^"]+)"', seg_block):
        subs = []
        for sub in d.split("M"):
            sub = sub.strip().rstrip("Z")
            if not sub:
                continue
            pts = [[float(a), float(b)] for a, b in
                   (p.split(",") for p in sub.split("L"))]
            subs.append(pts)
        pieces.append((pid, subs))
    return pieces


def parse_nodes():
    svg = SEGMENTS.read_text()
    return [(float(cx), float(cy), float(r)) for cx, cy, r in
            re.findall(r'<circle id="node-\d+" cx="([\d.]+)" cy="([\d.]+)" '
                       r'r="([\d.]+)"', svg)]


def _tr():
    return {"ty": "tr", "p": {"a": 0, "k": [0, 0]}, "a": {"a": 0, "k": [0, 0]},
            "s": {"a": 0, "k": [100, 100]}, "r": {"a": 0, "k": 0},
            "o": {"a": 0, "k": 100}, "sk": {"a": 0, "k": 0},
            "sa": {"a": 0, "k": 0}}


def _ks():
    return {"o": {"a": 0, "k": 100}, "r": {"a": 0, "k": 0},
            "p": {"a": 0, "k": [0, 0, 0]}, "a": {"a": 0, "k": [0, 0, 0]},
            "s": {"a": 0, "k": [100, 100, 100]}}


def piece_layer(ind, pid, subs, t_on, t_end):
    items = []
    for k, pts in enumerate(subs):
        items.append({"ty": "sh", "nm": f"sub-{k}", "ks": {"a": 0, "k": {
            "c": True, "v": pts,
            "i": [[0, 0]] * len(pts), "o": [[0, 0]] * len(pts)}}})
    items.append({"ty": "fl", "nm": "ink", "c": {"a": 0, "k": GREEN_RGB + [1]},
                  "o": {"a": 0, "k": 100}, "r": 2})
    items.append(_tr())
    return {"ddd": 0, "ind": ind, "ty": 4, "nm": pid, "sr": 1, "ks": _ks(),
            "ao": 0, "shapes": [{"ty": "gr", "nm": pid, "it": items}],
            "ip": t_on, "op": t_end, "st": 0, "bm": 0}


def node_layer(ind, n, cx, cy, r, t0, t_end):
    scale = {"a": 1, "k": [
        {"t": t0, "s": [0, 0, 100], **EASE_OUT},
        {"t": t0 + 7, "s": [116, 116, 100], **EASE_IN_OUT},
        {"t": t0 + POP_LEN, "s": [100, 100, 100]},
    ]}
    ks = {
        "o": {"a": 1, "k": [{"t": t0, "s": [0], **EASE_OUT},
                             {"t": t0 + 2, "s": [100]}]},
        "r": {"a": 0, "k": 0},
        "p": {"a": 0, "k": [cx, cy, 0]},
        "a": {"a": 0, "k": [0, 0, 0]},
        "s": scale,
    }
    group = {"ty": "gr", "nm": f"node-{n}", "it": [
        {"ty": "el", "nm": "dot", "p": {"a": 0, "k": [0, 0]},
         "s": {"a": 0, "k": [2 * r, 2 * r]}},
        {"ty": "fl", "nm": "fill", "c": {"a": 0, "k": GREEN_RGB + [1]},
         "o": {"a": 0, "k": 100}, "r": 1},
        _tr(),
    ]}
    return {"ddd": 0, "ind": ind, "ty": 4, "nm": f"node-{n}", "sr": 1,
            "ks": ks, "ao": 0, "shapes": [group],
            "ip": t0, "op": t_end, "st": 0, "bm": 0}


def main():
    pieces = parse_pieces()
    node_list = parse_nodes()
    assert len(node_list) == 5

    pops = {n: k * POP_EVERY for k, n in enumerate(POP_ORDER)}
    end = PIECE_START + (len(pieces) - 1) * PIECE_EVERY + HOLD

    layers = []
    ind = 1
    for n, (cx, cy, r) in enumerate(node_list, 1):
        layers.append(node_layer(ind, n, cx, cy, r, pops[n], end))
        ind += 1
    # later pen pieces stack above earlier ones: reverse pen order top-down
    for k, (pid, subs) in reversed(list(enumerate(pieces))):
        layers.append(piece_layer(ind, pid, subs,
                                  PIECE_START + k * PIECE_EVERY, end))
        ind += 1

    lottie = {
        "v": "5.9.6", "fr": FR, "ip": 0, "op": end, "w": W, "h": H,
        "nm": "hop wordmark draw-on", "ddd": 0, "assets": [],
        "layers": layers, "meta": {"g": "hop-wordmark-build"},
    }
    out = HERE / "hop-wordmark-drawon.json"
    out.write_text(json.dumps(lottie, separators=(",", ":")))
    print(f"{out.name} written ({out.stat().st_size / 1024:.0f} KB), "
          f"{len(pieces)} pieces, node pops {pops}, "
          f"{end} frames @ {FR}fps = {end / FR:.1f}s")


if __name__ == "__main__":
    main()
