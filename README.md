# World Cup matrix display — standalone firmware

On-device firmware for an **Adafruit Matrix Portal S3** driving a **128×64 HUB75
LED panel** as a live FIFA World Cup scoreboard. It does everything itself:

- polls ESPN's public API directly over HTTPS,
- parses the JSON (ArduinoJson, filtered, PSRAM-backed),
- runs a goal / finished state machine,
- chooses which board to show (goal > live > final-hold > now/next), and
- **renders the boards natively** at ~60fps.

No server and no network dependency beyond ESPN itself.

## Boards

- **Live** — flags, score, match clock, and group/stage label for the match in play.
- **Goal** — a ~16s celebration flash when a live score ticks up.
- **Final hold** — keeps a just-finished result on screen for ~20 minutes.
- **Now & Next** — idle board with the weekday plus the next scheduled fixtures.

## Architecture

Two FreeRTOS tasks, one per core:

- **Core 0 — `net.cpp`:** WiFi + NTP + ESPN. On boot it fetches the full
  tournament schedule (`scoreboard?dates=20260611-20260719&limit=200`) and
  standings, then polls today's range on an adaptive cadence (20s live / 60s
  kickoff-soon / 10min idle), refreshing schedule + standings hourly. Feeds the
  `Store`.
- **Core 1 — `main.cpp` `loop()`:** every frame computes `now` (epoch ms),
  captures a consistent `StoreView` under the store mutex, builds a `Snapshot`,
  renders it into the `Fb` surface, applies gamma 2.2 + time-of-day brightness,
  and pushes RGB565 to the HUB75 DMA panel.

Because every renderer is a pure function of `snap.now`, the goal celebration,
the LIVE blink, and the match clock all animate smoothly off the device's
NTP-synced clock — no frame polling.

## Configure + build + flash

[PlatformIO](https://platformio.org/) is used for the build:

```
cp src/secrets.h.example src/secrets.h   # then edit WIFI_SSID / WIFI_PASSWORD
pio run                                  # build
pio run -t upload                        # flash (double-tap RESET if coming from CircuitPython)
pio device monitor                       # serial log (USB CDC)
```

`src/secrets.h` is gitignored.

## Assets

Flag art and the big-numeral glyphs are baked into C++ headers under `src/gen/`,
generated from the JSON sources in `assets/`:

```
python3 tools/gen_assets.py   # reads assets/{flags,geist-native}.json
```

`src/gen/flags_data.h` and `src/gen/geist_data.h` are committed, so a normal
build doesn't need to regenerate them — only re-run the tool if those assets
change.

## Notes

- **Hardware:** Adafruit Matrix Portal S3 (ESP32-S3, **2MB quad-SPI PSRAM**, 8MB
  flash) + 128×64 HUB75 panel. PSRAM is required — the HTTP response bodies and
  the ArduinoJson parse buffers live there. The PlatformIO build sets
  `board_build.arduino.memory_type = qio_qspi` to match the quad PSRAM; the
  octal (`qio_opi`) setting silently fails to bring PSRAM up.
- **Timezone:** the device runs one local timezone — `America/Denver`
  (`MST7MDT,M3.2.0,M11.1.0` in `net.cpp`). Edit the POSIX `TZ` string there to
  relocate; kickoff clocks, the weekday, and the day/night brightness curve all
  follow it.
- **Standings:** the live board's group label ("GROUP D") is resolved from a
  periodic standings fetch (refreshed hourly with the schedule). It's the
  heaviest parse on-device; knockout labels don't need it.
- **Brightness:** auto-dims by local time of day. The two front buttons override
  brightness in ±10% steps (persisted to NVS); press past 100% / below 10% to
  clamp. There's no button to restore auto from the firmware — clear NVS or
  reflash to reset.
- **Status LED:** the onboard NeoPixel shows health — blue while connecting to
  WiFi, off once polls succeed, red if three polls fail in a row (stale data).

## License

MIT — see [LICENSE](LICENSE).
