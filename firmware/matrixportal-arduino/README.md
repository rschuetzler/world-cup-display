# Matrix Portal S3 firmware (Arduino port)

Drives the 128×64 RGB panel from TravisTracker's server-rendered frames.
This is the **recommended firmware** — it replaces the CircuitPython version
(`../matrixportal/`), which flashed corrupted rows on every Wi-Fi radio event
because Protomatter's panel scan is CPU-coupled. This port uses
[ESP32-HUB75-MatrixPanel-DMA](https://github.com/mrcodetastic/ESP32-HUB75-MatrixPanel-DMA):
the S3's LCD peripheral replays the scan from RAM via DMA, so the display is
glitch-free no matter what the CPU/radio are doing (same architecture as the
Tidbyt).

## Build & flash

1. Install [PlatformIO](https://platformio.org/) (`pipx install platformio`).
2. `cp src/secrets.h.example src/secrets.h` and fill in Wi-Fi + your
   `MATRIX_URL` (the `/d/<token>/matrix.rgb565` for your display).
3. Coming from CircuitPython: double-tap RESET (bootloader mode) for the first
   flash. After that, `pio run -t upload` re-flashes over normal USB.
4. `pio device monitor` for serial output.

Note: flashing this erases CircuitPython (and the CIRCUITPY drive). To go
back, re-flash the CircuitPython `.uf2` via the bootloader.

## Buttons

- **Up / Down** — brightness override (±10%), saved in NVS (survives reboot).
  Buttons are live during the poll wait and trigger an immediate refetch.

## Status NeoPixel

- blue = connecting · off = healthy · red = stale (≥3 failed polls; last good
  frame stays up) · orange blink = panel init failed (out of DMA RAM).

## On-arrival checklist (hardware-dependent knobs in `main.cpp`)

- [ ] **Edge-column flicker / one-pixel shift** → toggle `cfg.clkphase`
      (already `false` for the current panel).
- [ ] **Ghosting** (faint horizontal echoes) → raise
      `cfg.latch_blanking` (default 1, try 2) or lower `setBrightness8`.
- [ ] **Colors swapped** → watch the boot self-test (solid red → green →
      blue). If the order is wrong, permute the R/G/B columns in `PINS` —
      the current panel wants R/B opposite of Adafruit's MTX_* names.

## How it works

Two tasks, one per core. A fetch task (core 0) GETs `MATRIX_URL` with
`If-None-Match`, streams the RGB565 body into a staging buffer, and waits
`X-Poll-Seconds`. The render loop (core 1) animates scroll regions and the
clock at ~60 fps, swapping the staging buffer in between ticks when a new
frame lands — so polls (TLS handshake, slow servers, Wi-Fi drops) never
freeze the animation. All layout lives on the server — see
`docs/matrix-display-protocol.md`.
