// Normalized representation of a single match — port of WorldCupTracker.Match.
// Source-independent; built by the ESPN parser, held by the Store.
#pragma once
#include <Arduino.h>
#include <stdint.h>

enum class MatchState { Scheduled, Live, Halftime, Finished };

struct Side {
  String name;    // displayName (or name)
  String abbrev;  // may be empty
  bool hasScore;  // false == nil score (distinct from 0 — matters for goal detection)
  int score;      // valid only when hasScore
};

struct Match {
  String id;
  int64_t kickoffMs;  // epoch ms; valid only when hasKickoff
  bool hasKickoff;
  String round;  // may be empty
  Side home;
  Side away;
  MatchState state;
  String clock;  // displayClock, may be empty
};

inline bool isLiveState(MatchState s) {
  return s == MatchState::Live || s == MatchState::Halftime;
}
