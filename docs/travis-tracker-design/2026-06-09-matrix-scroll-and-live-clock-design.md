# Matrix scrolling overflow + live on-device clock — design

**Date:** 2026-06-09
**Status:** Approved (brainstorm), ready for implementation plan

## Problem

Two issues on the 128×64 RGB LED matrix (`TravisTracker.Matrix`, served as RGB565
frames to the MatrixPortal S3 firmware and the preview gallery):

1. **Overflow clips.** The in-flight "over" line — `OVER <place>` or
   `<N> MI <dir> OF <city>, <ST>` — is centered and frequently wider than the
   panel, so both ends fall off and the most useful text (distance, city) is
   never visible. It should scroll like a ticker instead of clipping.

2. **Stale clock.** The clock is `HH:MM`, baked into each server-rendered frame.
   The device only repaints on its poll (15–60 s depending on state), so a new
   minute can appear up to a full poll interval late.

## Constraints & context

- The device firmware (`firmware/matrixportal-arduino/src/main.cpp`) is today a
  **pure fetch-and-blit** client: it GETs a `128×64×2 = 16384`-byte RGB565 frame
  and blits it. All layout/design lives server-side (`TravisTracker.Matrix`).
- The panel is driven by **DMA double-buffering at 120 Hz+** on the ESP32-S3, so
  the CPU can redraw the back buffer and flip at 30–60 fps with no display glitch
  and no network traffic. Local animation is cheap.
