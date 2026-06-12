# Matrix Display Demo Mode — Design

**Date:** 2026-06-06
**Status:** approved (pending spec review)

## Problem

There's no way to show off the matrix panel or eyeball each display state on
real hardware without engineering a live flight into that state. We want a
"demo mode" that cycles the panel through all the display states on a timer,
toggled from the web UI so it works on the panel already mounted on the wall —
no firmware change.

## Scope

Demo mode affects **only** the matrix frame endpoint `GET /d/:token/matrix.rgb565`.
The HTML kiosk (`/d/:token` + `/d/:token/data`) is a separate device path and
stays on live data. (The backlog item is specifically the matrix panel; not
expanding scope to the browser kiosk.)

## Decisions (locked)

- **Trigger:** a per-user persistent flag, flipped by an **instant toggle** on
  the settings page (no Save step). When on, the user's `matrix.rgb565`
  endpoint serves cycling fixtures instead of their live snapshot.
- **States cycled:** all 10 in `@states` order — `idle`, `trip_pending`,
  `layover`, `pre_flight`, `taxiing`, `in_flight`, `alternating`,
  `post_flight`, `post_flight_pill_on_layover`, `post_flight_pill_on_pre_flight`.
- **Dwell:** per-user configurable, shown next to the toggle. **Default 5 s,
  bounded 5–60 s.** The 5 s floor matches the firmware's poll floor
  (`max(5, ps)` in both the Arduino and CircuitPython builds): a dwell below
  the panel's actual poll interval would desync (server advances state faster
  than the panel refetches, skipping states).
- **Rotation is stateless, wall-clock driven** — no stored cursor, no per-poll
  DB writes; multiple panels stay in sync and it survives restarts.

## Data model

Two new columns on `users` (one migration):

- `demo_mode :boolean, default: false, null: false`
- `demo_dwell_seconds :integer, default: 5, null: false`

`User` changeset validates `demo_dwell_seconds` is in `5..60`. `Accounts` gains
a setter used by the settings LiveView (see below).

## Components

### `TravisTrackerWeb.DisplayFixtures` (new — extracted, mechanical)

The 10 fixtures and the `@states` list currently live **inside**
`TravisTrackerWeb.PreviewController` and are already reached into from
`renderers_test.exs` (`PreviewController.fixture/2`). Move them verbatim into a
dedicated module:

- `states/0` → the 10 state atoms, in lifecycle order.
- `fixture(state, now)` → the per-state snapshot map (moved as-is).
- `parse_state(string)` → `{:ok, atom} | :error` (moved from PreviewController).

`PreviewController` then delegates to `DisplayFixtures`; the renderer tests
import from it. No behavior change — golden frames are byte-identical.

**Rationale:** removes the "controller as a shared library" smell and gives the
demo path a clean dependency that isn't another controller.

### `TravisTrackerWeb.MatrixDemo` (new — the rotation engine)

- `current_fixture(now, dwell_seconds)` → `{state, fixture_map}` where
  `index = rem(div(now_ms, dwell_ms), length(states))` and
  `now_ms = DateTime.to_unix(now, :millisecond)`. Looks the state up in
  `DisplayFixtures.states/0` and returns `{state, DisplayFixtures.fixture(state, now)}`.

Pure and deterministic given `now` — trivially unit-testable. Fixtures are
still computed against the real `now`, so countdowns/clocks read realistically.

### `TravisTrackerWeb.MatrixBinary` (modified)

`send_frame/3` gains an optional `:poll` opt. The poll header becomes
`opts[:poll] || Map.get(@poll, state, 30)`. Everything else (ETag from frame
bytes, `X-Display-State`, 304 on `If-None-Match`) is unchanged. The
state-keyed `@poll` defaults still drive the non-demo live path.

### `TravisTrackerWeb.DisplayController.matrix/2` (modified)

Single user lookup, then dispatch:

```elixir
def matrix(conn, %{"token" => token} = params) do
  case Accounts.get_user_by_display_token(token) do
    nil ->
      conn |> put_status(:not_found) |> text("not found")

    %User{demo_mode: true} = user ->
      {_state, fixture} = MatrixDemo.current_fixture(DateTime.utc_now(), user.demo_dwell_seconds)
      MatrixBinary.send_frame(
        conn,
        fixture,
        [mode: :corrected, poll: user.demo_dwell_seconds] ++ MatrixBinary.brightness_opt(params)
      )

    user ->
      case Display.snapshot_for_user(user, nil) do
        nil -> conn |> put_status(:not_found) |> text("not found")
        snapshot -> MatrixBinary.send_frame(conn, snapshot, [mode: :corrected] ++ MatrixBinary.brightness_opt(params))
      end
  end
end
```

The demo frame goes through the **same** encode path (`mode: :corrected` gamma +
`?b=` brightness override), so color/brightness behave identically to the real
display.

### Settings LiveView (modified)

A "Demo mode" section with:

- An **instant toggle** (its own `handle_event`) that flips `demo_mode` and
  persists immediately — no Save button.
- A **dwell input** (number, 5–60) next to it that persists on **blur**
  (`phx-blur`, so a half-typed value like `1` isn't saved/rejected mid-keystroke),
  reusing the same `Accounts` setter / changeset validation.

## Data flow

1. Panel polls `GET /d/:token/matrix.rgb565` every `X-Poll-Seconds`.
2. Controller looks up the user. If `demo_mode`:
   `MatrixDemo.current_fixture(now, dwell)` picks the state from the wall clock,
   renders + corrected-encodes it, sets `X-Poll-Seconds = dwell`.
3. State changes → frame bytes change → new ETag → `200` + new frame. Same
   state polled twice (timing jitter) → identical bytes → `304`, no flicker.
4. Panel refetches after `dwell` seconds → next state.

## Error handling / edge cases

- **Unknown token** → 404 (unchanged).
- **Dwell out of range** → rejected by the changeset; the input shows the
  validation error and the stored value is unchanged.
- **`alternating` state** renders whatever the renderer already produces for it
  (it's an existing state with a golden frame); no special handling.
- **Brightness `?b=`** continues to work in demo mode (same opts append).

## Testing

- **`MatrixDemo` unit test** (deterministic `now`): index advances at each
  dwell boundary, wraps from the last state back to the first, and a sweep
  across `10 * dwell` covers all 10 states exactly once per loop.
- **Controller test:** a `demo_mode: true` user hitting `matrix.rgb565` gets
  `200`, a 16384-byte body, `X-Poll-Seconds == demo_dwell_seconds`, and a
  `X-Display-State` that changes as injected time crosses dwell boundaries; a
  `demo_mode: false` user is served the live snapshot exactly as before.
- **Settings test:** toggling persists `demo_mode`; setting dwell persists and
  rejects out-of-range values.
- **Refactor safety:** existing `golden_test.exs` and `renderers_test.exs` pass
  unchanged after the `DisplayFixtures` extraction (byte-identical frames).

## Out of scope (YAGNI)

- Demo mode for the HTML kiosk / JSON data endpoint.
- A tokenless public demo endpoint.
- Configurable per-state dwell or custom state ordering.
- Animating sub-second transitions (the panel's poll floor is 5 s).

## Deploy

Standard flow: `bin/deploy.sh` (build → ship → migrate → restart). The new
migration adds the two columns; `bin/migrate` runs it as part of the deploy.
