// ESPN site-API parsers — port of WorldCupTracker.Espn. Deserializes the
// scoreboard and standings payloads (ArduinoJson, filtered, PSRAM-backed) into
// Match structs and group tables. Parsing streams straight from the HTTP body.
#pragma once
#include <Arduino.h>
#include <vector>
#include "match.h"

struct GroupEntry {
  String team;    // displayName
  String abbrev;  // abbreviation
};
struct Group {
  String name;  // e.g. "Group A"
  std::vector<GroupEntry> entries;
};

namespace Espn {
// Parse a scoreboard body (a NUL-terminated buffer of `len` bytes) into Match
// structs, sorted by kickoff. Returns false on a JSON error (the caller keeps
// the last good store contents). The buffer may be modified in place (zero-copy
// string extraction); the resulting Matches own independent String copies.
bool parseScoreboard(char* buf, size_t len, std::vector<Match>& out);

// Parse a standings body into groups (name + member teams only — enough for the
// live board's group-letter label).
bool parseStandings(char* buf, size_t len, std::vector<Group>& out);

// Parse the per-match summary body's `shootout` array into ordered per-kick
// results (1 scored, 0 missed) for the home/away sides, keyed by ESPN team id.
// Returns false on JSON error or if no shootout data is present.
bool parseShootout(char* buf, size_t len, const String& homeId, const String& awayId,
                   std::vector<int8_t>& kicksHome, std::vector<int8_t>& kicksAway);

// Map an ESPN status state/detail pair to a MatchState (exposed for clarity).
MatchState stateFromStatus(const char* state, const char* detail, const char* name);
}  // namespace Espn