- Plan B unified rendering: the preview gallery (`priv/static/matrix/live-app.js`
  + `led-core.js`'s `LEDPanel.loadRGB565`) is a thin RGB565 client of the same
  server frames, so the gallery and device are byte-identical today.
- Brightness + gamma are baked server-side into the RGB565 encode; the device
  sets panel brightness to 255 and honors a `?b=` override by re-fetching.

## Chosen architecture

**Keep layout on the server; give the device two small extra capabilities:**
pan a few server-rendered text sprites, and render the live clock locally. The
firmware does NOT gain a general layout engine.

Rejected alternative: a full data-driven device renderer (server ships JSON, the
device owns all 8 state layouts in C++). It would mean porting ~600 lines of
renderers and maintaining two renderers in lockstep forever, and it breaks
gallery parity. Not worth it for the stated goals.

## Wire protocol — frame + optional trailer

Response body = the existing `16384`-byte RGB565 base frame, optionally followed
by a trailer. **If nothing overflows and the clock is not device-rendered, there
is no trailer and the body is byte-for-byte identical to today** (`Content-Length
== 16384`). Clients detect the trailer by length + magic.

```
[ 16384-byte RGB565 base frame ]
[ trailer (optional) ]
  "SCRL"            4 bytes magic
  version           u8   (= 1)
  count N           u8
  N × descriptor (variable, tagged by kind):
    kind            u8
    --- kind 0: scroll sprite ---
      x,y,w,h       u8 ×4    on-panel window rect
      stripW        u16 LE   full text-strip pixel width
      speed         u8       px/sec
      gap           u8       px between loop repeats
      mode          u8       0 = continuous loop (1/2 reserved: reset/ping-pong)
    --- kind 1: clock ---
      center_x      u8
      y             u8
      scale         u8       (1 = native 1:1; reserved for future sizes)
      color         u16 LE   RGB565
      tz_offset_min i16 LE   current UTC offset of the clock's timezone
      flags         u8       bit0 h12, bit1 show_seconds (0 for v1)
      anchor_epoch  u64 LE   server "now" at render (fallback before NTP)
  Then, in descriptor order, the kind-0 strips: stripW × h × 2 bytes RGB565 LE.
  Kind-1 descriptors carry no pixel payload.
```

Strips are rendered through the **same `to_rgb565` pipeline** as the base frame,
so gamma + brightness (and `?b=`) are baked in identically.

## Server changes (`TravisTracker.Matrix`)

### Framebuffer scroll regions
- `Framebuffer` gains a `scroll_regions` list (and the render result carries it
  through to `to_rgb565`).
- New helper `Framebuffer.scroll_text(fb, x, y, w, text, color, opts)`:
  - if `Font.text_w(text) <= w` → draw inline exactly as today (honoring
    `align: :center`), record nothing.
  - else → record `%{kind: :scroll, x:, y:, w:, h: 7, text:, color:, speed: 30,
    gap: 28, mode: :loop}` and leave the band blank.

### Clock region
- New helper `Framebuffer.clock_region(fb, center_x, y, opts)` records
  `%{kind: :clock, center_x:, y:, color:, tz_offset_min:, flags:, anchor:}` and
  leaves the digit bounding box blank — **only when `live_clock: true`** is set
  on the render. Otherwise it bakes the clock as today (gallery/web path).

### Renderers
- In-flight: replace `Font.text_center(64, 30, over, soft)` with
  `Framebuffer.scroll_text(fb, 4, 30, 120, over, soft, align: :center)`.
- Idle + layover big clock: route through `clock_region/3`, which bakes or
  blanks-and-descriptors based on the `live_clock` opt.

### Encoding
- `Matrix.to_rgb565/2` accepts opts `live_clock: bool`. After the base frame, for
  each region it emits a descriptor; for kind-0 it renders the full text to a
  `stripW × 7` strip and appends RGB565 bytes (same brightness/gamma). Kind-1
  emits descriptor only.

### Endpoints
- `DisplayController.matrix` (device) passes `live_clock: true`.
- `PreviewController.matrix` (gallery) does **not** → clock stays baked.
- **Poll cadence unchanged** (15/30/60 s). Data freshness drives polling; the
  clock now ticks independently on-device, which also avoids poll pile-up as more
  devices are added.

## Firmware changes (`main.cpp`, ~120 lines net)

- **Parse trailer:** after reading the body, if `got > 16384` and magic matches,
  parse up to `N` (cap 4) descriptors + kind-0 strips into static buffers
  (bound stripW, e.g. ≤512 → ≤8 KB/strip; the S3 has PSRAM headroom).
- **Animation tick** (replaces blit-once; runs inside the poll wait, ~16 ms):
  1. `drawRGBBitmap(base)` into the back buffer.
  2. For each scroll region: `off = (millis()*speed/1000) mod (stripW+gap)`; copy
     the strip into the back buffer at `x-off` and `x-off+span`, clipped to
     `[x, x+w)`.
  3. Render the clock region(s): compute local time, format `HH:MM`, blit the
     ported Geist routine centered on `center_x`.
  4. `flipDMABuffer()`.
  - With zero regions this collapses to one blit then idle — same as today.
- **Time base:** SNTP (`configTime`) on boot + hourly re-sync; the RTC ticks
  between syncs, so the clock stays correct through data-server outages. Before
  NTP locks, use `anchor_epoch + millis()` delta from the last frame.
- **304 handling:** on 304 keep the cached frame + regions and keep animating.

### Font parity (the main risk)
The device must match the server's `Matrix.Geist` placement exactly. The server
blits from `priv/matrix/geist-native.json` (per-glyph bitmap + `advance`/`xoff`/
`yoff`, cap-height 19, scale 1:1) via its `placed`/`string_w`/`big_center` math —
**not** Adafruit GFX. The repo's `font/GeistPixel-Square_native.h` is a GFX font
with different packing/baseline/advance, so it is **not** used here.

Instead: generate a small C header from `geist-native.json` containing only the
clock glyphs (`0`–`9`, `:`) in the same bitmap/advance/xoff/yoff structure, and
port the ~20-line `placed`/`blit`/center routine to C. This guarantees the
on-device clock is pixel-identical to the server's. A build/mix task should
generate the header from the JSON so the two never drift.

## Preview-gallery parity

- `led-core.js` `loadRGB565` learns to parse the trailer; `LEDPanel` gains a
  `requestAnimationFrame` pan for kind-0 sprites using the **server's** strip
  bytes + the same loop math → pixel-identical scrolling.
- Kind-1 (clock) is never emitted to the gallery (server bakes it), so **no Geist
  font port to JS** is needed.
- Regenerate the fingerprinted + `.gz` copies of the touched JS.

## Defaults

- Scroll: `speed 30 px/s`, `gap 28 px`, `mode :loop`, hard clip at region edges.
- Clock: minute resolution (`show_seconds = 0`), NTP + hourly re-sync.

## Scope

**In v1:**
- Scroll the in-flight "over" line only (mechanism generic for later opt-in).
- Device-render the idle + layover `HH:MM` clock.

**Out of v1 (mechanism leaves room):**
- Scroll for other panes (layover route, city labels).
- Ping-pong / scroll-and-reset modes (`mode` reserved).
- Edge fade on scroll regions (hard clip for now).
- A seconds display.
- Device-rendering anything beyond the clock.

## Testing

- `Framebuffer.scroll_text`: records a region on overflow, draws inline when it
  fits (by `Font.text_w`).
- `Matrix.to_rgb565`: trailer length + descriptor fields + strip dims for a long
  "over" string; **no trailer** when nothing overflows and `live_clock: false`
  (back-compat: body `== 16384`).
- `clock_region`: baked when `live_clock: false`; blanked + descriptor emitted
  when `true`; descriptor carries correct `tz_offset_min`/`anchor`.
- Golden in-flight frame with a long "over" string: base band blank, region
  present.
- Generated clock-glyph header matches `geist-native.json` (a test asserting the
  C header's bytes/metrics derive from the JSON, so they can't drift).
- Firmware + gallery: visual verification (scroll smoothness, clock tick, font
  parity vs a baked reference; outage behavior — clock keeps ticking when the
  data endpoint is down).

## Docs

- Update `docs/matrix-display-protocol.md` with the trailer format and the
  device-rendered clock.
