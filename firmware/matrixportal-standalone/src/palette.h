// Named colors for the matrix renderers — port of Matrix.Palette (the WC half
// of the `P` map). Only the tokens the World Cup boards actually use are kept;
// the flight/weather tokens are dropped.
#pragma once
#include "rgb.h"

namespace Pal {
// From Matrix.Palette @p — values verbatim.
constexpr Rgb white = {0xD4, 0xE3, 0xFF};
constexpr Rgb soft = {0x9F, 0xB2, 0xD8};
constexpr Rgb dim = {0x5E, 0x6E, 0x92};
constexpr Rgb faint = {0x2F, 0x3A, 0x59};
constexpr Rgb ice = {0x8A, 0xB0, 0xFF};
constexpr Rgb wc_white = {0xE4, 0xEC, 0xFF};
constexpr Rgb live = {0xFF, 0x54, 0x54};
constexpr Rgb gold = {0xFF, 0xCF, 0x5C};
constexpr Rgb pitch = {0x46, 0xD0, 0x7F};
constexpr Rgb win = {0x5C, 0xE0, 0x98};
constexpr Rgb ball = {0xEA, 0xF2, 0xFF};
}  // namespace Pal
