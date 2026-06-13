#include "espn.h"
#include <ArduinoJson.h>
#include <algorithm>
#include <ctype.h>
#include <esp_heap_caps.h>

namespace {
// Route ArduinoJson allocations to PSRAM — the filtered scoreboard for the full
// 104-match tournament is comfortably larger than internal heap likes.
struct PsramAllocator : ArduinoJson::Allocator {
  void* allocate(size_t n) override { return heap_caps_malloc(n, MALLOC_CAP_SPIRAM); }
  void deallocate(void* p) override { heap_caps_free(p); }
  void* reallocate(void* p, size_t n) override {
    return heap_caps_realloc(p, n, MALLOC_CAP_SPIRAM);
  }
};
PsramAllocator psram;

// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
int64_t daysFromCivil(int y, unsigned m, unsigned d) {
  y -= m <= 2;
  int era = (y >= 0 ? y : y - 399) / 400;
  unsigned yoe = (unsigned)(y - era * 400);
  unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return (int64_t)era * 146097 + (int)doe - 719468;
}

// ESPN dates are UTC, "2026-06-11T19:00Z" (seconds optional).
bool parseKickoff(const char* date, int64_t& outMs) {
  if (!date) return false;
  int Y, Mo, D, H, Mi, S = 0;
  int n = sscanf(date, "%d-%d-%dT%d:%d:%d", &Y, &Mo, &D, &H, &Mi, &S);
  if (n < 5) return false;
  outMs = (daysFromCivil(Y, (unsigned)Mo, (unsigned)D) * 86400LL + H * 3600 + Mi * 60 + S) * 1000LL;
  return true;
}

bool parseLeadingInt(const char* s, int& out) {
  if (!s) return false;
  while (*s == ' ') s++;
  bool neg = false;
  if (*s == '-') { neg = true; s++; }
  if (!isdigit((unsigned char)*s)) return false;
  long v = 0;
  while (isdigit((unsigned char)*s)) v = v * 10 + (*s++ - '0');
  out = (int)(neg ? -v : v);
  return true;
}

String idToString(JsonVariantConst v) {
  if (v.is<const char*>()) return String(v.as<const char*>());
  if (v.is<long long>()) return String((long long)v.as<long long>());
  return String("");
}

bool containsCI(const char* hay, const char* needle) {
  if (!hay) return false;
  String h(hay);
  h.toLowerCase();
  return h.indexOf(needle) >= 0;
}

String humanizeSlug(const char* slug) {
  if (!slug || !*slug) return String("");
  String out;
  bool wordStart = true;
  for (const char* p = slug; *p; p++) {
    char c = *p;
    if (c == '-') {
      out += ' ';
      wordStart = true;
    } else {
      char lc = (char)tolower((unsigned char)c);
      out += wordStart ? (char)toupper((unsigned char)lc) : lc;
      wordStart = false;
    }
  }
  return out;
}

Side parseSide(JsonArrayConst competitors, const char* homeAway, MatchState state) {
  Side s;
  s.hasScore = false;
  s.score = 0;
  JsonObjectConst comp;
  for (JsonObjectConst c : competitors) {
    const char* ha = c["homeAway"];
    if (ha && strcmp(ha, homeAway) == 0) { comp = c; break; }
  }
  JsonObjectConst team = comp["team"];
  const char* name = team["displayName"] | (const char*)team["name"];
  s.name = name ? String(name) : String("");
  const char* ab = team["abbreviation"];
  s.abbrev = ab ? String(ab) : String("");
  if (state != MatchState::Scheduled) {
    JsonVariantConst sv = comp["score"];
    int v;
    if (sv.is<int>()) {
      s.hasScore = true;
      s.score = sv.as<int>();
    } else if (sv.is<const char*>() && parseLeadingInt(sv.as<const char*>(), v)) {
      s.hasScore = true;
      s.score = v;
    }
  }
  return s;
}

String roundLabel(JsonObjectConst event, JsonObjectConst competition) {
  JsonArrayConst notes = competition["notes"];
  if (!notes.isNull()) {
    for (JsonObjectConst n : notes) {
      const char* h = n["headline"];
      if (h && *h) return String(h);
    }
  }
  return humanizeSlug(event["season"]["slug"]);
}
}  // namespace

