#include "net.h"
#include <Arduino.h>
#include <HTTPClient.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <esp_heap_caps.h>
#include <time.h>
#include <vector>
#include "espn.h"
#include "secrets.h"
#include "store.h"
#include "timeutil.h"

namespace {
// America/Denver, POSIX form (matches the server's DISPLAY_TZ).
const char* TZ = "MST7MDT,M3.2.0,M11.1.0";
const char* USER_AGENT = "world-cup-tracker/0.1";
const char* SCOREBOARD_BASE =
    "https://site.api.espn.com/apis/site/v2/sports/soccer/fifa.world/scoreboard";
const char* SUMMARY_BASE =
    "https://site.api.espn.com/apis/site/v2/sports/soccer/fifa.world/summary";
const char* STANDINGS_URL =
    "https://site.api.espn.com/apis/v2/sports/soccer/fifa.world/standings";
const char* TOURNAMENT_RANGE = "20260611-20260719";

const uint32_t HTTP_TIMEOUT_MS = 20000;
const int FAIL_LIMIT = 3;

const int64_t SCHEDULE_INTERVAL_MS = 60 * 60 * 1000;  // hourly
const uint32_t LIVE_INTERVAL = 20000;
const uint32_t SOON_INTERVAL = 60000;
const uint32_t IDLE_INTERVAL = 600000;
const int64_t SOON_WINDOW_MS = 15 * 60 * 1000;
const int64_t GOAL_BURST_MS = 20000;

Store* g_store = nullptr;
int g_fails = 0;

void connectWifi() {
  setStatusLed(0, 0, 40);
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);  // wall-powered; snappier polls
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  while (WiFi.status() != WL_CONNECTED) delay(250);
  setStatusLed(0, 0, 0);
}

// Read the whole HTTP body into a PSRAM buffer (NUL-terminated). Buffering the
// full response decouples the JSON parse from a slow/chunked TLS socket.
bool readBody(HTTPClient& http, char** outBuf, size_t* outLen) {
  int len = http.getSize();
  WiFiClient* s = http.getStreamPtr();
  size_t cap = (len > 0) ? (size_t)len + 1 : 32768;
  char* buf = (char*)heap_caps_malloc(cap, MALLOC_CAP_SPIRAM);
  if (!buf) return false;

  size_t got = 0;
  uint32_t lastData = millis();
  while (millis() - lastData < HTTP_TIMEOUT_MS) {
    if (len > 0 && got >= (size_t)len) break;
    size_t avail = s->available();
    if (avail) {
      if (got + avail + 1 > cap) {
        size_t ncap = cap * 2;
        while (got + avail + 1 > ncap) ncap *= 2;
        char* nb = (char*)heap_caps_realloc(buf, ncap, MALLOC_CAP_SPIRAM);
        if (!nb) {
          heap_caps_free(buf);
          return false;
        }
        buf = nb;
        cap = ncap;
      }
      int n = s->readBytes(buf + got, avail);
      if (n > 0) {
        got += n;
        lastData = millis();
      }
    } else if (!s->connected()) {
      break;
    } else {
      delay(2);
    }
  }
  buf[got] = 0;
  *outBuf = buf;
  *outLen = got;
  return got > 0;
}

bool httpGet(const String& url, char** buf, size_t* len) {
  WiFiClientSecure tls;
  // The ESPN API is public; skip CA validation to stay robust across cert
  // rotations (no secret rides the transport).
  tls.setInsecure();
  HTTPClient http;
  http.setTimeout(HTTP_TIMEOUT_MS);
  http.setConnectTimeout(HTTP_TIMEOUT_MS);
  http.setUserAgent(USER_AGENT);
  // ESPN's CDN serves these responses with Transfer-Encoding: chunked over
  // HTTP/1.1. We read the body straight off the socket (getStreamPtr) without
  // de-chunking, so the hex chunk-size markers ("c000\r\n"...) would land inside
  // the buffer and ArduinoJson would parse the leading marker as a bare number,
  // discarding the whole document. Forcing HTTP/1.0 makes the server send an
  // unchunked, connection-close-delimited body that readBody handles cleanly.
  http.useHTTP10(true);
  if (!http.begin(tls, url)) return false;
  int code = http.GET();
  if (code != 200) {
    http.end();
    return false;
  }
  bool ok = readBody(http, buf, len);
  http.end();
  return ok;
}

String yyyymmdd(time_t t) {
  struct tm g;
  gmtime_r(&t, &g);
  char b[9];
  snprintf(b, sizeof(b), "%04d%02d%02d", g.tm_year + 1900, g.tm_mon + 1, g.tm_mday);
  return String(b);
}

// today-1 .. today+1 (UTC), matching Poller.today_range.
String todayRange(int64_t now) {
  time_t s = (time_t)(now / 1000);
  return yyyymmdd(s - 86400) + "-" + yyyymmdd(s + 86400);
}

