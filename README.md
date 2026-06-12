# World Cup Tracker

Pulls the 2026 FIFA World Cup schedule and live match information and displays
it on a 128×64 RGB LED matrix panel — the same hardware (and display
architecture) as [travis-tracker](../travis-tracker), the flight tracker this
project borrows from.

## Status

Greenfield. This repo currently contains the matrix-display reference material
copied from travis-tracker (see below); no tracker code exists yet.

## Display hardware & architecture (inherited from travis-tracker)

- **Panel:** 128×64 RGB HUB75, driven by an Adafruit **Matrix Portal S3**.
- **Firmware:** `firmware/matrixportal-arduino/` — PlatformIO/Arduino, using
  ESP32-HUB75-MatrixPanel-DMA. Pure fetch-and-blit: it GETs a server-rendered
  frame and displays it. (An older CircuitPython firmware exists in
  travis-tracker but is deprecated — it glitched on Wi-Fi radio events.)
- **Server renders everything.** Frames are baked server-side as raw
  **RGB565 little-endian** (128 × 64 × 2 = 16384 bytes) and served from an
  HTTP endpoint. The device polls with `If-None-Match`/ETag and honors
  `X-Poll-Seconds`. Layout changes never require a reflash.
- **Wire format:** `docs/matrix-display-protocol.md` — base frame + optional
  v1.1 trailer for on-device scroll regions and a live ticking clock.
- **Poll-driven rotation:** the device only sees a new slide when it polls, so
  multi-slide rotation must advance per-poll (travis-tracker's `AltCursor`),
  not by wall clock. Don't poll fast to fake animation — use the trailer's
  scroll/clock descriptors instead; bandwidth and battery matter.
- **Brightness/gamma** are baked into the device-endpoint encode (time-of-day
  curve + panel gamma); preview/simulator endpoints serve raw sRGB.
- **Font:** Geist pixel font in `font/` (BDF + C header + native JSON used by
  the Elixir renderer).
- **Simulator:** `tools/matrix_sim.py` decodes a live `.rgb565` frame to PNG
  with Pillow, so the wire format can be verified without hardware.

### One device, one URL

The physical panel polls a single `MATRIX_URL` baked into `secrets.h`. It
currently points at travis-tracker. To show World Cup content, either:

1. point the device at this project's frame endpoint (flash a new URL),
2. give this project its own panel, or
3. have travis-tracker proxy/interleave World Cup slides into its rotation.

Decide before building the serving side.

## What's where

| Path | Origin | Contents |
|------|--------|----------|
| `docs/matrix-display-protocol.md` | travis-tracker | The frame wire format (endpoints, headers, trailer). |
| `docs/travis-tracker-design/` | travis-tracker | Design specs for the hardware display, demo mode, scroll + live clock, and live preview. |
| `firmware/matrixportal-arduino/` | travis-tracker | The recommended Matrix Portal S3 firmware (PlatformIO). `cp src/secrets.h.example src/secrets.h` and fill in Wi-Fi + URL. |
| `font/` | travis-tracker | GeistPixel-Square font in BDF / C-header / JSON forms. |
| `reference/travis-tracker-matrix/` | travis-tracker | The Elixir server renderer (`framebuffer`, `rgb565`, `font`, `glyphs`, `trailer`, `alt_cursor`, …) plus the `matrix_binary` controller and demo-mode module. Reference only — module names are still `TravisTracker.*`. |
| `tools/matrix_sim.py` | travis-tracker | Desktop frame simulator (RGB565 → PNG). |

Copied 2026-06-12 from travis-tracker @ `8c60f50`.

## Environment notes

- Dev happens on `ryan-claw` (this host) over Tailscale; dev servers must bind
  `0.0.0.0`. Prod runs on the user's Proxmox cluster (LXC/VM), no cloud.
- `.tool-versions` pins Elixir/Erlang (matching travis-tracker) on the
  assumption this will also be a Phoenix app; change it if the stack changes.

## Next steps (not started)

- Pick a World Cup schedule/live-score data source (e.g. football-data.org,
  API-Football, FIFA's unofficial endpoints) and check rate limits against the
  device's 15–60 s poll cadence.
- Decide the serving model (own app vs. travis-tracker integration — see
  "One device, one URL").
- Design the boards: upcoming-fixtures slide, live-match slide (score, clock,
  scorers ticker via scroll trailer), group standings, knockout bracket.
