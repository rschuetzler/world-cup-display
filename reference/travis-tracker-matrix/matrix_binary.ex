defmodule TravisTrackerWeb.MatrixBinary do
  @moduledoc "Shared response shaping for the RGB565 binary frame endpoints."
  import Plug.Conn

  # Adaptive poll cadence per state (seconds).
  @poll %{
    in_flight: 15,
    taxiing: 15,
    pre_flight: 15,
    alternating: 15,
    trip_pending: 30,
    layover: 30,
    idle: 60,
    post_flight: 30
  }

  @doc "Render+encode `snapshot` and send it, honoring If-None-Match (304)."
  def send_frame(conn, snapshot, opts) do
    bytes = TravisTracker.Matrix.to_rgb565(snapshot, opts)
    # Hash only the base 16 KB frame for ETag — the trailer may contain a live
    # clock anchor that changes every render, which would defeat caching.
    # Trade-off: a scroll strip that changes while the base frame is byte-identical
    # won't bust the cache until the base changes — rare, and self-heals next poll.
    etag_input = binary_part(bytes, 0, min(byte_size(bytes), 16_384))
    etag = "\"" <> Base.encode16(:crypto.hash(:sha256, etag_input), case: :lower) <> "\""
    # `:state` override lets the demo path report the cycled state even when a
    # fixture reuses another state's snapshot (the two post_flight-pill variants
    # render off :pre_flight/:layover, so their snapshot.state isn't the pill).
    state = opts[:state] || state_of(snapshot)
    poll = opts[:poll] || Map.get(@poll, state, 30)

    conn =
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_header("x-display-state", to_string(state))
      |> put_resp_header("x-display-width", "128")
      |> put_resp_header("x-display-height", "64")
      |> put_resp_header("x-poll-seconds", Integer.to_string(poll))
      |> put_resp_header("cache-control", "no-store")

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_content_type("application/octet-stream")
      |> send_resp(200, bytes)
    end
  end

  @doc "Parse an optional `?b=` brightness override into `to_rgb565` opts."
  def brightness_opt(%{"b" => s}) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> [brightness: f]
      :error -> []
    end
  end

  def brightness_opt(_params), do: []

  # the snapshot may be a fixture map (atom :state) or the live struct
  defp state_of(%{state: s}), do: s
end
