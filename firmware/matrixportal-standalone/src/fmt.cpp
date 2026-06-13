#include "fmt.h"
#include <time.h>

namespace {
const char* WEEKDAYS[7] = {"MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"};

const int64_t MINUTE_MS = 60000;
const int64_t HOUR_MS = 60 * MINUTE_MS;
const int64_t DAY_MS = 24 * HOUR_MS;

struct tm localOf(int64_t ms) {
  time_t secs = (time_t)(ms / 1000);
  struct tm lt;
  localtime_r(&secs, &lt);
  return lt;
}
}  // namespace

namespace Fmt {

String clock(int64_t ms) {
  struct tm lt = localOf(ms);
  char buf[6];
  snprintf(buf, sizeof(buf), "%02d:%02d", lt.tm_hour, lt.tm_min);
  return String(buf);
}

const char* weekday(int64_t ms) {
  struct tm lt = localOf(ms);
  // tm_wday: 0=Sun..6=Sat -> Mon-first index (Date.day_of_week - 1).
  return WEEKDAYS[(lt.tm_wday + 6) % 7];
}

bool sameLocalDay(int64_t a, int64_t b) {
  struct tm la = localOf(a), lb = localOf(b);
  return la.tm_year == lb.tm_year && la.tm_mon == lb.tm_mon && la.tm_mday == lb.tm_mday;
}

Ko ko(int64_t ms, int64_t now) {
  Ko out;
  out.cl = clock(ms);
  out.wd = sameLocalDay(ms, now) ? String("") : String(weekday(ms));
  return out;
}

String countdownLabel(int64_t deltaMs) {
  char buf[16];
  if (deltaMs < MINUTE_MS) return String("SOON");
  if (deltaMs < HOUR_MS) {
    snprintf(buf, sizeof(buf), "%dM", (int)(deltaMs / MINUTE_MS));
  } else if (deltaMs < DAY_MS) {
    snprintf(buf, sizeof(buf), "%dH %dM", (int)(deltaMs / HOUR_MS),
             (int)((deltaMs % HOUR_MS) / MINUTE_MS));
  } else {
    snprintf(buf, sizeof(buf), "%dD %dH", (int)(deltaMs / DAY_MS),
             (int)((deltaMs % DAY_MS) / HOUR_MS));
  }
  return String(buf);
}

}  // namespace Fmt
