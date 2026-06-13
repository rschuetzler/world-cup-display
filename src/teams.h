// World Cup team table — port of Matrix.Teams. Maps a 3-letter code to the full
// country name (the goal marquee renders names) and the team's accent color.
//
// Hand-picked entries (from wc-data.js) carry design-authoritative names+colors;
// the rest are "derived" — font-safe names here, with colors pulled from the
// baked flag accents (Flags::accent). Unknown codes echo the code and get the
// design's neutral-white fallback.
#pragma once
#include "rgb.h"

namespace Teams {
const char* name(const char* code);
Rgb color(const char* code);
}  // namespace Teams
