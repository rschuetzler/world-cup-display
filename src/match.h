// Normalized representation of a single match — port of WorldCupTracker.Match.
// Source-independent; built by the ESPN parser, held by the Store.
#pragma once
#include <Arduino.h>
#include <stdint.h>
#include <vector>

// Halftime here means "any in-progress intermission with the clock stopped" —
// regulation half-time, end of regulation before extra time, the extra-time
// interval, and the pause before penalties. The exact phase is derived
// downstream from `period` and `minute`.
enum class MatchState { Scheduled, Live, Halftime, Finished };

struct Side {
  String name;    // displayName (or name)
  String abbrev;  // may be empty
  String teamId;  // ESPN numeric team id (matches the summary shootout array)
  bool hasScore;  // false == nil score (distinct from 0 — matters for goal detection)
  int score;      // valid only when hasScore
  int shootoutScore = 0;  // running penalty-shootout tally (scoreboard "shootoutScore")
};

struct Match {
  String id;
  int64_t kickoffMs;  // epoch ms; valid only when hasKickoff
  bool hasKickoff;
  String round;  // round name, from the season slug (e.g. "Round Of 32")
  String note;   // result blurb, populated at full time (e.g. "X advance ...")
  Side home;
  Side away;
  MatchState state;
  String clock;     // displayClock, may be empty
  int minute = 0;   // base minute parsed from clock ("45'+4'" -> 45)
  int stoppage = 0; // added minutes ("45'+4'" -> 4), 0 if none
  int period = 0;   // 1 1st half, 2 2nd half, 3/4 extra time, 5 penalties
  // Per-kick shootout results in order (1 scored, 0 missed), from the summary
  // endpoint; empty until fetched. Length implies kicks taken per side.
  bool hasShootout = false;
  std::vector<int8_t> kicksHome;
  std::vector<int8_t> kicksAway;
};

inline bool isLiveState(MatchState s) {
  return s == MatchState::Live || s == MatchState::Halftime;
}
