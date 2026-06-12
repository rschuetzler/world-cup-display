#!/usr/bin/env python3
"""Fetch one 128x64 RGB565 frame from a running TravisTracker and save a PNG.

Exercises the exact decode path the firmware uses, so the wire format is proven
before any hardware exists.

Usage:
    python3 tools/matrix_sim.py http://127.0.0.1:4000/preview/in_flight/matrix.rgb565
    python3 tools/matrix_sim.py <url> --scale 8 --out frame.png
"""
import argparse
import urllib.request
from PIL import Image

W, H = 128, 64


def decode_rgb565_le(data: bytes) -> Image.Image:
    if len(data) != W * H * 2:
        raise ValueError(f"expected {W * H * 2} bytes, got {len(data)}")
    img = Image.new("RGB", (W, H))
    px = img.load()
    for i in range(W * H):
        v = data[i * 2] | (data[i * 2 + 1] << 8)  # little-endian
        r5, g6, b5 = (v >> 11) & 0x1F, (v >> 5) & 0x3F, v & 0x1F
        px[i % W, i // W] = (
            (r5 << 3) | (r5 >> 2),
            (g6 << 2) | (g6 >> 4),
            (b5 << 3) | (b5 >> 2),
        )
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("--scale", type=int, default=8)
    ap.add_argument("--out", default="frame.png")
    args = ap.parse_args()

    with urllib.request.urlopen(args.url) as resp:
        body = resp.read()
        for h in ("X-Display-State", "X-Poll-Seconds", "ETag"):
            print(f"{h}: {resp.headers.get(h)}")

    img = decode_rgb565_le(body)
    img = img.resize((W * args.scale, H * args.scale), Image.NEAREST)
    img.save(args.out)
    print(f"wrote {args.out} ({img.width}x{img.height})")


if __name__ == "__main__":
    main()
