// Designer pixel-art LED flags — port of Matrix.Flags. Each of the 48 team
// codes carries three baked bitmaps (26x17 hero, 12x8 ribbon, 10x7 row); those
// blit verbatim, any other size is nearest-neighbor scaled from the 26x17 art,
// and unknown codes draw a grey checker box. Pixel data lives in gen/flags_data.h.
#pragma once
#include "fb.h"
#include "rgb.h"

namespace Flags {
void draw(Fb& fb, int ox, int oy, int w, int h, const char* code);
bool has(const char* code);
// Accent color for `code` (the asset pipeline's "accent" field). Returns false
// if the code has no baked flag.
bool accent(const char* code, Rgb& out);
}  // namespace Flags
