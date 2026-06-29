#include "snapshot.h"
#include <ctype.h>

namespace {
const int64_t GOAL_DURATION_MS = 16500;
const int64_t FINAL_HOLD_MS = 20 * 60 * 1000;
const int64_t FINAL_ALT_MS = 15000;  // final-hold ⇄ now/next swap period
// Two matches count as the same simultaneous slot if their kickoffs fall inside
// this window — group-stage finales kick two games off together. Used to decide
// which just-finished match keeps its slot (as FINAL) beside a live partner.
const int64_t CONCURRENT_WINDOW_MS = 30 * 60 * 1000;
const int MAX_LIVE_ROWS = 2;

bool concurrent(int64_t a, int64_t b) {
  int64_t d = a > b ? a - b : b - a;
  return d <= CONCURRENT_WINDOW_MS;
}

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
  s.paused = m.state == MatchState::Halftime;
  s.minute = m.minute;
  s.stoppage = m.stoppage;
  s.period = m.period;
  s.hs = score(m.home);
  s.as = score(m.away);
  s.stage = stageLabel(m, v.standings);
  s.home = code(m.home);
  s.away = code(m.away);
  s.kickoffMs = m.hasKickoff ? m.kickoffMs : now;
  return s;
}

LiveRow liveRow(const Match& m, bool isFinal, int64_t now) {
  LiveRow r;
  r.home = code(m.home);
  r.away = code(m.away);
  r.hs = score(m.home);
  r.as = score(m.away);
  r.kickoffMs = m.hasKickoff ? m.kickoffMs : now;
  r.paused = m.state == MatchState::Halftime;
  r.final = isFinal;
  r.minute = m.minute;
  r.stoppage = m.stoppage;
  r.period = m.period;
  return r;
}

Snapshot nowNextSnapshot(const std::vector<LiveRow>& liveRows, const StoreView& v, int64_t now) {
  Snapshot s{};
  s.state = Board::NowNext;
  s.now = now;
  s.flags = true;
  for (const auto& r : liveRows) {
    if ((int)s.live.size() >= MAX_LIVE_ROWS) break;
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

  // Assemble the "now" rows. Live matches first (this preserves the existing
  // two-live-games dual board), then fill any remaining slot with a
  // recently-finished match that was concurrent with the action — so each game
  // in a simultaneous pair flips to FINAL on its own clock while its partner
  // keeps playing, and both stay on screen together.
  std::vector<LiveRow> rows;
  for (const auto& m : v.live) {
    if ((int)rows.size() >= MAX_LIVE_ROWS) break;
    rows.push_back(liveRow(m, false, now));
  }
  if ((int)rows.size() < MAX_LIVE_ROWS) {
    // Concurrency anchor: the live matches if any, else the most-recent final
    // (v.finals is sorted most-recent-first and already deduped/windowed).
    bool haveAnchor = false;
    int64_t anchor = 0;
    if (!v.live.empty()) { anchor = v.live[0].kickoffMs; haveAnchor = true; }
    else if (!v.finals.empty()) { anchor = v.finals[0].match.kickoffMs; haveAnchor = true; }
    if (haveAnchor) {
      for (const auto& f : v.finals) {
        if ((int)rows.size() >= MAX_LIVE_ROWS) break;
        if (concurrent(f.match.kickoffMs, anchor)) rows.push_back(liveRow(f.match, true, now));
      }
    }
  }

  int liveCount = 0, finalCount = 0;
  for (const auto& r : rows) (r.final ? finalCount : liveCount)++;

  // Two-or-more concurrent games (any mix of live and final) -> dual now/next.
  if ((int)rows.size() >= 2) return nowNextSnapshot(rows, v, now);

  // Exactly one live game, no finished partner -> single live board.
  if (liveCount == 1) return liveSnapshot(v.live[0], v, now);

  // No live games, one recent final -> the single FINAL hold board, alternating
  // with now/next every 15s (only swap when there's an upcoming match to show).
  // rows[0] (when present) is v.finals[0], the match anchoring the window.
  if (finalCount == 1) {
    bool showNext = !v.next.empty() && (now / FINAL_ALT_MS) % 2 == 1;
    if (!showNext) {
      Snapshot s = liveSnapshot(v.finals[0].match, v, now);
      s.finalHold = true;
      return s;
    }
  }

  // Nothing live or recently final (or alternating to it) -> upcoming.
  return nowNextSnapshot({}, v, now);
}

}  // namespace SnapshotBuilder
