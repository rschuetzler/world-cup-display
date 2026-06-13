// Native Geist Pixel Square numerals at arbitrary heights — port of the
// nativeGlyph / geist_bits / resample_lit? / big_center block in
// WcRenderers (wc_renderers.ex:558-662). The design-size bitmap (cap height 19)
// is area-resampled by scale = h/19 with the 0.42 coverage threshold, glyphs
// composed on real advance widths, then the inked string trimmed and centred.
//
// Only digits 0-9 and '-' are embedded (gen/geist_data.h) — big numerals are
// used solely for scores like "2-1".
#pragma once
#include "fb.h"
#include "rgb.h"

namespace Geist {
// Big numerals centred on cx at cap height h.
void bigCenter(Fb& fb, int cx, int y, const char* str, int h, Rgb color);
}  // namespace Geist
