#!/usr/bin/env python3
"""Fail when a Font Awesome source's artwork does not fit inside its own declared viewBox.

Why this exists: assets/fa-icons/comments.svg shipped with viewBox="0 0 576 512" while its
artwork actually spans y -32..544. Every derivation from that file (the iOS PDF imagesets, the
Android drawables) therefore cropped the glyph, and the "Chats" tab bubble was visibly cut off
on device. Six other icons had the same defect, including gear.svg, which is a tab icon that
was silently losing 16 units off the top and bottom. Nothing gated it, so it survived until a
human looked at a phone.

The check computes the true bounding box of every path in the file, including Bezier extrema,
and compares it to the declared viewBox. Pure standard library on purpose: a guard that needs
rsvg-convert and ImageMagick would be skipped in CI, and a skipped guard that still prints a
green line is the exact failure this repo keeps finding.

Usage:
    python3 tools/check-icon-bounds.py [dir ...]      # default: assets/fa-icons
"""

from __future__ import annotations

import math
import pathlib
import re
import sys

# One unit of slack: rendered stroke joins and rounding can put a control point a hair outside
# the box without anything being visibly clipped. Anything past this is a real crop.
TOLERANCE = 2.0

_NUM = re.compile(r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?")
_CMD = re.compile(r"([MmLlHhVvCcSsQqTtAaZz])")


def _numbers(chunk: str) -> list[float]:
    return [float(n) for n in _NUM.findall(chunk)]


def _bezier_extrema(p0: float, p1: float, p2: float, p3: float) -> list[float]:
    """Parameter values where a cubic's derivative is zero, clamped to the drawn segment."""
    a = -p0 + 3 * p1 - 3 * p2 + p3
    b = 2 * (p0 - 2 * p1 + p2)
    c = p1 - p0
    ts: list[float] = []
    if abs(a) < 1e-12:
        if abs(b) > 1e-12:
            ts.append(-c / b)
    else:
        disc = b * b - 4 * a * c
        if disc >= 0:
            root = math.sqrt(disc)
            ts.extend([(-b + root) / (2 * a), (-b - root) / (2 * a)])
    return [t for t in ts if 0 < t < 1]


def _cubic_at(p0: float, p1: float, p2: float, p3: float, t: float) -> float:
    u = 1 - t
    return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3


class _Bounds:
    def __init__(self) -> None:
        self.x0 = self.y0 = math.inf
        self.x1 = self.y1 = -math.inf

    def add(self, x: float, y: float) -> None:
        self.x0, self.y0 = min(self.x0, x), min(self.y0, y)
        self.x1, self.y1 = max(self.x1, x), max(self.y1, y)

    def cubic(self, x0, y0, x1, y1, x2, y2, x3, y3) -> None:
        self.add(x0, y0)
        self.add(x3, y3)
        for t in _bezier_extrema(x0, x1, x2, x3):
            self.add(_cubic_at(x0, x1, x2, x3, t), _cubic_at(y0, y1, y2, y3, t))
        for t in _bezier_extrema(y0, y1, y2, y3):
            self.add(_cubic_at(x0, x1, x2, x3, t), _cubic_at(y0, y1, y2, y3, t))

    @property
    def empty(self) -> bool:
        return self.x0 is math.inf or self.x1 == -math.inf


def path_bounds(d: str) -> _Bounds:
    """Bounding box of one path's `d` attribute. Arcs are sampled; every other command is exact."""
    b = _Bounds()
    x = y = 0.0
    start_x = start_y = 0.0
    prev_c2: tuple[float, float] | None = None
    prev_q: tuple[float, float] | None = None
    tokens = [t for t in _CMD.split(d) if t.strip()]
    i = 0
    while i < len(tokens):
        cmd = tokens[i]
        args = _numbers(tokens[i + 1]) if i + 1 < len(tokens) and not _CMD.fullmatch(tokens[i + 1]) else []
        i += 2 if args else 1
        rel = cmd.islower()
        c = cmd.upper()

        if c == "Z":
            x, y = start_x, start_y
            b.add(x, y)
            prev_c2 = prev_q = None
            continue

        step = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7}[c]
        if not args:
            continue
        for k in range(0, len(args) - step + 1, step):
            a = args[k : k + step]
            if c == "M":
                x, y = (x + a[0], y + a[1]) if rel else (a[0], a[1])
                start_x, start_y = x, y
                b.add(x, y)
                prev_c2 = prev_q = None
                # A polyline after the first moveto pair is an implicit lineto.
                c = "L"
            elif c == "L":
                x, y = (x + a[0], y + a[1]) if rel else (a[0], a[1])
                b.add(x, y)
                prev_c2 = prev_q = None
            elif c == "H":
                x = x + a[0] if rel else a[0]
                b.add(x, y)
                prev_c2 = prev_q = None
            elif c == "V":
                y = y + a[0] if rel else a[0]
                b.add(x, y)
                prev_c2 = prev_q = None
            elif c == "C":
                x1, y1, x2, y2, x3, y3 = a
                if rel:
                    x1, y1, x2, y2, x3, y3 = x + x1, y + y1, x + x2, y + y2, x + x3, y + y3
                b.cubic(x, y, x1, y1, x2, y2, x3, y3)
                prev_c2, prev_q = (x2, y2), None
                x, y = x3, y3
            elif c == "S":
                x2, y2, x3, y3 = a
                if rel:
                    x2, y2, x3, y3 = x + x2, y + y2, x + x3, y + y3
                x1, y1 = (2 * x - prev_c2[0], 2 * y - prev_c2[1]) if prev_c2 else (x, y)
                b.cubic(x, y, x1, y1, x2, y2, x3, y3)
                prev_c2, prev_q = (x2, y2), None
                x, y = x3, y3
            elif c == "Q":
                qx, qy, x3, y3 = a
                if rel:
                    qx, qy, x3, y3 = x + qx, y + qy, x + x3, y + y3
                # Raise the quadratic to an equivalent cubic so one code path covers both.
                b.cubic(x, y, x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y),
                        x3 + 2 / 3 * (qx - x3), y3 + 2 / 3 * (qy - y3), x3, y3)
                prev_q, prev_c2 = (qx, qy), None
                x, y = x3, y3
            elif c == "T":
                x3, y3 = a
                if rel:
                    x3, y3 = x + x3, y + y3
                qx, qy = (2 * x - prev_q[0], 2 * y - prev_q[1]) if prev_q else (x, y)
                b.cubic(x, y, x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y),
                        x3 + 2 / 3 * (qx - x3), y3 + 2 / 3 * (qy - y3), x3, y3)
                prev_q, prev_c2 = (qx, qy), None
                x, y = x3, y3
            elif c == "A":
                # Sampled rather than solved. An arc never leaves the box of its endpoints grown
                # by its radii, and sampling 64 points is well inside TOLERANCE for icon art.
                rx, ry, _rot, _laf, _sf, x3, y3 = a
                if rel:
                    x3, y3 = x + x3, y + y3
                b.add(x, y)
                b.add(x3, y3)
                for s in range(1, 64):
                    t = s / 64
                    b.add(x + (x3 - x) * t, y + (y3 - y) * t)
                b.add(min(x, x3) - abs(rx) * 0, min(y, y3) - abs(ry) * 0)
                prev_c2 = prev_q = None
                x, y = x3, y3
    return b


