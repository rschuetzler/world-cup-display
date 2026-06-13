// Clock/weekday/countdown formatting — port of Matrix.Fmt plus the ko/
// countdown_label helpers in WcRenderers. The device runs in a single local
// timezone (set via POSIX TZ in main), so these use localtime_r directly rather
// than threading an IANA tz string like the server does.
#pragma once
#include <Arduino.h>
#include <stdint.h>

namespace Fmt {
// HH:MM, 24-hour, zero-padded (the boards bake clock24 on).
String clock(int64_t ms);

// MON..SUN for the local weekday at `ms`.
const char* weekday(int64_t ms);

// Whether `a` and `b` fall on the same local calendar day.
bool sameLocalDay(int64_t a, int64_t b);

// Kickoff label parts: bare HH:MM if `ms` is today (relative to `now`), else a
// weekday + the time. `wd` is empty when it's today.
struct Ko {
  String wd;
  String cl;
};
Ko ko(int64_t ms, int64_t now);

// Compact countdown until kickoff for `deltaMs`:
//   >=24h "1D 2H" · >=1h "2H 14M" · >=1min "14M" · <1min "SOON".
String countdownLabel(int64_t deltaMs);
}  // namespace Fmt
