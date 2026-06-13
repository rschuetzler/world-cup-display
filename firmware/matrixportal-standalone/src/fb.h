// A 128x64 RGB surface — port of Matrix.Framebuffer. Stored densely as
// buf[y][x][channel] (full-range 0..255); cleared to black each frame.
//
// add/4 is additive and clamps each channel at 255 (overlapping writes stack);
// set/4 replaces; rect/6 is an additive fill. Off-panel coordinates are
// silently ignored so callers can blit near the edges without bounds checks.
// Matches the Elixir semantics exactly, including round-half-away-from-zero
// (lroundf) on the blended channel.
#pragma once
#include <math.h>
#include <string.h>
#include <stdint.h>
#include "rgb.h"

class Fb {
 public:
  static const int W = 128;
  static const int H = 64;
  uint8_t buf[H][W][3];

  void clear() { memset(buf, 0, sizeof(buf)); }

  inline void set(int x, int y, Rgb c) {
    if (x < 0 || x >= W || y < 0 || y >= H) return;
    buf[y][x][0] = c.r;
    buf[y][x][1] = c.g;
    buf[y][x][2] = c.b;
  }

  inline void add(int x, int y, Rgb c, float a = 1.0f) {
    if (x < 0 || x >= W || y < 0 || y >= H) return;
    long r = lroundf(buf[y][x][0] + c.r * a);
    long g = lroundf(buf[y][x][1] + c.g * a);
    long b = lroundf(buf[y][x][2] + c.b * a);
    buf[y][x][0] = r > 255 ? 255 : (uint8_t)r;
    buf[y][x][1] = g > 255 ? 255 : (uint8_t)g;
    buf[y][x][2] = b > 255 ? 255 : (uint8_t)b;
  }

  inline void rect(int x, int y, int w, int h, Rgb c, float a = 1.0f) {
    for (int xx = 0; xx < w; xx++)
      for (int yy = 0; yy < h; yy++) add(x + xx, y + yy, c, a);
  }

  inline void hline(int x, int y, int w, Rgb c, float a = 1.0f) { rect(x, y, w, 1, c, a); }
};
