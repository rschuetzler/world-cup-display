# Matrix Display Protocol

The wire format between TravisTracker (server) and the 128×64 RGB panel
(Adafruit Matrix Portal S3, CircuitPython). The server renders; the device blits.

## Endpoints

- `GET /d/:token/matrix.rgb565` — the live device frame (per-user secret token).
- `GET /preview/:state/matrix.rgb565` — a fixture frame for one state (no token).

## Response body

Raw pixels, no header: `128 × 64 × 2 = 16384` bytes, row-major (y outer, x inner),
top-left origin, **RGB565 little-endian** (`(r5 << 11) | (g6 << 5) | b5`, low byte
first).

## Response headers

| Header | Meaning |
|--------|---------|
| `ETag` | Hash of the **base 16 KB frame** (not the optional trailer). Send back as `If-None-Match`; an unchanged base returns `304` with no body. Hashing only the base keeps caching alive even though the live-clock trailer's `anchor` changes every render — the device keeps animating the clock/scroll from its cached trailer until the base changes. |
| `X-Display-State` | Current state name (e.g. `in_flight`). |
| `X-Display-Width` / `X-Display-Height` | `128` / `64`. |
| `X-Poll-Seconds` | How long the device should wait before the next poll (adaptive: ~15 in-flight, up to 60 idle). |
| `Cache-Control` | `no-store`. |
| `Content-Type` | `application/octet-stream`. |

## Query params

- `?b=0.0–1.0` — manual brightness override (the device's button control).
  Absent → the server's time-of-day brightness curve (device timezone).

## Correction

The **device** endpoint applies gamma + brightness in the encode. The **preview**
endpoint is `:raw` (an sRGB monitor needs no panel gamma), so the gallery shows
the design's true colors.

## Optional frame trailer (v1.1)

After the 16384-byte base frame, the body MAY include a trailer. If the body is
exactly 16384 bytes there is no trailer (back-compatible). Layout (little-endian):

    "SCRL"            4 bytes magic
    version           u8   (= 1)
    count N           u8
    N × descriptor:
      kind            u8
      kind 0 scroll:  x u8, y u8, w u8, h u8, stripW u16 LE, speed u8, gap u8, mode u8
      kind 1 clock:   center_x u8, y u8, scale u8, color u16 LE (RGB565),
                      tz_offset i16 LE (minutes), flags u8, anchor u64 LE (epoch ms)
    then kind-0 strips in descriptor order: stripW × h × 2 bytes RGB565 LE.

    flags: bit0 = 12-hour, bit1 = show seconds (0 in v1).
    mode (scroll): 0 = continuous left loop with `gap` px between repeats.

The trailer is emitted only when needed: a scroll descriptor appears when a line
overflows its pane; a clock descriptor appears only on the **device** endpoint
(the preview endpoint bakes the clock into the base frame instead). Clients with
no trailer support read the first 16384 bytes and ignore the rest — overflowing
lines and the live clock then appear blank for them.

**Scroll sprite:** the base frame leaves the window `[x, x+w) × [y, y+h)` blank.
The client pans the strip: at screen column `cx ∈ [x, x+w)`, show strip column
`((cx - x) + floor(now_ms * speed / 1000)) mod (stripW + gap)`; columns ≥ stripW
are the gap (blank). Strips are pre-corrected (gamma/brightness baked in) like the
base frame.

**Clock (device only):** the base frame leaves the digits blank. The device
computes `local = utc(NTP, or anchor + elapsed) + tz_offset`, formats `HH:MM`, and
renders the Geist numerals centered on `center_x` at top `y`. `anchor` is a
fallback time source before NTP locks. Because the clock is rendered on-device, it
ticks on time and keeps running through server outages.

## Errors

Unknown token / state → `404`. The device keeps its last good frame on any
non-200 (other than 304) or network error.
