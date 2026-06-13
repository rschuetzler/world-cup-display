// World Cup Tracker — Matrix Portal S3 STANDALONE firmware.
//
// Does it all on-device: a net task (core 0) polls ESPN, parses the JSON, and
// runs the goal/finished state machine into the Store; the render loop (core 1)
// builds a snapshot every frame and paints the three World Cup boards natively
// at ~60fps. No server, no LXC. Because every renderer is a pure function of
// snap.now, the goal celebration / LIVE blink / match clock animate smoothly
// off the device's NTP-synced clock — no frame polling.
//
// Panel handling (HUB75 + DMA, double-buffered) mirrors ../matrixportal-arduino:
// the S3's LCD peripheral replays the scan from RAM via DMA, so Wi-Fi/CPU
// activity on core 0 can never glitch the display.

#include <Arduino.h>
#include <Adafruit_NeoPixel.h>
#include <ESP32-HUB75-MatrixPanel-I2S-DMA.h>
#include <Preferences.h>

#include "brightness.h"
#include "fb.h"
#include "net.h"
#include "render.h"
#include "snapshot.h"
#include "store.h"
#include "timeutil.h"

// ── config ──────────────────────────────────────────────────────────────
constexpr int W = 128, H = 64;
constexpr int64_t FINAL_HOLD_MS = 20 * 60 * 1000;  // post-game FINAL hold window

// MatrixPortal S3 HUB75 wiring — verified pin map from the server-driven
// firmware (R/B swapped vs the Adafruit MTX_* names per the boot self-test).
constexpr HUB75_I2S_CFG::i2s_pins PINS = {
    40, 41, 42,          // R1 G1 B1
    37, 39, 38,          // R2 G2 B2
    45, 36, 48, 35, 21,  // A B C D E
    47, 14, 2,           // LAT OE CLK
};

// ── state ───────────────────────────────────────────────────────────────
MatrixPanel_I2S_DMA* panel = nullptr;
Adafruit_NeoPixel pixel(1, PIN_NEOPIXEL, NEO_GRB + NEO_KHZ800);
Preferences prefs;

Store store;
Fb fb;                          // the render surface (global; 24KB, off-stack)
static uint16_t out[W * H];     // RGB565 scratch for drawRGBBitmap

uint8_t overridePct = 0;        // brightness override %; 0 = time-of-day auto

// ── status LED (blue = connecting · off = healthy · red = stale) ─────────
void setStatusLed(uint8_t r, uint8_t g, uint8_t b) {
  static uint32_t last = 0xFFFFFFFF;
  uint32_t c = pixel.Color(r, g, b);
  if (c == last) return;
  pixel.fill(c);
  pixel.show();
  last = c;
}

// ── brightness override (persisted in NVS) ───────────────────────────────
void loadOverride() { overridePct = prefs.getUChar("b", 0); }

void pollButtons() {
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
    prefs.putUChar("b", overridePct);
    delay(250);  // debounce
  }
}

// ── frame present: gamma + brightness correction -> RGB565 -> panel ──────
static inline uint16_t to565(Rgb c) {
  return (uint16_t)(((c.r >> 3) << 11) | ((c.g >> 2) << 5) | (c.b >> 3));
}

void present(float scalar) {
  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      Rgb c = {fb.buf[y][x][0], fb.buf[y][x][1], fb.buf[y][x][2]};
      out[y * W + x] = to565(Brightness::correct(c, scalar));
    }
  }
  panel->drawRGBBitmap(0, 0, out, W, H);
  panel->flipDMABuffer();
}

// ── setup / loop ──────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);

  pinMode(PIN_BUTTON_UP, INPUT_PULLUP);
  pinMode(PIN_BUTTON_DOWN, INPUT_PULLUP);
  pixel.begin();
  pixel.setBrightness(40);

  prefs.begin("matrix");
  loadOverride();
  Brightness::init();

  HUB75_I2S_CFG cfg(W, H, 1 /* chain */, PINS);
  cfg.double_buff = true;
  cfg.setPixelColorDepthBits(6);
  cfg.min_refresh_rate = 120;
  cfg.clkphase = false;
  panel = new MatrixPanel_I2S_DMA(cfg);
  if (!panel->begin()) {
    while (true) {
      setStatusLed(40, 20, 0);
      delay(500);
      setStatusLed(0, 0, 0);
      delay(500);
    }
  }
  panel->setBrightness8(255);  // brightness/gamma baked into the frame in software
  panel->clearScreen();

  store.begin();
  Net::start(store);  // core 0: WiFi + NTP + ESPN polling
}

// Render loop (core 1): never blocks on the network — animations keep running
// through polls, Wi-Fi drops, and slow upstreams off the last good store state.
void loop() {
  int64_t now = nowEpochMs();
  StoreView v = store.capture(now, FINAL_HOLD_MS);
  Snapshot snap = SnapshotBuilder::build(v, now);

  fb.clear();
  Render::board(fb, snap);

  float scalar = overridePct ? overridePct / 100.0f : Brightness::forNow(now);
  present(scalar);

  pollButtons();
  delay(16);  // ~60fps
}
