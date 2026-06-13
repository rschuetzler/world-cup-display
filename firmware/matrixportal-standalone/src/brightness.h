// Time-of-day brightness scaling + gamma 2.2 — port of Matrix.Brightness.
// The framebuffer stays full-range; correction is applied only when the frame
// is pushed to the panel (Fb present, in main.cpp). The device's single local
// timezone (set via POSIX TZ) drives auto-dimming: full by day, dim overnight.
#pragma once
#include <stdint.h>
#include "rgb.h"

namespace Brightness {
// Build the gamma-2.2 lookup table. Call once at boot.
void init();

// Brightness scalar 0.25..1.0 for a local hour-of-day (0.0..24.0).
float forHour(float h);

// Brightness scalar for the device's local time at epoch-ms `nowMs`.
float forNow(int64_t nowMs);

// Gamma-correct each channel, then scale by `scalar` (0..1), clamped 0..255.
Rgb correct(Rgb c, float scalar);
}  // namespace Brightness
