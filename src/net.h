// WiFi + NTP + ESPN polling task — the on-device replacement for the server's
// Poller. Polls a rolling scoreboard window (today-1 .. today+7) on an adaptive
// cadence for the schedule + live scores, refreshes standings hourly, and feeds
// the Store. Runs on core 0.
#pragma once
class Store;

namespace Net {
// Spawn the poller task pinned to core 0. Must be called after store.begin().
void start(Store& store);
}  // namespace Net

// Provided by main.cpp — drives the onboard NeoPixel status LED
// (blue = connecting, off = healthy, red = stale).
extern void setStatusLed(unsigned char r, unsigned char g, unsigned char b);
