#include "brightness.h"
#include <math.h>
#include <time.h>

namespace {
uint8_t gammaLut[256];

inline float lerp(float a, float b, float t) { return a + (b - a) * t; }

const float DAY = 1.0f;
const float NIGHT = 0.25f;
}  // namespace

namespace Brightness {

void init() {
  for (int v = 0; v < 256; v++) {
    gammaLut[v] = (uint8_t)lroundf(powf(v / 255.0f, 2.2f) * 255.0f);
  }
}

// Mirrors Brightness.for_hour/1 exactly.
float forHour(float h) {
  if (h >= 8.0f && h <= 18.0f) return DAY;
  if (h >= 6.0f && h < 8.0f) return lerp(NIGHT, DAY, (h - 6.0f) / 2.0f);
  if (h > 18.0f && h <= 22.0f) return lerp(DAY, NIGHT, (h - 18.0f) / 4.0f);
  return NIGHT;
}

float forNow(int64_t nowMs) {
  time_t secs = (time_t)(nowMs / 1000);
  struct tm lt;
  localtime_r(&secs, &lt);
  return forHour(lt.tm_hour + lt.tm_min / 60.0f);
}

Rgb correct(Rgb c, float scalar) {
  auto scale = [&](uint8_t v) -> uint8_t {
    long s = lroundf(gammaLut[v] * scalar);
    return s > 255 ? 255 : (uint8_t)s;
  };
  return {scale(c.r), scale(c.g), scale(c.b)};
}

}  // namespace Brightness
