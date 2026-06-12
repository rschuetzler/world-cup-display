// TravisTracker — Matrix Portal S3 firmware (Arduino / PlatformIO).
//
// Pure fetch-and-blit, ported from the CircuitPython version
// (../matrixportal/code.py) onto ESP32-HUB75-MatrixPanel-DMA: the S3's LCD
// peripheral replays the panel scan from RAM via DMA with zero CPU per
// refresh, so Wi-Fi/CPU activity can never glitch the display. (CircuitPython's
// Protomatter scan is CPU-coupled and flashed corrupted rows on every radio
// event — the reason this port exists.)
//
// All layout/design lives on the server (TravisTracker.Matrix); this file
// should rarely change. See docs/matrix-display-protocol.md for the wire
// format: 128*64*2 bytes, row-major, RGB565 little-endian — which matches the
// ESP32's endianness, so the body casts straight to uint16_t[].
//
// Two tasks, one per core: the Arduino loop (core 1) animates at ~60 fps and
// never blocks; a fetch task (core 0) owns Wi-Fi/HTTP and polls the server.
// Frames hand off through a pair of buffers — the fetch task fills `staging`,
// raises `framePending`, and the render loop swaps front/staging between
// ticks. Without this split, every poll froze scrolling for the full TLS
// handshake + round trip (~1s, worse on Wi-Fi hiccups).

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <Adafruit_NeoPixel.h>
#include <ESP32-HUB75-MatrixPanel-I2S-DMA.h>

#include "secrets.h" // WIFI_SSID / WIFI_PASSWORD / MATRIX_URL
#include "geist_clock_font.h"
#include <time.h>
#include <sys/time.h>
#include <atomic>

// ── config ──────────────────────────────────────────────────────────────
constexpr int W = 128, H = 64;
constexpr int FAIL_LIMIT = 3;      // consecutive failures before the "stale" signal
constexpr uint32_t HTTP_TIMEOUT_MS = 20000;

// MatrixPortal S3 HUB75 wiring (GPIOs per the Adafruit schematic), with R/B
// swapped vs the Adafruit MTX_* names: verified empirically with the boot
// self-test — Adafruit's "R1" (42) drives this panel's blue and vice versa.
constexpr HUB75_I2S_CFG::i2s_pins PINS = {
    40, 41, 42, // R1 G1 B1
    37, 39, 38, // R2 G2 B2
    45, 36, 48, 35, 21, // A B C D E (E needed for 1/32-scan 64-tall)
    47, 14, 2, // LAT OE CLK
};
// PIN_NEOPIXEL (4), PIN_BUTTON_UP (6), PIN_BUTTON_DOWN (7) come from the
// adafruit_matrixportal_esp32s3 board variant; buttons are active low.

// ── state ───────────────────────────────────────────────────────────────
MatrixPanel_I2S_DMA *panel = nullptr;
Adafruit_NeoPixel pixel(1, PIN_NEOPIXEL, NEO_GRB + NEO_KHZ800);
Preferences prefs;

constexpr size_t BASE_BYTES = W * H * 2;       // 16384
constexpr size_t TRAILER_MAX = 32768;          // generous: ≤4 strips + descriptors
constexpr int MAX_REGIONS = 4;

// Double-buffered wire frames (base + trailer). The render loop (core 1)
// reads `front`; the fetch task (core 0) writes `staging`. Hand-off is
// SPSC: fetch fills staging only while !framePending, then raises the flag;
// render swaps the pointers between ticks and clears it. parseTrailer's
// region tables point into `front`, so the swap and re-parse happen together
// on the render thread.
alignas(4) static uint8_t frames[2][BASE_BYTES + TRAILER_MAX];
static uint8_t *front = frames[0];
static uint8_t *staging = frames[1];
static size_t frontLen = 0;
static size_t stagingLen = 0;
static std::atomic<bool> framePending{false};
static std::atomic<bool> forceRefetch{false};  // buttons → poll now

struct ScrollRegion {
  uint8_t x, y, w, h;
  uint16_t stripW;
  uint8_t speed, gap, mode;
  const uint8_t *strip;  // points into `front`
};
struct ClockRegion {
  uint8_t cx, y, scale;
  uint16_t color;
  int16_t tzOff;   // minutes
  uint8_t flags;   // bit0 h12
  uint64_t anchor; // epoch ms
};

static ScrollRegion scrolls[MAX_REGIONS];
static int scrollCount = 0;
static ClockRegion clk;
static bool haveClock = false;
static uint32_t anchorAtMillis = 0;  // millis() when the current anchor was received (uint32 so the millis() wrap subtracts correctly)

