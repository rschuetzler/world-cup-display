// The three World Cup boards — direct port of WorldCupTracker.Matrix.WcRenderers.
// Pure functions of the Snapshot (every animation reads snap.now), painting into
// the framebuffer.
#pragma once
#include "fb.h"
#include "snapshot.h"

namespace Render {
void board(Fb& fb, const Snapshot& s);
}  // namespace Render