String scoreboardUrl(const String& range) {
  return String(SCOREBOARD_BASE) + "?dates=" + range + "&limit=200";
}

bool fetchScoreboard(const String& url) {
  char* buf = nullptr;
  size_t len = 0;
  if (!httpGet(url, &buf, &len)) return false;
  std::vector<Match> matches;
  bool ok = Espn::parseScoreboard(buf, len, matches);
  heap_caps_free(buf);
  if (ok) g_store->put(matches);
  return ok;
}

bool fetchStandings() {
  char* buf = nullptr;
  size_t len = 0;
  if (!httpGet(STANDINGS_URL, &buf, &len)) return false;
  std::vector<Group> groups;
  bool ok = Espn::parseStandings(buf, len, groups);
  heap_caps_free(buf);
  if (ok) g_store->putStandings(groups);
  return ok;
}

// Pull per-kick shootout results for one match from the (large) summary
// endpoint. Filtered down to just the `shootout` array on parse.
bool fetchShootout(const Match& m) {
  String url = String(SUMMARY_BASE) + "?event=" + m.id;
  char* buf = nullptr;
  size_t len = 0;
  if (!httpGet(url, &buf, &len)) return false;
  std::vector<int8_t> kh, ka;
  bool ok = Espn::parseShootout(buf, len, m.home.teamId, m.away.teamId, kh, ka);
  heap_caps_free(buf);
  if (ok) g_store->putShootout(m.id, kh, ka);
  return ok;
}

// Refresh shootout data for any match in a penalty shootout (period 5). Fetched
// every cycle while live; once more when it goes final to capture the decider.
void refreshShootouts(const std::vector<Match>& matches, std::vector<String>& finalsDone) {
  for (const auto& m : matches) {
    if (m.period < 5) continue;
    bool live = isLiveState(m.state);
    bool done = false;
    for (const auto& id : finalsDone)
      if (id == m.id) { done = true; break; }
    if (live) {
      fetchShootout(m);
    } else if (m.state == MatchState::Finished && !done) {
      fetchShootout(m);
      finalsDone.push_back(m.id);
    }
  }
}

void refreshSchedule() {
  fetchScoreboard(scoreboardUrl(TOURNAMENT_RANGE));
  fetchStandings();
}

// Port of Poller.choose_interval.
uint32_t chooseInterval(const std::vector<Match>& matches, const std::vector<GoalEvent>& goals,
                        int64_t now) {
  for (const auto& m : matches)
    if (isLiveState(m.state)) return LIVE_INTERVAL;
  for (const auto& g : goals)
    if (now - g.atMs <= GOAL_BURST_MS) return LIVE_INTERVAL;
  for (const auto& m : matches) {
    if (m.state == MatchState::Scheduled && m.hasKickoff) {
      int64_t d = m.kickoffMs - now;
      if (d < 0) d = -d;
      if (d <= SOON_WINDOW_MS) return SOON_INTERVAL;
    }
  }
  return IDLE_INTERVAL;
}

void task(void*) {
  connectWifi();
  configTzTime(TZ, "pool.ntp.org", "time.nist.gov");
  uint32_t t0 = millis();
  while (!timeSynced() && millis() - t0 < 15000) delay(200);

  refreshSchedule();
  int64_t lastSchedule = nowEpochMs();
  std::vector<String> penFinalsDone;  // shootout finals whose decider we've fetched

  for (;;) {
    if (WiFi.status() != WL_CONNECTED) connectWifi();

    int64_t now = nowEpochMs();
    if (now - lastSchedule >= SCHEDULE_INTERVAL_MS) {
      refreshSchedule();
      lastSchedule = now;
    }

    if (fetchScoreboard(scoreboardUrl(todayRange(now)))) {
      g_fails = 0;
      setStatusLed(0, 0, 0);
    } else {
      g_fails++;
      Serial.println("poll error");
      if (g_fails >= FAIL_LIMIT) setStatusLed(40, 0, 0);  // red = stale
    }

    std::vector<Match> matches = g_store->schedule();
    refreshShootouts(matches, penFinalsDone);
    std::vector<GoalEvent> goals = g_store->goalEvents(nowEpochMs());
    uint32_t interval = chooseInterval(matches, goals, nowEpochMs());

    uint32_t deadline = millis() + interval;
    while ((int32_t)(deadline - millis()) > 0) delay(100);
  }
}
}  // namespace

namespace Net {
void start(Store& store) {
  g_store = &store;
  // TLS + ArduinoJson keep most state on the heap, but give a generous stack.
  xTaskCreatePinnedToCore(task, "net", 16384, nullptr, 1, nullptr, 0);
}
}  // namespace Net
