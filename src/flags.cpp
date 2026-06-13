#include "flags.h"
#include <string.h>
#include "gen/flags_data.h"

namespace {
const int BASE_W = 26;
const int BASE_H = 17;

// Unknown-code checker colors, as the JS reference / Matrix.Flags use.
const Rgb GREY = {0x3A, 0x41, 0x50};
const Rgb DIM_BLACK = {0x26, 0x2B, 0x38};

const FlagEntry* find(const char* code) {
  if (!code) return nullptr;
  for (int i = 0; i < FLAG_COUNT; i++)
    if (strcmp(FLAGS[i].code, code) == 0) return &FLAGS[i];
  return nullptr;
}

void blit(Fb& fb, int ox, int oy, int w, const uint8_t* px, int count) {
  for (int i = 0; i < count; i++) {
    const uint8_t* p = px + i * 3;
    fb.set(ox + i % w, oy + i / w, {p[0], p[1], p[2]});
  }
}

// Nearest-neighbor scale from the 26x17 hero art.
void scaleBlit(Fb& fb, int ox, int oy, int w, int h, const uint8_t* base) {
  for (int fy = 0; fy < h; fy++)
    for (int fx = 0; fx < w; fx++) {
      int sx = fx * BASE_W / w;
      int sy = fy * BASE_H / h;
      const uint8_t* p = base + (sy * BASE_W + sx) * 3;
      fb.set(ox + fx, oy + fy, {p[0], p[1], p[2]});
    }
}

void checker(Fb& fb, int ox, int oy, int w, int h) {
  for (int fy = 0; fy < h; fy++)
    for (int fx = 0; fx < w; fx++)
      fb.set(ox + fx, oy + fy, ((fx + fy) % 2 == 1) ? GREY : DIM_BLACK);
}
}  // namespace

namespace Flags {

void draw(Fb& fb, int ox, int oy, int w, int h, const char* code) {
  const FlagEntry* e = find(code);
  if (!e) {
    checker(fb, ox, oy, w, h);
    return;
  }
  if (w == 10 && h == 7)
    blit(fb, ox, oy, w, e->px10x7, 10 * 7);
  else if (w == 12 && h == 8)
    blit(fb, ox, oy, w, e->px12x8, 12 * 8);
  else if (w == BASE_W && h == BASE_H)
    blit(fb, ox, oy, w, e->px26x17, BASE_W * BASE_H);
  else
    scaleBlit(fb, ox, oy, w, h, e->px26x17);
}

bool has(const char* code) { return find(code) != nullptr; }

bool accent(const char* code, Rgb& out) {
  const FlagEntry* e = find(code);
  if (!e) return false;
  out = {e->ar, e->ag, e->ab};
  return true;
}

}  // namespace Flags