namespace Espn {

MatchState stateFromStatus(const char* state, const char* detail) {
  if (!state) return MatchState::Scheduled;
  if (strcmp(state, "pre") == 0) return MatchState::Scheduled;
  if (strcmp(state, "post") == 0) return MatchState::Finished;
  if (strcmp(state, "in") == 0)
    return containsCI(detail, "halftime") ? MatchState::Halftime : MatchState::Live;
  return MatchState::Scheduled;
}

bool parseScoreboard(char* buf, size_t len, std::vector<Match>& out) {
  JsonDocument filter(&psram);
  JsonObject ev = filter["events"].add<JsonObject>();
  ev["id"] = true;
  ev["date"] = true;
  ev["season"]["slug"] = true;
  JsonObject st = ev["status"].to<JsonObject>();
  st["displayClock"] = true;
  st["type"]["state"] = true;
  st["type"]["detail"] = true;
  JsonObject comp = ev["competitions"].add<JsonObject>();
  comp["notes"].add<JsonObject>()["headline"] = true;
  JsonObject cr = comp["competitors"].add<JsonObject>();
  cr["homeAway"] = true;
  cr["score"] = true;
  JsonObject tm = cr["team"].to<JsonObject>();
  tm["displayName"] = true;
  tm["name"] = true;
  tm["abbreviation"] = true;

  JsonDocument doc(&psram);
  DeserializationError err =
      deserializeJson(doc, buf, len, DeserializationOption::Filter(filter));
  if (err) return false;

  out.clear();
  for (JsonObjectConst event : doc["events"].as<JsonArrayConst>()) {
    JsonObjectConst competition = event["competitions"][0];
    JsonObjectConst status = event["status"];
    MatchState state = stateFromStatus(status["type"]["state"], status["type"]["detail"]);
    JsonArrayConst competitors = competition["competitors"];

    Match m;
    m.id = idToString(event["id"]);
    m.hasKickoff = parseKickoff(event["date"], m.kickoffMs);
    if (!m.hasKickoff) m.kickoffMs = 0;
    m.round = roundLabel(event, competition);
    m.state = state;
    m.home = parseSide(competitors, "home", state);
    m.away = parseSide(competitors, "away", state);
    // ESPN reports a meaningless "0'" clock pre-match; keep it only otherwise.
    const char* dc = status["displayClock"];
    m.clock = (state == MatchState::Scheduled || !dc) ? String("") : String(dc);
    out.push_back(m);
  }

  std::sort(out.begin(), out.end(), [](const Match& a, const Match& b) {
    int64_t ka = a.hasKickoff ? a.kickoffMs : INT64_MAX;
    int64_t kb = b.hasKickoff ? b.kickoffMs : INT64_MAX;
    return ka < kb;
  });
  return true;
}

bool parseStandings(char* buf, size_t len, std::vector<Group>& out) {
  JsonDocument filter(&psram);
  JsonObject ch = filter["children"].add<JsonObject>();
  ch["name"] = true;
  JsonObject entry = ch["standings"]["entries"].add<JsonObject>();
  JsonObject tm = entry["team"].to<JsonObject>();
  tm["displayName"] = true;
  tm["abbreviation"] = true;

  JsonDocument doc(&psram);
  DeserializationError err =
      deserializeJson(doc, buf, len, DeserializationOption::Filter(filter));
  if (err) return false;

  out.clear();
  for (JsonObjectConst child : doc["children"].as<JsonArrayConst>()) {
    Group g;
    const char* name = child["name"];
    g.name = name ? String(name) : String("");
    JsonArrayConst entries = child["standings"]["entries"];
    for (JsonObjectConst e : entries) {
      GroupEntry ge;
      const char* t = e["team"]["displayName"];
      const char* a = e["team"]["abbreviation"];
      ge.team = t ? String(t) : String("");
      ge.abbrev = a ? String(a) : String("");
      g.entries.push_back(ge);
    }
    out.push_back(g);
  }
  return true;
}

}  // namespace Espn
