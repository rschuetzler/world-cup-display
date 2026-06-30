// Owns the current tournament state — port of WorldCupTracker.Store. Holds the
// merged match list (by id), group standings, and edge-detected goal/finished
// events. Goal events are detected on write (a live match's score strictly
// rising), kept 60s; full-time transitions (live -> finished) kept 60min.
//
// A FreeRTOS mutex guards all access: the net task writes (put/putStandings),
// the render task reads a consistent batch via capture().
#pragma once
#include <Arduino.h>
#include <vector>
#include "espn.h"
#include "match.h"

struct GoalEvent {
  String matchId;
  int team;  // 0 = home, 1 = away
  Match match;
  int64_t atMs;
};

struct RecentFinal {
  Match match;
  int64_t finishedAtMs;
};

// A consistent batch of everything the snapshot builder needs, copied under one
// lock so the 60fps render task never races the poller.
struct StoreView {
  std::vector<Match> live;
  std::vector<Match> next;
  std::vector<RecentFinal> finals;
  std::vector<GoalEvent> goals;
  std::vector<Group> standings;
};

class Store {
 public:
  void begin();

  // Merge today's/schedule matches in by id, edge-detecting goals + finals.
  void put(const std::vector<Match>& matches);
  void putStandings(const std::vector<Group>& groups);
  // Attach per-kick shootout results (from the summary endpoint) to a match.
  void putShootout(const String& matchId, const std::vector<int8_t>& kicksHome,
                   const std::vector<int8_t>& kicksAway);

  // For the poller's cadence choice.
  std::vector<Match> schedule();
  std::vector<GoalEvent> goalEvents(int64_t now);

  // One locked batch for the renderer.
  StoreView capture(int64_t now, int64_t finalHoldMs);

 private:
  SemaphoreHandle_t mutex_ = nullptr;
  std::vector<Match> matches_;
  std::vector<GoalEvent> goals_;
  std::vector<Group> standings_;

  struct FinishedRec {
    String matchId;
    int64_t atMs;
  };
  std::vector<FinishedRec> finished_;

  Match* findById(const String& id);
};
