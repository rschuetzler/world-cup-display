// Pure snapshot builder between the Store and the board renderers — port of
// WorldCupTracker.Display.State. Chooses one board in priority order
// (goal > live > final-hold > now_next) and flattens the store data into a
// plain Snapshot the renderers consume. No favorite team: with several live
// matches it always falls to now_next.
#pragma once
#include <Arduino.h>
#include <vector>
#include "store.h"

enum class Board { NowNext, Live, Goal };

struct LiveRow {
  String home, away;  // codes
  int hs, as;
  int64_t kickoffMs;
  bool paused;      // clock stopped (half-time / extra-time interval / pre-pens)
  bool final;       // game over -> show FINAL instead of a running clock
  int minute;       // API base minute ("45'+4'" -> 45)
  int stoppage;     // API added minutes ("45'+4'" -> 4), 0 if none
  int period;       // 1/2 regulation, 3/4 extra time, 5 penalties
};

struct NextRow {
  String home, away;  // codes
  int64_t kickoffMs;
};

struct Snapshot {
  Board state;
  int64_t now;
  bool flags;  // show flags? (always true on-device; the renderers keep the off path)

  // now_next
  std::vector<LiveRow> live;
  std::vector<NextRow> next;

  // live / goal (the chosen match, as codes)
  bool finalHold;
  bool paused;    // clock stopped (half-time / extra-time interval / pre-pens)
  int minute, hs, as;
  int stoppage;   // added minutes (the "+N" in "45'+4'"), 0 if none
  int period;     // 1/2 regulation, 3/4 extra time, 5 penalties
  String stage, home, away;
  int64_t kickoffMs;

  // goal
  int64_t goalStartedAt;
  int team;     // 0 home, 1 away
  String code;  // scoring team code
};

namespace SnapshotBuilder {
Snapshot build(const StoreView& v, int64_t now);

// Exposed for completeness / testing.
int parseMinute(const String& clock);
}  // namespace SnapshotBuilder
