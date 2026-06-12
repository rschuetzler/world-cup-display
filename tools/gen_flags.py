#!/usr/bin/env python3
"""Bake the designer flag PNGs (assets/flags/) into priv/matrix/flags.json.

For each of the 48 team codes:
  - 26x17: the hand-tuned native pixel art, verbatim (hero size).
  - 12x8 and 10x7: area-averaged downsamples of the 416x272 large export,
    with each cell snapped to the nearest color in that flag's native palette
    so small flags stay LED-crisp instead of going muddy.
  - accent: the most saturated, well-covered palette color (used to theme the
    goal celebration for teams without a hand-picked color in Teams).

Output shape:
  {"CODE": {"accent": "RRGGBB",
            "sizes": {"26x17": "RRGGBB...", "12x8": "...", "10x7": "..."}}}

Run from the repo root: python3 tools/gen_flags.py
"""

import colorsys
import json
import os

from PIL import Image

NATIVE_DIR = "assets/flags/native_26x17"
LARGE_DIR = "assets/flags/large_416x272"
OUT_PATH = "priv/matrix/flags.json"
SMALL_SIZES = [(12, 8), (10, 7)]


def palette(im):
    return [c for _count, c in im.getcolors(im.width * im.height)]


def nearest(color, pal):
    r, g, b = color
    return min(pal, key=lambda p: (p[0] - r) ** 2 + (p[1] - g) ** 2 + (p[2] - b) ** 2)


def downsample_snapped(large, w, h, pal):
    """Area-average `large` to w*h, then snap each cell to the native palette."""
    avg = large.resize((w, h), Image.BOX)
    return [nearest(avg.getpixel((x, y)), pal) for y in range(h) for x in range(w)]


def downsample_centers(native, w, h):
    """Point-sample the native art at each cell center. Preserves thin stripes
    that area-averaging smears into the background (e.g. Curaçao's yellow)."""
    nw, nh = native.size
    return [
        native.getpixel((int((x + 0.5) * nw / w), int((y + 0.5) * nh / h)))
        for y in range(h)
        for x in range(w)
    ]


def coverage(pixels):
    counts = {}
    for p in pixels:
        counts[p] = counts.get(p, 0) + 1
    total = len(pixels)
    return {c: n / total for c, n in counts.items()}


def rescue_missing_bands(native, pixels, w, h, min_cov=0.04):
    """Stamp back significant native colors that the downsample lost entirely.

    A thin stripe (Curaçao's 1-row yellow) can fall between sample rows at 7px
    tall no matter how the cells are placed. For each native color with
    >= min_cov coverage that's absent from the result: if it dominates whole
    native rows (a horizontal band) repaint the mapped small row, likewise for
    columns. Non-band devices (stars, emblems) are left to die gracefully.
    """
    nw, nh = native.size
    nat = list(native.getdata())
    present = set(pixels)
    for color, cov in coverage(nat).items():
        if cov < min_cov or color in present:
            continue
        band_rows = [
            y for y in range(nh) if sum(nat[y * nw + x] == color for x in range(nw)) >= 0.6 * nw
        ]
        band_cols = [
            x for x in range(nw) if sum(nat[y * nw + x] == color for y in range(nh)) >= 0.6 * nh
        ]
        if band_rows:
            sy = min(h - 1, round((sum(band_rows) / len(band_rows)) * h / nh))
            for x in range(w):
                pixels[sy * w + x] = color
        elif band_cols:
            sx = min(w - 1, round((sum(band_cols) / len(band_cols)) * w / nw))
            for y in range(h):
                pixels[y * w + sx] = color
    return pixels


def downsample(native, large, w, h, pal):
    """Pick whichever downsample keeps the flag's color distribution closest
    to the native art (L1 distance over per-color coverage), then rescue any
    significant band color both methods lost. Area-averaging wins on striped
    fields (USA); center sampling wins on offset features (BIH's diagonal)."""
    native_cov = coverage(list(native.getdata()))
    candidates = [
        downsample_snapped(large, w, h, pal),
        downsample_centers(native, w, h),
    ]

    def fidelity(pixels):
        cov = coverage(pixels)
        return sum(abs(cov.get(c, 0.0) - native_cov.get(c, 0.0)) for c in set(cov) | set(native_cov))

    return rescue_missing_bands(native, min(candidates, key=fidelity), w, h)


def accent(im):
    """Most saturated palette color, weighted by coverage; avoids the dim-grey
    'black' and near-white field colors that would theme the goal board badly."""
    best, best_score = None, -1.0
    for count, (r, g, b) in im.getcolors(im.width * im.height):
        hue, sat, val = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
        if val < 0.35:  # dim-grey "black" fields
            continue
        coverage = count / (im.width * im.height)
        score = (sat + 0.15) * (coverage**0.5) * val
        if score > best_score:
            best_score, best = score, (r, g, b)
    # LED-friendly floor: lift very dark accents toward readable brightness
    hue, sat, val = colorsys.rgb_to_hsv(*(c / 255 for c in best))
    if val < 0.65:
        best = tuple(round(c * 255) for c in colorsys.hsv_to_rgb(hue, sat, 0.65))
    return best


def hexs(pixels):
    return "".join(f"{r:02x}{g:02x}{b:02x}" for (r, g, b) in pixels)


def main():
    out = {}
    for fname in sorted(os.listdir(NATIVE_DIR)):
        code = os.path.splitext(fname)[0]
        native = Image.open(os.path.join(NATIVE_DIR, fname)).convert("RGB")
        large = Image.open(os.path.join(LARGE_DIR, fname)).convert("RGB")
        pal = palette(native)
        sizes = {"26x17": hexs(list(native.getdata()))}
        for w, h in SMALL_SIZES:
            sizes[f"{w}x{h}"] = hexs(downsample(native, large, w, h, pal))
        out[code] = {"accent": "%02x%02x%02x" % accent(native), "sizes": sizes}

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w") as f:
        json.dump(out, f, separators=(",", ":"), sort_keys=True)
    print(f"{len(out)} flags -> {OUT_PATH} ({os.path.getsize(OUT_PATH)} bytes)")


if __name__ == "__main__":
    main()
