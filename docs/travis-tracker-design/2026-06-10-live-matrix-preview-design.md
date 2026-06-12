# Live matrix preview — design

## Problem

There's no way to see what the physical matrix panel is *currently* showing
without having the hardware in hand. The preview gallery (`/preview/matrix`)
renders the LED simulation only against hardcoded per-state fixtures; the device
endpoint (`/d/:token/matrix.rgb565`) serves the real live frame but as raw
bytes a browser can't usefully display (gamma/brightness-corrected for the
panel, with a live-clock trailer the browser renderer skips).

## Goal

A browser page, reachable without the hardware, that renders the user's **live**
matrix frame through the same simulated-LED renderer the gallery uses — so the
user can check their display from any device.

## Decisions (from brainstorming)

- **Access:** token URL, shareable, no login — hung off the existing display
  token, exactly like the device endpoints.
- **Brightness:** always full (raw color), matching the gallery — best for
  legibility. (`:raw` encoding ignores brightness anyway.)
- **Alternation:** the preview **cycles on its own** independent rotation cursor,
  so it shows every slide on its own cadence and never disturbs the panel.
- **Discoverability:** add a "Preview" link beside the existing Display URL on
  the dashboard.

## Architecture

### Routes (public `/d` scope, token-gated)

- `GET /d/:token/preview` → `DisplayController.preview` — an HTML page with a
  single simulated LED panel.
- `GET /d/:token/preview.rgb565` → `DisplayController.preview_frame` — the raw
  RGB565 bytes for that page.

Both 404 on an unknown token, mirroring the existing device actions.

### Frame encoding (`preview_frame`)

Renders the user's current snapshot the way the **gallery** encodes fixtures,
not the way the device encodes its frame:

- `mode: :raw` — true colors on an sRGB monitor (the corrected device bytes look
  wrong on a screen).
- `live_clock: false` — bake the clock into the base frame. `led-core.js`
  deliberately skips live-clock trailer regions, so baking is what makes the
  time render in the browser.
- No `?b=` brightness override (full brightness).

This is deliberately the same encoding path as `PreviewController.matrix`, just
applied to `Display.snapshot_for_user(user, nil)` (live data) instead of a
fixture.

### Snapshot selection — faithful to the panel, isolated from it

`preview_frame` mirrors the three branches of the device `matrix` action:

1. Unknown token → 404.
2. `demo_mode` user → render `MatrixDemo.current_fixture/2` (the same
   wall-clock-cycled fixture the device shows). This path is independent of the
   token cursor, so there's no interference.
3. Live user → `Display.snapshot_for_user(user, nil)`, then, for an
   `:alternating` snapshot, bake a slide index.

The alternation handling is the one place isolation matters. The device advances
a per-token cursor *once per poll* (`AltCursor.advance(token, …)`), and the panel
only rotates when it polls — so if the preview advanced that same cursor the
panel would skip slides. Instead the preview advances a **separate cursor key**,
`"#{token}:preview"`, via the same `AltCursor.advance/3`. Result: the preview
cycles on its own ~15 s cadence, the device's rotation is untouched.

`advance_alternation/2` in `DisplayController` is generalized to take the cursor
key (the `matrix` action passes `token`; `preview_frame` passes the
`:preview`-suffixed key). No new `AltCursor` function is required.

### Client (`priv/static/matrix/preview-app.js`)

A small single-panel client (~40 lines), distinct from the multi-panel
`live-app.js`:

- Reads the frame URL from a data attribute on the page
  (`/d/<token>/preview.rgb565`).
- Fetches the frame, renders it via `led-core.js` (`loadRGB565` + `present` /
  `presentAnimated`), and re-polls on the interval named by the response's
  `x-poll-seconds` header.
- Animates scrolling regions via `led-core`'s existing path. It does not depend
  on the parked scroll-poll-continuity work, but inherits its improvement once
  that lands.

### HTML page (`preview` action + template)

A minimal template that bypasses the root layout (like the existing kiosk `show`
page and the gallery), containing one `<canvas>` and `<script>` tags for
`led-core.js` + `preview-app.js`, with the frame URL in a data attribute. Script
inclusion mirrors the gallery template (`matrix_preview_html/index.html.heex`).

### Dashboard link

Beside the existing Display URL on the dashboard, add a "Preview" link to
`/d/<token>/preview`. Reuses the same token/URL helper that renders the Display
URL today (`TravisTrackerWeb.DisplayUrl`).

## Fidelity note

Between device polls the panel holds a frame up to ~15 s old, while the preview
re-renders the live snapshot each poll — so the preview is *fresher* than the
panel, not a byte-for-byte copy of the frame currently latched on the hardware.
For "what is my display showing right now," fresher live data is the desired
behavior; this is a deliberate, documented gap, not a bug.

## Testing

- **Controller** (`display_controller_test.exs`):
  - `GET /d/:token/preview.rgb565` → 200, `content-type: application/octet-stream`,
    body ≥ 16384 bytes, `x-display-width: 128` / `x-display-height: 64` /
    `x-poll-seconds` headers present.
  - Unknown token → 404.
  - `demo_mode` user → 200 with a frame (demo path exercised).
  - `GET /d/:token/preview` → 200 HTML containing the `<canvas>` and the
    `preview-app.js` / `led-core.js` script references and the frame-URL data
    attribute.
- **Isolation** (`alt_cursor` / controller): advancing the preview cursor key
  does not move the device cursor for the same token — the device's
  `advance(token, …)` sequence is unaffected by interleaved
  `advance("#{token}:preview", …)` calls. (Distinct keys already guarantee this;
  the test pins the guarantee.)

## Out of scope

- Matching the device's time-of-day brightness dimming (chosen against: full
  brightness).
- A login-gated variant (chosen against: token URL).
- Byte-exact reproduction of the last frame latched on the hardware (see Fidelity
  note).
- Changes to `led-core.js` scroll behavior (covered by the separate, parked
  scroll-poll-continuity spec).
