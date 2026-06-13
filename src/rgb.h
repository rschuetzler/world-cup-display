// An {r,g,b} color, 0..255 per channel — the C++ analogue of the Elixir
// renderers' {r, g, b} tuples (Matrix.Framebuffer.rgb()).
#pragma once
#include <stdint.h>

struct Rgb {
  uint8_t r, g, b;
};
