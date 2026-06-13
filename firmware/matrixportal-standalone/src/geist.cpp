#include "geist.h"
#include <math.h>
#include <string.h>
#include "gen/geist_data.h"

namespace {
inline int rnd(float v) { return (int)lroundf(v); }

const GeistGlyph* findGlyph(char ch) {
  for (int i = 0; i < GEIST_GLYPH_COUNT; i++)
    if (GEIST_GLYPHS[i].ch == ch) return &GEIST_GLYPHS[i];
  return nullptr;
}

// Area-average the source cells covered by output pixel (ox, oy); lit when
// coverage > 0.42. Out-of-range source cells count toward the total but unlit,
// exactly as the JS's undefined-row reads behave.
bool resampleLit(const uint8_t* bits, int srcW, int srcH, int ox, int oy, float inv) {
  float sy0 = oy * inv, sy1 = (oy + 1) * inv;
  float sx0 = ox * inv, sx1 = (ox + 1) * inv;
  int sy_lo = (int)floorf(sy0), sy_hi = (int)ceilf(sy1) - 1;
  int sx_lo = (int)floorf(sx0), sx_hi = (int)ceilf(sx1) - 1;
  int lit = 0, tot = 0;
  for (int sy = sy_lo; sy <= sy_hi; sy++) {
    for (int sx = sx_lo; sx <= sx_hi; sx++) {
      int cell = (sy >= 0 && sy < srcH && sx >= 0 && sx < srcW) ? bits[sy * srcW + sx] : 0;
      lit += cell;
      tot += 1;
    }
  }
  return tot > 0 && (float)lit / tot > 0.42f;
}

struct Placed {
  const GeistGlyph* g;  // source glyph (for re-resampling at draw time)
  int xabs;             // pen + round(xoff*scale)
  int top;              // round((cap - yoff)*scale)
  int w;                // round(width*scale)
  int gw, gh;           // output cell size (max(1, round(dim*scale)))
};
const int MAX_PLACED = 16;
}  // namespace

namespace Geist {

void bigCenter(Fb& fb, int cx, int y, const char* str, int h, Rgb color) {
  float scale = (float)h / GEIST_CAP_HEIGHT;
  float inv = 1.0f / scale;
  int spaceAdv = rnd(GEIST_SPACE_ADV * scale);

  Placed placed[MAX_PLACED];
  int n = 0;
  int pen = 0;

  for (const char* p = str; *p && n < MAX_PLACED; p++) {
    char ch = *p;
    if (ch == ' ') {
      pen += spaceAdv;
      continue;
    }
    const GeistGlyph* g = findGlyph(ch);
    if (g && g->width > 0) {
      Placed& pl = placed[n++];
      pl.g = g;
      pl.xabs = pen + rnd(g->xoff * scale);
      pl.top = rnd((GEIST_CAP_HEIGHT - g->yoff) * scale);
      pl.w = rnd(g->width * scale);
      pl.gw = g->width * scale < 1 ? 1 : rnd(g->width * scale);
      pl.gh = g->height * scale < 1 ? 1 : rnd(g->height * scale);
      if (pl.gw < 1) pl.gw = 1;
      if (pl.gh < 1) pl.gh = 1;
      pen += rnd(g->advance * scale);
    } else {
      // Unknown/inkless char: advance by '0' width (mirrors nativeGlyph nil case).
      const GeistGlyph* zero = findGlyph('0');
      pen += rnd((zero ? zero->advance : GEIST_SPACE_ADV) * scale);
    }
  }

  if (n == 0) return;

  int minX = placed[0].xabs;
  int maxX = placed[0].xabs + placed[0].w;
  for (int i = 1; i < n; i++) {
    if (placed[i].xabs < minX) minX = placed[i].xabs;
    if (placed[i].xabs + placed[i].w > maxX) maxX = placed[i].xabs + placed[i].w;
  }
  int width = maxX - minX;
  if (width < 1) width = 1;

  int x0 = rnd(cx - width / 2.0f);

  for (int i = 0; i < n; i++) {
    Placed& pl = placed[i];
    int gx = pl.xabs - minX;
    for (int oy = 0; oy < pl.gh; oy++)
      for (int ox = 0; ox < pl.gw; ox++)
        if (resampleLit(pl.g->bits, pl.g->width, pl.g->height, ox, oy, inv))
          fb.add(x0 + gx + ox, y + pl.top + oy, color, 1.0f);
  }
}

}  // namespace Geist