String etag = "";
uint32_t pollSecs = 15;
int fails = 0;
uint8_t overridePct = 0; // brightness override in percent; 0 = server auto

// ── status LED (blue = connecting · off = healthy · red = stale) ────────
void status(uint8_t r, uint8_t g, uint8_t b) {
  static uint32_t last = 0xFFFFFFFF;
  uint32_t c = pixel.Color(r, g, b);
  if (c == last) return; // writes cost time; skip no-ops
  pixel.fill(c);
  pixel.show();
  last = c;
}

// ── wifi ────────────────────────────────────────────────────────────────
void connectWifi() {
  status(0, 0, 40);
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false); // wall-powered; snappier polls
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  while (WiFi.status() != WL_CONNECTED) delay(250);
  status(0, 0, 0);
}

// ── brightness override (persisted in NVS) ──────────────────────────────
void loadOverride() { overridePct = prefs.getUChar("b", 0); }
void saveOverride() { prefs.putUChar("b", overridePct); }

String frameUrl() {
  String url = MATRIX_URL;
  if (overridePct) {
    char q[16];
    snprintf(q, sizeof(q), "?b=%.2f", overridePct / 100.0);
    url += q;
  }
  return url;
}

// Returns true if the override changed (active-low buttons).
bool pollButtons() {
  bool changed = false;
  if (digitalRead(PIN_BUTTON_UP) == LOW) {
    overridePct = min(100, (overridePct ? overridePct : 100) + 10);
    changed = true;
  }
  if (digitalRead(PIN_BUTTON_DOWN) == LOW) {
    overridePct = max(10, (overridePct ? overridePct : 100) - 10);
    changed = true;
  }
  if (changed) {
    saveOverride();
    delay(250); // debounce
  }
  return changed;
}

// ── Geist clock renderer ────────────────────────────────────────────────
static const GeistClockGlyph *clockGlyph(char c) {
  for (int i = 0; i < GEIST_CLOCK_GLYPH_COUNT; i++)
    if (GEIST_CLOCK_GLYPHS[i].cp == (uint8_t)c) return &GEIST_CLOCK_GLYPHS[i];
  return nullptr;
}

// Inked width of `str` in the clock numerals (mirrors Geist.string_w).
static int clockStrWidth(const char *str) {
  int pen = 0, minX = 100000, maxX = -100000;
  for (const char *c = str; *c; c++) {
    const GeistClockGlyph *g = clockGlyph(*c);
    if (!g) { pen += 10; continue; }
    int gx0 = pen + g->xoff;
    if (gx0 < minX) minX = gx0;
    if (gx0 + g->width > maxX) maxX = gx0 + g->width;
    pen += g->advance;
  }
  return (maxX <= minX) ? 1 : (maxX - minX);
}

// Blit `str` centered on cx, top y0, into the back buffer (mirrors Geist.blit).
static void drawClock(const char *str, int cx, int y0, uint16_t color) {
  int x0 = cx - clockStrWidth(str) / 2;
  // first compute minX across placed glyphs
  int pen = 0, minX = 100000;
  for (const char *c = str; *c; c++) {
    const GeistClockGlyph *g = clockGlyph(*c);
    if (!g) { pen += 10; continue; }
    if (pen + g->xoff < minX) minX = pen + g->xoff;
    pen += g->advance;
  }
  pen = 0;
  for (const char *c = str; *c; c++) {
    const GeistClockGlyph *g = clockGlyph(*c);
    if (!g) { pen += 10; continue; }
    int gx0 = pen + g->xoff;
    int top = GEIST_CLOCK_CAP - g->yoff;
    for (int row = 0; row < g->height; row++) {
      const uint8_t *rp = g->bitmap + row * g->rowbytes;
      for (int col = 0; col < g->width; col++) {
        if (rp[col >> 3] & (0x80 >> (col & 7))) {
          panel->drawPixel(x0 + (gx0 - minX) + col, y0 + top + row, color);
        }
      }
    }
    pen += g->advance;
  }
}

// Best-effort current UTC epoch ms: NTP if synced, else the server anchor + drift.
static uint64_t nowUtcMs() {
  time_t t = time(nullptr);
  if (t > 1700000000) {  // NTP locked (after ~2023-11)
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    return (uint64_t)tv.tv_sec * 1000ULL + tv.tv_usec / 1000ULL;
  }
  if (haveClock) return clk.anchor + (uint64_t)(millis() - anchorAtMillis);
  return 0;
}

