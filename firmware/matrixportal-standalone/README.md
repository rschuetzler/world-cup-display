# Matrix Portal S3 — standalone World Cup firmware

A fully **on-device** build of the World Cup tracker. Unlike the server-driven
firmware in [`../matrixportal-arduino`](../matrixportal-arduino) — which fetches
pre-rendered RGB565 frames from the Elixir server and blits them — this build
does everything itself:

- polls ESPN directly over HTTPS,
- parses the JSON (ArduinoJson, filtered, PSRAM-backed),
- runs the goal/finished state machine,
- chooses the board (goal > live > final-hold > now/next), and
- **renders the three boards natively** at ~60fps.

No server, no LXC, no network dependency beyond ESPN itself.

## How it differs from the server-driven firmware

| | `matrixportal-arduino` (server-driven) | `matrixportal-standalone` (this) |
|---|---|---|
| Data source | TravisTracker/WC Elixir server | ESPN site API, direct |
| Device job | fetch + blit RGB565 frames | poll, parse, decide, **render** |
| Layout changes | edit server, no reflash | reflash firmware |
| Survives server outage | no (server is the source) | n/a (no server) |
| Animations | server clock/scroll trailer | native, off the device clock |

It's a faithful C++ port of the server's Elixir stack: the renderers
(`WcRenderers` → `render.cpp`), state machine (`Display.State` → `snapshot.cpp`),
store with goal/finished edge-detection (`Store` → `store.cpp`), ESPN parser
(`Espn` → `espn.cpp`), and all the rendering primitives (font, flags, Geist
numerals, palette, teams, brightness, fmt).

## Architecture

Two FreeRTOS tasks, one per core:

- **Core 0 — `net.cpp`:** WiFi + NTP + ESPN. On boot fetches the full tournament
  schedule (`scoreboard?dates=20260611-20260719&limit=200`) and standings, then
  polls today's range on an adaptive cadence (20s live / 60s kickoff-soon /
  10min idle), refreshing schedule + standings hourly. Feeds the `Store`.
- **Core 1 — `main.cpp` `loop()`:** every frame computes `now` (epoch ms),
  captures a consistent `StoreView` under the store mutex, builds a `Snapshot`,
  renders it into the `Fb` surface, applies gamma 2.2 + time-of-day brightness,
  and pushes RGB565 to the HUB75 DMA panel.

## Assets

Flag art and the Geist big-numeral glyphs are baked into C++ headers under
`src/gen/`, generated from the same files the server uses:

```
python3 tools/gen_assets.py   # reads ../../priv/matrix/{flags,geist-native}.json
```

`src/gen/flags_data.h` and `src/gen/geist_data.h` are committed, so a normal
build doesn't need to regenerate them — only re-run the tool if those assets
change.

## Configure + build + flash

```
cp src/secrets.h.example src/secrets.h   # then edit WIFI_SSID / WIFI_PASSWORD
pio run                                  # build
pio run -t upload                        # flash (double-tap RESET if coming from CircuitPython)
pio device monitor                       # serial log
```

`src/secrets.h` is gitignored.

## Notes

- **Timezone:** the device runs one local timezone — `America/Denver`
  (`MST7MDT,M3.2.0,M11.1.0` in `net.cpp`), matching the server's `DISPLAY_TZ`.
  Edit the POSIX `TZ` string there to relocate; kickoff clocks, the weekday, and
  the day/night brightness curve all follow it.
- **Standings:** the live board's group label ("GROUP D") is resolved from a
  periodic standings fetch (refreshed hourly with the schedule). It's the
  heaviest parse on-device; knockout labels don't need it.
- **Brightness:** auto-dims by local time of day. The two front buttons override
  brightness in ±10% steps (persisted to NVS); press past 100% / below 10% to
  clamp. There's no button to restore auto from the firmware — clear NVS or
  reflash to reset.
- **Hardware:** Adafruit Matrix Portal S3 (ESP32-S3, 2MB PSRAM, 8MB flash) +
  128×64 HUB75 panel. PSRAM is required (ArduinoJson buffers + the full HTTP
  body live there).
