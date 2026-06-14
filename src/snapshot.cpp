#include "snapshot.h"
#include <ctype.h>

namespace {
const int64_t GOAL_DURATION_MS = 16500;
const int64_t FINAL_HOLD_MS = 20 * 60 * 1000;
const int MAX_LIVE_ROWS = 2;

String upcase(const String& s) {
  String o = s;
  o.toUpperCase();
  return o;
}

// 3-letter display code for a side: abbrev if present, else first 3 of name
// upcased, else "".
String code(const Side& s) {
  if (s.abbrev.length() > 0) return s.abbrev;
  if (s.name.length() > 0) return upcase(s.name.substring(0, 3));
  return String("");
}

int score(const Side& s) { return s.hasScore ? s.score : 0; }

bool groupHasSide(const Group& g, const Match& m) {
  for (const auto& e : g.entries) {
    if (m.home.name.length() && e.team == m.home.name) return true;
    if (m.away.name.length() && e.team == m.away.name) return true;
    if (m.home.abbrev.length() && e.abbrev == m.home.abbrev) return true;
    if (m.away.abbrev.length() && e.abbrev == m.away.abbrev) return true;
  }
  return false;
}

String stageLabel(const Match& m, const std::vector<Group>& standings) {
  String lower = m.round;
  lower.toLowerCase();
  bool groupStage = m.round.length() > 0 && lower.indexOf("group") >= 0;
  if (groupStage) {
    for (const auto& g : standings)
      if (g.name.length() > 0 && groupHasSide(g, m)) return upcase(g.name);
  }
  return upcase(m.round);  // "" round -> ""
}

Snapshot liveSnapshot(const Match& m, const StoreView& v, int64_t now) {
  Snapshot s{};
  s.state = Board::Live;
  s.now = now;
  s.flags = true;
  s.finalHold = false;
  s.ht = m.state == MatchState::Halftime;
  s.minute = m.minute;
  s.stoppage = m.stoppage;
  s.hs = score(m.home);
  s.as = score(m.away);
  s.stage = stageLabel(m, v.standings);
  s.home = code(m.home);
  s.away = code(m.away);
  s.kickoffMs = m.hasKickoff ? m.kickoffMs : now;
  return s;
}

Snapshot nowNextSnapshot(const StoreView& v, int64_t now) {
  Snapshot s{};
  s.state = Board::NowNext;
  s.now = now;
  s.flags = true;
  // No favorite team -> live rows are simply the first two in kickoff order.
  for (const auto& m : v.live) {
    if ((int)s.live.size() >= MAX_LIVE_ROWS) break;
    LiveRow r;
    r.home = code(m.home);
    r.away = code(m.away);
    r.hs = score(m.home);
    r.as = score(m.away);
    r.kickoffMs = m.hasKickoff ? m.kickoffMs : now;
    r.ht = m.state == MatchState::Halftime;
    s.live.push_back(r);
  }
  for (const auto& m : v.next) {
    NextRow r;
    r.home = code(m.home);
    r.away = code(m.away);
    r.kickoffMs = m.hasKickoff ? m.kickoffMs : now;
    s.next.push_back(r);
  }
  return s;
}
}  // namespace

namespace SnapshotBuilder {

int parseMinute(const String& clock) {
  String t = clock;
  t.trim();
  int i = 0, n = t.length();
  if (i >= n || !isdigit((unsigned char)t[i])) return 0;
  long v = 0;
  while (i < n && isdigit((unsigned char)t[i])) v = v * 10 + (t[i++] - '0');
  return v >= 0 ? (int)v : 0;
}

Snapshot build(const StoreView& v, int64_t now) {
  // Fresh goal: newest event whose match is still live and < goal duration old.
  const GoalEvent* freshGoal = nullptr;
  for (const auto& e : v.goals) {
    if (now - e.atMs >= GOAL_DURATION_MS) continue;
    bool liveMatch = false;
    for (const auto& m : v.live)
      if (m.id == e.matchId) { liveMatch = true; break; }
    if (!liveMatch) continue;
    if (!freshGoal || e.atMs >= freshGoal->atMs) freshGoal = &e;
  }

  if (freshGoal) {
    const Match* match = nullptr;
    for (const auto& m : v.live)
      if (m.id == freshGoal->matchId) { match = &m; break; }
    if (match) {
      Snapshot s = liveSnapshot(*match, v, now);
      s.state = Board::Goal;
      s.goalStartedAt = freshGoal->atMs;
      s.team = freshGoal->team;
      s.code = code(freshGoal->team == 0 ? match->home : match->away);
      return s;
    }
  }

  if (v.live.size() == 1) return liveSnapshot(v.live[0], v, now);

  if (v.live.empty()) {
    // recently_finished is sorted most-recent-first and already windowed.
    if (!v.finals.empty()) {
      Snapshot s = liveSnapshot(v.finals[0].match, v, now);
      s.finalHold = true;
      return s;
    }
    return nowNextSnapshot(v, now);
  }

  // Several live, no favorite -> now_next.
  return nowNextSnapshot(v, now);
}

}  // namespace SnapshotBuilder