// ── frame compositor ────────────────────────────────────────────────────
// Paint base frame + panned scroll sprites + clock into the back buffer, flip.
static void renderTick() {
  panel->drawRGBBitmap(0, 0, (uint16_t *)front, W, H);

  uint32_t t = millis();
  for (int i = 0; i < scrollCount; i++) {
    ScrollRegion &s = scrolls[i];
    int span = s.stripW + s.gap;
    if (span <= 0) continue;
    uint32_t off = (uint32_t)(((uint64_t)t * s.speed) / 1000) % span;
    for (int dx = 0; dx < s.w; dx++) {
      int col = (off + dx) % span;
      if (col >= s.stripW) continue;  // gap
      const uint8_t *colBase = s.strip + (size_t)col * 2;  // row 0 of this column
      for (int row = 0; row < s.h; row++) {
        const uint8_t *px = colBase + (size_t)row * s.stripW * 2;
        uint16_t v = px[0] | (px[1] << 8);
        if (v) panel->drawPixel(s.x + dx, s.y + row, v);
      }
    }
  }

  if (haveClock) {
    uint64_t utc = nowUtcMs();
    if (utc > 0) {  // have a time source (NTP or anchor)
      int64_t local = (int64_t)utc + (int64_t)clk.tzOff * 60000LL;
      if (local < 0) local = 0;
      uint32_t totalMin = (uint32_t)(((uint64_t)local / 60000ULL) % 1440ULL);
      int hh = totalMin / 60, mm = totalMin % 60;
      if (clk.flags & 0x01) { hh = hh % 12; if (hh == 0) hh = 12; }
      char buf[6];
      snprintf(buf, sizeof(buf), "%02d:%02d", hh, mm);
      drawClock(buf, clk.cx, clk.y, clk.color);
    }
  }

  panel->flipDMABuffer();
}

// ── trailer parser ──────────────────────────────────────────────────────
static uint16_t rd16(const uint8_t *p) { return p[0] | (p[1] << 8); }

// Parse the trailer (if any) at front+BASE_BYTES into the region tables.
// Bounds-checked: a truncated/short trailer bails to an empty state rather
// than storing dangling pointers. Render-thread only (tables alias `front`).
static void parseTrailer() {
  scrollCount = 0;
  haveClock = false;
  if (frontLen <= BASE_BYTES) return;

  const uint8_t *p = front + BASE_BYTES;
  const uint8_t *end = front + frontLen;
  if (end - p < 6) return;                 // need magic + version + count
  if (memcmp(p, "SCRL", 4) != 0) return;
  p += 4;
  uint8_t ver = *p++;
  if (ver != 1) return;
  uint8_t n = *p++;

  // Pass 1: descriptors.
  int ns = 0;
  for (uint8_t i = 0; i < n; i++) {
    if (p >= end) { scrollCount = 0; haveClock = false; return; }  // truncated
    uint8_t kind = *p++;
    if (kind == 0) {
      if (end - p < 9) { scrollCount = 0; haveClock = false; return; }
      if (ns < MAX_REGIONS) {
        ScrollRegion &s = scrolls[ns];
        s.x = p[0]; s.y = p[1]; s.w = p[2]; s.h = p[3];
        s.stripW = rd16(p + 4);
        s.speed = p[6]; s.gap = p[7]; s.mode = p[8];
        ns++;
      }
      p += 9;
    } else if (kind == 1) {
      if (end - p < 16) { scrollCount = 0; haveClock = false; return; }
      clk.cx = p[0]; clk.y = p[1]; clk.scale = p[2];
      clk.color = rd16(p + 3);
      clk.tzOff = (int16_t)rd16(p + 5);
      clk.flags = p[7];
      clk.anchor = 0;
      for (int b = 0; b < 8; b++) clk.anchor |= (uint64_t)p[8 + b] << (8 * b);
      haveClock = true;
      anchorAtMillis = millis();
      p += 16;
    } else {
      return; // unknown kind → ignore the rest of the trailer
    }
  }
  scrollCount = ns;

  // Pass 2: strips follow all descriptors, in scroll-descriptor order.
  for (int i = 0; i < scrollCount; i++) {
    size_t stripBytes = (size_t)scrolls[i].stripW * scrolls[i].h * 2;
    if (p + stripBytes > end) { scrollCount = 0; return; }  // truncated strip
    scrolls[i].strip = p;
    p += stripBytes;
  }
}

