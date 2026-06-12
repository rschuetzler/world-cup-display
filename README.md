# World Cup Tracker

Pulls the 2026 FIFA World Cup schedule and live match information and displays
it on a 128×64 RGB LED matrix panel — the same hardware (and display
architecture) as [travis-tracker](../travis-tracker), the flight tracker this
project borrows from.

## Status

Working end-to-end (2026-06-12): a supervised Elixir OTP app polls ESPN's
unauthenticated API (FIFA's as fallback — `docs/2026-06-12-data-source-research.md`),
normalizes matches into a Store with goal edge-detection, builds display
snapshots, renders the three boards from the design handoff
(`reference/worldcup-design/`), and serves device frames at
`GET /matrix.rgb565` (Bandit on `0.0.0.0:4400`, ETag + adaptive
`X-Poll-Seconds`). `GET /preview.rgb565` serves the raw-sRGB frame for
`tools/matrix_sim.py`; `GET /healthz` reports store freshness.

Run it: `mix deps.get && mix run --no-halt`, then point the panel (or curl)
at `http://ryan-claw:4400/matrix.rgb565`.

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

## Next steps / known gaps

- **Verify live-window API behavior** — ESPN `in`-state shape, FIFA live
  `MatchStatus`/`Period`, halftime strings. Probe tool:
  `tools/wc_data_probe.py`; run it during any live match.
- **Flags cover 22 of 48 teams.** The design handoff defines 22 flag
  samplers; everyone else (BIH, PAR, QAT, HAI, CUW, CPV, …) renders the grey
  placeholder checker. Needs more samplers (or a codes-only fallback policy).
- **Goal-burst cadence needs a firmware tweak.** The server sends
  `X-Poll-Seconds: 0.3` during the goal celebration per the design, but
  `firmware/matrixportal-arduino/src/main.cpp` parses the header with
  `toInt()` + `max(5, …)`, so fractional bursts are ignored. Needs float
  parse + lower clamp before the celebration animates on hardware.
- **Marquee as trailer scroll strip** (design follow-up): extend
  `Matrix.Trailer` to 2× font strips so the GOOOL marquee scrolls smoothly
  on-device between polls.
- **Now & Next with zero live matches** still shows the `LIVE` header over an
  empty section (design assumed ≥1 live row). Cosmetic; decide what idle
  should look like.
- **FIFA fallback isn't wired into the Poller** — `WorldCupTracker.Fifa` is
  implemented and tested but the Poller only uses the ESPN source today.
- Decide the device cutover (point the panel's `MATRIX_URL` here vs.
  travis-tracker proxying — see "One device, one URL").
- Standings/bracket boards (data is already in the Store; no renderer yet).
