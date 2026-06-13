// 5x7 uppercase bitmap font + text helpers — port of Matrix.Font.
// Bit 0x10 is the leftmost column; 7 rows; glyph advance is 6px (5 + 1 gap).
// Strings are upcased before drawing. Unknown chars fall back to the space
// glyph (advance preserved) — e.g. the apostrophe in "78'" renders blank, just
// as the Elixir font (which has no ' glyph) does.
#pragma once
#include "fb.h"
#include "rgb.h"

namespace Font {
int textW(const char* s);    // len*6 - 1
int text2xW(const char* s);  // len*12 - 2

void text(Fb& fb, int x, int y, const char* s, Rgb color, float a = 1.0f);
void textCenter(Fb& fb, int cx, int y, const char* s, Rgb color, float a = 1.0f);
void textRight(Fb& fb, int xRight, int y, const char* s, Rgb color, float a = 1.0f);
void text2x(Fb& fb, int x, int y, const char* s, Rgb color, float a = 1.0f);
}  // namespace Font
