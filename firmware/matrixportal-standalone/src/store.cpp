#include "store.h"
#include <algorithm>
#include "timeutil.h"

namespace {
const int64_t GOAL_RETENTION_MS = 60000;
const int64_t FINISHED_RETENTION_MS = 60 * 60 * 1000;
const int64_t KICKOFF_GRACE_MS = 15 * 60 * 1000;
const int NEXT_MAX = 4;

const Side& sideOf(const Match& m, int team) { return team == 0 ? m.home : m.away; }

bool kickoffLess(const Match& a, const Match& b) {
  int64_t ka = a.hasKickoff ? a.kickoffMs : INT64_MAX;
  int64_t kb = b.hasKickoff ? b.kickoffMs : INT64_MAX;
  return ka < kb;
}
}  // namespace

void Store::begin() { mutex_ = xSemaphoreCreateMutex(); }

Match* Store::findById(const String& id) {
  for (auto& m : matches_)
    if (m.id == id) return &m;
  return nullptr;
}

void Store::put(const std::vector<Match>& incoming) {
  xSemaphoreTake(mutex_, portMAX_DELAY);
  int64_t now = nowEpochMs();

  // Detect against the OLD state, before merging (mirrors Store.handle_call).
  for (const Match& nm : incoming) {
    Match* old = findById(nm.id);
    if (!old) continue;
    if (isLiveState(nm.state)) {
      for (int team = 0; team < 2; team++) {
        const Side& os = sideOf(*old, team);
        const Side& ns = sideOf(nm, team);
        if (os.hasScore && ns.hasScore && ns.score > os.score)
          goals_.push_back({nm.id, team, nm, now});
      }
    }
    if (nm.state == MatchState::Finished && isLiveState(old->state))
      finished_.push_back({nm.id, now});
  }

  // Merge by id.
  for (const Match& nm : incoming) {
    Match* old = findById(nm.id);
    if (old)
      *old = nm;
    else
      matches_.push_back(nm);
  }

  // Prune.
  goals_.erase(std::remove_if(goals_.begin(), goals_.end(),
                              [&](const GoalEvent& e) { return now - e.atMs > GOAL_RETENTION_MS; }),
               goals_.end());
  finished_.erase(
      std::remove_if(finished_.begin(), finished_.end(),
                     [&](const FinishedRec& f) { return now - f.atMs > FINISHED_RETENTION_MS; }),
      finished_.end());

  xSemaphoreGive(mutex_);
}

void Store::putStandings(const std::vector<Group>& groups) {
  xSemaphoreTake(mutex_, portMAX_DELAY);
  standings_ = groups;
  xSemaphoreGive(mutex_);
}

std::vector<Match> Store::schedule() {
  xSemaphoreTake(mutex_, portMAX_DELAY);
  std::vector<Match> out = matches_;
  xSemaphoreGive(mutex_);
  std::sort(out.begin(), out.end(), kickoffLess);
  return out;
}

std::vector<GoalEvent> Store::goalEvents(int64_t now) {
  xSemaphoreTake(mutex_, portMAX_DELAY);
  std::vector<GoalEvent> out;
  for (const auto& e : goals_)
    if (now - e.atMs <= GOAL_RETENTION_MS) out.push_back(e);
  xSemaphoreGive(mutex_);
  return out;
}

StoreView Store::capture(int64_t now, int64_t finalHoldMs) {
  xSemaphoreTake(mutex_, portMAX_DELAY);

  std::vector<Match> sorted = matches_;
  std::sort(sorted.begin(), sorted.end(), kickoffLess);

  StoreView v;

  // live_matches
  for (const auto& m : sorted)
    if (isLiveState(m.state)) v.live.push_back(m);

  // next_matches(4): scheduled, has kickoff, within the post-kickoff grace.
  int64_t cutoff = now - KICKOFF_GRACE_MS;
  for (const auto& m : sorted) {
    if ((int)v.next.size() >= NEXT_MAX) break;
    if (m.state == MatchState::Scheduled && m.hasKickoff && m.kickoffMs >= cutoff)
      v.next.push_back(m);
  }

  // recently_finished(finalHoldMs): most recent first, deduped by match id.
  std::vector<FinishedRec> cand;
  for (const auto& f : finished_)
    if (now - f.atMs <= finalHoldMs) cand.push_back(f);
  std::sort(cand.begin(), cand.end(),
            [](const FinishedRec& a, const FinishedRec& b) { return a.atMs > b.atMs; });
  std::vector<String> seen;
  for (const auto& f : cand) {
    bool dup = false;
    for (const auto& s : seen)
      if (s == f.matchId) { dup = true; break; }
    if (dup) continue;
    seen.push_back(f.matchId);
    Match* m = findById(f.matchId);
    if (m) v.finals.push_back({*m, f.atMs});
  }

  // goal_events (fresh)
  for (const auto& e : goals_)
    if (now - e.atMs <= GOAL_RETENTION_MS) v.goals.push_back(e);

  v.standings = standings_;

  xSemaphoreGive(mutex_);
  return v;
}