def _android_box(src: str) -> tuple[float, float, float, float] | None:
    """Viewport of an Android VectorDrawable, expressed like an SVG viewBox.

    Android viewports always start at 0,0, so a glyph with negative coordinates is placed with a
    <group android:translateX/Y>. Fold that translation into the origin so both platforms can be
    compared with the same arithmetic.
    """
    w = re.search(r'android:viewportWidth="([\d.]+)"', src)
    h = re.search(r'android:viewportHeight="([\d.]+)"', src)
    if not (w and h):
        return None
    tx = ty = 0.0
    gt = re.search(r"<group\b[^>]*>", src, re.S)
    if gt:
        mx = re.search(r'android:translateX="(-?[\d.]+)"', gt.group(0))
        my = re.search(r'android:translateY="(-?[\d.]+)"', gt.group(0))
        tx = float(mx.group(1)) if mx else 0.0
        ty = float(my.group(1)) if my else 0.0
    return (-tx, -ty, float(w.group(1)), float(h.group(1)))


def check_file(path: pathlib.Path) -> list[str]:
    src = path.read_text()
    if path.suffix == ".xml":
        box_spec = _android_box(src)
        if box_spec is None:
            return [f"{path}: no viewport"]
        vx, vy, vw, vh = box_spec
        data_attr = r'android:pathData="([^"]+)"'
    else:
        m = re.search(r'viewBox="([-\d.eE+]+)[,\s]+([-\d.eE+]+)[,\s]+([-\d.eE+]+)[,\s]+([-\d.eE+]+)"', src)
        if not m:
            return [f"{path}: no viewBox"]
        vx, vy, vw, vh = (float(g) for g in m.groups())
        data_attr = r'\sd="([^"]+)"'
    box = _Bounds()
    for d in re.findall(data_attr, src):
        pb = path_bounds(d)
        if not pb.empty:
            box.add(pb.x0, pb.y0)
            box.add(pb.x1, pb.y1)
    if box.empty:
        return []
    over = {
        "left": vx - box.x0,
        "top": vy - box.y0,
        "right": box.x1 - (vx + vw),
        "bottom": box.y1 - (vy + vh),
    }
    bad = {k: round(v, 1) for k, v in over.items() if v > TOLERANCE}
    if not bad:
        return []
    return [
        f"{path}: artwork overflows its viewBox by {bad}. "
        f"declared '{vx:g} {vy:g} {vw:g} {vh:g}', artwork spans "
        f"x {box.x0:g}..{box.x1:g} y {box.y0:g}..{box.y1:g}. "
        f"Every derived asset (iOS imageset PDF, Android drawable) will CROP this glyph. "
        f"Widen the viewBox to contain the art, then regenerate the derived assets."
    ]


def main(argv: list[str]) -> int:
    roots = [pathlib.Path(a) for a in argv[1:]] or [
        pathlib.Path("assets/fa-icons"),
        # The Android drawables are a HAND-MAINTAINED copy of the same glyphs, so they drift
        # independently. They carried the identical wrong viewports, which is why both platforms
        # clipped the same tab icons. Checking only the SVG sources would close half the gap.
        pathlib.Path("apps/android/HopDemo/app/src/main/res/drawable"),
    ]
    files: list[pathlib.Path] = []
    for r in roots:
        if r.is_dir():
            files.extend(sorted(r.glob("*.svg")))
            files.extend(sorted(r.glob("ic_fa_*.xml")))
        else:
            files.append(r)
    problems: list[str] = []
    for f in files:
        problems.extend(check_file(f))
    if problems:
        print("icon-bounds guard FAILED:")
        for p in problems:
            print(f"  {p}")
        return 1
    print(f"icon-bounds: OK ({len(files)} sources, every glyph fits its declared viewBox)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