// ── fetch & blit ────────────────────────────────────────────────────────
bool fetchFrame() {
  String url = frameUrl();
  WiFiClientSecure tls;
  WiFiClient plain;
  HTTPClient http;
  http.setTimeout(HTTP_TIMEOUT_MS);
  http.setConnectTimeout(HTTP_TIMEOUT_MS);

  bool ok;
  if (url.startsWith("https://")) {
    // The frame is public-ish (secret is in the URL, not the transport peer);
    // skip CA validation to keep this robust across cert rotations.
    tls.setInsecure();
    ok = http.begin(tls, url);
  } else {
    ok = http.begin(plain, url);
  }
  if (!ok) return false;

  const char *keys[] = {"ETag", "X-Poll-Seconds"};
  http.collectHeaders(keys, 2);
  if (etag.length()) http.addHeader("If-None-Match", etag);

  int code = http.GET();

  if (code == 200) {
    // The render loop consumes a pending frame within one ~16ms tick, so this
    // wait is theoretical — but never scribble on a buffer mid-handoff.
    while (framePending.load()) delay(2);

    WiFiClient *s = http.getStreamPtr();
    int want = http.getSize();  // Content-Length, or -1 if unknown
    size_t cap = BASE_BYTES + TRAILER_MAX;
    size_t got = 0;
    uint32_t lastData = millis();
    while (got < cap && millis() - lastData < HTTP_TIMEOUT_MS) {
      if (want > 0 && got >= (size_t)want) break;
      int n = s->read(staging + got, cap - got);
      if (n > 0) {
        got += n;
        lastData = millis();
      } else if (!s->connected() && !s->available()) {
        break;
      } else {
        delay(1);
      }
    }
    if (got >= BASE_BYTES) {
      stagingLen = got;
      framePending.store(true);  // render loop swaps it in between ticks
    }
    if (http.hasHeader("ETag")) etag = http.header("ETag");
    int ps = http.header("X-Poll-Seconds").toInt();
    if (ps > 0) pollSecs = max(5, ps);
  }
  // 304 → unchanged; keep the frame.

  http.end();
  return code == 200 || code == 304;
}

// ── fetch task (core 0) ─────────────────────────────────────────────────
// Owns Wi-Fi, HTTP, etag/pollSecs, and the status LED. Blocking here is fine:
// the render loop on core 1 keeps animating the last frame throughout.
static void fetchTask(void *) {
  connectWifi();
  // UTC from NTP; we apply the per-clock tz offset ourselves. Re-syncs hourly.
  configTime(0, 0, "pool.ntp.org", "time.nist.gov");

  for (;;) {
    if (WiFi.status() != WL_CONNECTED) connectWifi();

    if (fetchFrame()) {
      fails = 0;
      status(0, 0, 0);
    } else {
      fails++;
      Serial.println("poll error");
      if (fails >= FAIL_LIMIT) status(40, 0, 0);  // red = stale; last frame stays
    }

    uint32_t deadline = millis() + pollSecs * 1000;
    while ((int32_t)(deadline - millis()) > 0) {
      if (forceRefetch.exchange(false)) {
        etag = "";  // brightness change → refetch now, uncached
        break;
      }
      delay(50);
    }
  }
}

// ── setup / loop ────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);

  pinMode(PIN_BUTTON_UP, INPUT_PULLUP);
  pinMode(PIN_BUTTON_DOWN, INPUT_PULLUP);
  pixel.begin();
  pixel.setBrightness(40);

  prefs.begin("matrix");
  loadOverride();

  HUB75_I2S_CFG cfg(W, H, 1 /* chain */, PINS);
  cfg.double_buff = true;            // draw offscreen, flip atomically
  cfg.setPixelColorDepthBits(6);     // wire format is RGB565 → >6 bits is wasted RAM
  cfg.min_refresh_rate = 120;        // camera/eye-friendly floor
  cfg.clkphase = false;              // edge-column flicker/ghost pixels with the default
  panel = new MatrixPanel_I2S_DMA(cfg);
  if (!panel->begin()) {
    // Not enough DMA-capable RAM — shouldn't happen at 6-bit depth.
    while (true) {
      status(40, 20, 0);
      delay(500);
      status(0, 0, 0);
      delay(500);
    }
  }
  panel->setBrightness8(255); // brightness/gamma are baked into the frame server-side
  panel->clearScreen();

  // Networking lives on core 0 (the Arduino loop runs on core 1). 12 KB stack:
  // HTTPClient+TLS keeps most of its state on the heap, but not all of it.
  xTaskCreatePinnedToCore(fetchTask, "fetch", 12288, nullptr, 1, nullptr, 0);
}

// Render loop (core 1): never blocks on the network. The clock keeps ticking
// and sprites keep scrolling through polls, Wi-Fi drops, and slow servers.
void loop() {
  if (framePending.load()) {
    uint8_t *t = front;
    front = staging;
    staging = t;
    frontLen = stagingLen;
    parseTrailer();  // rebuild region tables; strips point into the new front
    framePending.store(false);
  }

  renderTick();
  if (pollButtons()) forceRefetch.store(true);
  delay(16);  // ~60 fps
}
