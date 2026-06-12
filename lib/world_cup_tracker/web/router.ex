defmodule WorldCupTracker.Web.Router do
  @moduledoc """
  The HTTP serving layer for the 128×64 panel — the wire protocol is
  `docs/matrix-display-protocol.md`, the consumer is
  `firmware/matrixportal-arduino`.

    * `GET /matrix.rgb565` — the device frame: `Display.State.snapshot/1` →
      `WcRenderers.render/1` → RGB565 with panel gamma + time-of-day
      brightness baked in (`?b=0.0–1.0` overrides the curve, the device's
      button control). Honors `If-None-Match` → `304`.
    * `GET /preview.rgb565` — the same frame, `:raw` encode (an sRGB monitor
      needs no panel correction), for `tools/matrix_sim.py`.
    * `GET /healthz` — store freshness as JSON.

  v1 serves the 16384-byte base frame only: `WcRenderers` emits no
  scroll/clock descriptors yet, so no v1.1 trailer is appended. Follow-up:
  the goal marquee as a 2× scroll strip (see
  `reference/worldcup-design/README.md`, "The marquee as a scroll strip").

  Both frame endpoints accept `?now=` (epoch ms) overriding the snapshot
  clock — a determinism hook for tests and frame debugging; the device never
  sends it.
  """

  use Plug.Router

  alias WorldCupTracker.Display.State
  alias WorldCupTracker.Matrix.{Brightness, Rgb565, WcRenderers}
  alias WorldCupTracker.Store

  @default_timezone "America/Denver"
  # Matches the Poller's "soon" window: a kickoff within 15 minutes.
  @soon_window_ms 15 * 60 * 1000
  # The goal-burst cadence from the design handoff (≈0.2–0.3s → ~3–5 fps):
  # the `:goal` board animates purely off `snap.now - goal_started_at`, so
  # fast polling is what plays the celebration on the device.
  @goal_burst_seconds 0.3

  plug(:match)
  plug(:dispatch)

  get "/matrix.rgb565" do
    conn = fetch_query_params(conn)
    snap = State.snapshot(snapshot_opts(conn))
    send_frame(conn, snap, {:corrected, brightness(conn.params, snap)})
  end

  get "/preview.rgb565" do
    conn = fetch_query_params(conn)
    send_frame(conn, State.snapshot(snapshot_opts(conn)), :raw)
  end

  get "/healthz" do
    body =
      Jason.encode!(%{
        matches_cached: length(Store.schedule()),
        live_count: length(Store.live_matches()),
        last_updated: Store.last_updated()
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  @doc """
  Adaptive poll cadence (seconds) for a display snapshot, sent as
  `X-Poll-Seconds`:

    * `:goal` → #{@goal_burst_seconds} — the goal-burst rate; the device
      replays the celebration by polling fast for ~16.5s
    * `:live`, or a Now & Next board with live/halftime rows → 15
    * Now & Next with a kickoff within 15 minutes → 30
    * otherwise → 60
  """
  @spec poll_seconds(State.snapshot()) :: number()
  def poll_seconds(%{state: :goal}), do: @goal_burst_seconds
  def poll_seconds(%{state: :live}), do: 15
  def poll_seconds(%{state: :now_next, live: [_ | _]}), do: 15

  def poll_seconds(%{state: :now_next, next: next, now: now}) do
    soon? =
      Enum.any?(next, fn %{kickoff_utc: kickoff} ->
        is_integer(kickoff) and kickoff - now <= @soon_window_ms
      end)

    if soon?, do: 30, else: 60
  end

  ## Internals

  defp send_frame(conn, snap, mode) do
    body = snap |> WcRenderers.render() |> Rgb565.encode(mode)
    etag = ~s("#{Base.encode16(:erlang.md5(body), case: :lower)}")

    # Headers go on both branches: a 304 must still carry X-Poll-Seconds so
    # the device keeps its adaptive cadence on unchanged frames.
    conn =
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_header("x-display-state", to_string(snap.state))
      |> put_resp_header("x-display-width", "128")
      |> put_resp_header("x-display-height", "64")
      |> put_resp_header("x-poll-seconds", to_string(poll_seconds(snap)))
      |> put_resp_header("cache-control", "no-store")

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_content_type("application/octet-stream")
      |> send_resp(200, body)
    end
  end

  defp snapshot_opts(conn) do
    case Integer.parse(conn.params["now"] || "") do
      {ms, ""} -> [now: ms]
      _ -> []
    end
  end

  # `?b=` manual brightness override (the device's button control); absent or
  # out of range → the time-of-day curve for the configured display timezone.
  defp brightness(params, snap) do
    case Float.parse(params["b"] || "") do
      {f, _} when f >= 0.0 and f <= 1.0 ->
        f

      _ ->
        tz = Application.get_env(:world_cup_tracker, :timezone, @default_timezone)
        Brightness.for_zone(tz, snap.now)
    end
  end
end
