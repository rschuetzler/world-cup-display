# Matrix Hardware Display — Design

**Date:** 2026-06-01
**Status:** Approved (brainstorm), pending implementation plan
**Hardware:** [Adafruit Matrix Portal S3](https://www.adafruit.com/product/5778) driving a 128×64 RGB HUB75 LED matrix.

## Goal

Get the codebase as ready as possible to light up a real 128×64 RGB LED panel
the moment the Matrix Portal S3 arrives. We already have a 128×64 *browser*
preview (the `/preview/matrix` gallery, rendered in JS). This project moves the
canonical rendering server-side, defines a device-friendly binary protocol, and
prepares flash-ready firmware — so arrival day is "copy files, set Wi-Fi,
confirm a few panel constants," not "start building."

## Key decisions (from brainstorming)

1. **Render location: server.** The server produces a ready-made 128×64 frame;
   the device just blits it. Firmware stays tiny and rarely reflashed; design
   iteration happens server-side where we can preview it in a browser.
2. **Render engine: a pure-Elixir port.** The existing JS renderers become the
   reference spec; layout logic is reimplemented once in Elixir and becomes the
   single source of truth. The browser gallery then shows the *same* server
   frames, so preview == panel.
3. **Firmware: CircuitPython.** Drag-and-drop `code.py`, no compile/flash
   toolchain. The device is pure fetch-and-blit, so Python is plenty.
4. **Brightness: auto by time-of-day, with a button override.** The server
   scales brightness from a day/night curve using the display's local time, and
   bakes gamma into the encode. The board's two buttons nudge an override via a
   `?b=` query param. Gamma + brightness are applied at encode time only; the
   canonical framebuffer stays full-range.
5. **Poll cadence: ~15s,** server-adaptive per state (faster in-flight, slower
   idle), advertised in a response header.

## Architecture & data flow

```
TravisTracker (Elixir)                    Matrix Portal S3 (CircuitPython)
─────────────────────                     ────────────────────────────────
Display.snapshot_for_token(token)
  → Matrix.Renderers.render(snap)
      = Matrix.Framebuffer (128×64 RGB, logical pixels)
  → Matrix.Rgb565.encode(fb, brightness, gamma)
      = 16 KB little-endian RGB565
                              ──HTTP GET──▶  every X-Poll-Seconds:
GET /d/<token>/matrix.rgb565                  GET with If-None-Match
  body: 8192 px × 2 B = 16 KB                  200 → bitmaptools.readinto → panel
  headers: ETag, X-Display-State,             304 → keep frame
           X-Poll-Seconds, no-store           error → keep last frame, signal LED
  If-None-Match match → 304
```

The same `Matrix.Framebuffer` feeds two thin consumers: the device (`Rgb565`
bytes) and the browser gallery (fetches the same bytes, paints them with the
retained `led-core.js` LED-dot/bloom surface).

## Protocol contract

This is the one thing both sides must agree on; it gets its own reference doc
(see Documentation).

- **Device endpoint:** `GET /d/:token/matrix.rgb565`
  - Auth: the existing per-user secret token (same threat model as `/d/:token`).
  - Body: raw pixels only, no header — `128 × 64 × 2 = 16384` bytes, row-major,
    top-left origin, **RGB565 little-endian**.
  - Headers: `ETag` (hash of the frame bytes), `X-Display-State`,
    `X-Display-Width` / `X-Display-Height`, `X-Poll-Seconds`,
    `Content-Type: application/octet-stream`, `Cache-Control: no-store`.
  - `If-None-Match: <etag>` → `304 Not Modified` with no body when unchanged.
  - `?b=0.0–1.0` optional manual brightness override; absent → time-of-day curve.
  - Unknown token → `404`.
- **Preview endpoint:** `GET /preview/:state/matrix.rgb565`
  - Mirrors `/preview/:state/data`: renders the fixture for one state, no token.
  - Served **raw** (full range, no panel gamma) — a monitor is already sRGB, so
    the gallery shows the design's true colors while the device path applies
    panel correction. (A `corrected` mode is available for parity testing.)

## Server components (`TravisTracker.Matrix`)

Small, single-purpose units:

- **`Matrix.Framebuffer`** — a logical 128×64 RGB surface as a sparse map
  `%{{x, y} => {r, g, b}}` (only lit pixels; default off). Pure drawing helpers
  return updated framebuffers: `put_pixel/4`, `rect/6`, `hline`/`vline`,
  `text/5`, `text_right`/`text_center`, `progress/6`. Encodes in one final pass.
- **`Matrix.Font`** — the two typefaces + icons, ported verbatim from the JS:
  - the 5×7 uppercase bitmap font (`F` hex rows) as a compile-time attribute,
  - the **Geist Pixel Square** numerals — the auto-generated bitmap JSON shipped
    as `priv/matrix/geist-native.json`, read + decoded at compile time,
  - the pixel **icons** (weather glyphs + plane marker).
  - API: `draw_text`, `draw_geist`, `draw_icon`.
- **`Matrix.Palette`** — the accent/status color constants (the JS `RP`/`TW`
  palette): cyan = active/in-flight, green = on-time, amber = delay, warm tints
  for weather/time-of-day.
- **`Matrix.Renderers`** — one pure function per state,
  `render(snapshot) → framebuffer`, mirroring the 10 JS renderers 1:1: `idle`,
  `trip_pending`, `layover`, `pre_flight`, `taxiing`, `in_flight`,
  `post_flight`, `alternating`, and the two recent-landing-pill variants. Reads
  the snapshot field names `DisplayController` already serializes; computes
  clocks/countdowns/progress from `snap.now`.
- **`Matrix.Brightness`** — the time-of-day → brightness-scalar curve (using the
  display timezone) and the gamma LUT.
- **`Matrix.Rgb565`** — encodes a framebuffer to the 16 KB little-endian RGB565
  binary, applying brightness + gamma (or raw, for preview). Pure, no deps.

**Principle — logical pixels, no bloom.** The renderers emit only crisp logical
pixels (true per-LED colors). Round-LED dots and glow are a *display-surface*
concern: physical on the panel, and `led-core.js` in the browser. Bloom is never
part of the canonical frame.

## Preview unification

- **Keep** `led-core.js` as a dumb display surface (the round-LED + bloom look).
- **Slim** `live-app.js`: for each board, fetch its `…/matrix.rgb565`, decode the
  16-bit pixels, hand them to `led-core` to paint. Board list/labels stay.
- **Delete** the layout/data JS now living in Elixir: `renderers.js`, `fonts.js`,
  `geist-native.js`, `fontblit.js`, `fixtures.js` (and their `static_paths`
  entries / digested artifacts).
- Result: the gallery shows the exact logical frames the panel displays, with
  cosmetic bloom for screen realism. Zero layout drift possible.

## Firmware (CircuitPython)

Files dropped on the `CIRCUITPY` USB drive:

- **`code.py`** — the whole program.
- **`settings.toml`** — `CIRCUITPY_WIFI_SSID`, `CIRCUITPY_WIFI_PASSWORD`,
  `MATRIX_URL` (the full `/d/<token>/matrix.rgb565` URL). Read via `os.getenv`;
  keeps secrets out of `code.py`. Ship `settings.toml.example`.
- **`lib/`** — only `adafruit_requests` + `adafruit_connection_manager` (HTTPS).
  Everything else (`wifi`, `socketpool`, `ssl`, `displayio`, `rgbmatrix`,
  `framebufferio`, `bitmaptools`, `microcontroller`) is built into the Matrix
  Portal S3 CircuitPython firmware. Ship a pinned library/version note.

**Boot / display setup:** configure `rgbmatrix.RGBMatrix` with the Matrix
Portal's fixed pin set, `width=128, height=64, bit_depth=<tunable>`, wrap in
`framebufferio.FramebufferDisplay` (hardware scans via `auto_refresh`). One
persistent `displayio.Bitmap(128, 64, 65536)` + `ColorConverter(RGB565)` →
`TileGrid` → root group; pixels update in place, no per-frame allocation.

**Poll loop:**
1. `GET MATRIX_URL` with `If-None-Match: <last_etag>` (and `?b=<override>` if set).
2. `200` → `bitmaptools.readinto(bitmap, BytesIO(resp.content), bits_per_pixel=16,
   swap_bytes=…)` → panel shows it. Save `ETag`; read `X-Poll-Seconds`.
3. `304` → keep frame, sleep.
4. error (timeout / wrong length / Wi-Fi drop) → keep last good frame, bump a
   failure counter, reconnect Wi-Fi as needed; after N consecutive failures,
   signal on the onboard red LED / NeoPixel (status only — no drawing).
5. Sleep `X-Poll-Seconds`.

**Buttons:** the two onboard buttons step a brightness override (±0.1, clamped),
stored in `microcontroller.nvm` so it survives reboots (the filesystem is
read-only while USB-mounted). The override rides along as `?b=` on the next
fetch; the server does the actual dimming.

**Hardware-dependent constants** (confirm once the panel is in hand — the only
real unknowns):
- Panel **geometry/chain**: a 128×64 may be one panel or two 64×64 tiles —
  `rgbmatrix` needs the right `tile` / address-line (`E`) and serpentine config
  for 1/32-scan.
- **RGB565 byte order** — verify colors aren't swapped (flip `swap_bytes`).
- Starting **`bit_depth`** and brightness/gamma curve fine-tune.

## Documentation deliverables

Documentation is part of the work, not a follow-up:
- **Protocol contract reference** — `docs/matrix-display-protocol.md`: the
  endpoint, binary format, headers, brightness param, and correction modes, so
  server and firmware stay in sync. The single source of truth for the wire
  format.
- **Firmware README** — flashing CircuitPython onto the Matrix Portal S3, copying
  `lib/`, filling `settings.toml`, and an **on-arrival checklist** for the
  hardware-dependent constants above.
- **`@moduledoc`s** on every `Matrix.*` module.
- **PLAN.md update** — record the milestone in the project plan.

## Testing strategy

- **Unit tests** — font glyph blits, text alignment, progress-bar fill %, the
  gamma LUT, the time-of-day brightness curve, RGB565 encoding/endianness.
- **Golden-frame tests** — render each state's fixture, assert the encoded bytes
  match a committed golden (regenerated deliberately when a layout changes).
  This is the primary guard against drift.
- **Endpoint conn tests** — body is exactly 16384 bytes; `ETag` present;
  `If-None-Match` → `304`; `X-Poll-Seconds` varies by state; `?b=` clamps; bad
  token → `404`; preview endpoint renders each state.
- **Preview gallery parity** — Playwright screenshots of each gallery state
  confirm the server frames render correctly in the browser.
- **Desktop device simulator** — a small Python/Pillow script in `tools/` that
  fetches `…/matrix.rgb565` from the running server and saves/shows a PNG,
  exercising the real fetch → 16-bit decode → endianness path with a non-browser
  client. De-risks the protocol before any hardware exists.
- **Firmware** runs end-to-end only on the board; the simulator covers the
  network/decode half until then.

## Sequencing (implementation phases)

1. `Framebuffer` + `Font` (5×7 + Geist + icons) + `Palette` + primitives — unit
   tested.
2. `Renderers` — port the 10 layouts — golden-frame tested.
3. `Rgb565` + `Brightness`/gamma + the two endpoints + adaptive headers — conn
   tested.
4. Preview unification — slim `live-app.js`, delete the layout JS,
   Playwright-verify gallery parity.
5. Firmware `code.py` + `settings.toml.example` + lib note + README + the desktop
   simulator.
6. Documentation pass (protocol reference, firmware README + on-arrival
   checklist, moduledocs, PLAN.md) — woven through the phases, finalized here.
7. *(On arrival)* flash, fill `settings.toml`, confirm geometry / endianness /
   bit-depth, tune the brightness curve.

## Out of scope (YAGNI)

- Device-side layout/time math (countdowns step per poll; that's fine for a wall
  panel).
- The accelerometer, an ambient light sensor (designed-around, can add later via
  STEMMA QT), Bluetooth.
- Push transport (WebSocket/SSE) — HTTP polling with `ETag`/`304` is sufficient.
- Multiple simultaneous panels / per-panel layout variants.
