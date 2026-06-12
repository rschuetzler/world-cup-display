defmodule WorldCupTracker.Web.RouterTest do
  # async: false — the Router reads the globally named WorldCupTracker.Store
  # (State.snapshot/1 default), so these tests seed and restart that shared
  # store and must not run alongside anything else touching it.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias WorldCupTracker.{Match, Store}
  alias WorldCupTracker.Web.Router

  @opts Router.init([])
  @frame_bytes 128 * 64 * 2
  # A fixed snapshot clock (via ?now=) keeps frames byte-identical across
  # requests — the Now & Next board has a 600ms blink dot driven by snap.now.
  @now DateTime.to_unix(~U[2026-06-12 19:00:00Z], :millisecond)
  @min_ms 60_000

  setup do
    # Restart the app's Store so every test starts from an empty table.
    :ok = Supervisor.terminate_child(WorldCupTracker.Supervisor, WorldCupTracker.Store)
    {:ok, _} = Supervisor.restart_child(WorldCupTracker.Supervisor, WorldCupTracker.Store)
    :ok
  end

  defp build_match(id, opts) do
    %Match{
      source: :espn,
      id: id,
      kickoff: Keyword.get(opts, :kickoff, DateTime.utc_now()),
      round: "Group Stage",
      home: %{name: "Canada", abbrev: "CAN", score: Keyword.get(opts, :home_score)},
      away: %{name: "Bosnia", abbrev: "BIH", score: Keyword.get(opts, :away_score)},
      state: Keyword.get(opts, :state, :scheduled),
      clock: Keyword.get(opts, :clock)
    }
  end

  defp in_minutes(minutes), do: DateTime.add(DateTime.utc_now(), minutes * 60, :second)

  defp request(path, headers \\ []) do
    headers
    |> Enum.reduce(conn(:get, path), fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> Router.call(@opts)
  end

  defp header(conn, name) do
    case get_resp_header(conn, name) do
      [value] -> value
      [] -> nil
    end
  end

  describe "GET /matrix.rgb565" do
    test "serves a 16384-byte device frame with the protocol headers" do
      :ok =
        Store.put_today(WorldCupTracker.Store, [
          build_match("1",
            state: :live,
            home_score: 1,
            away_score: 0,
            clock: "23'",
            kickoff: in_minutes(-23)
          )
        ])

      conn = request("/matrix.rgb565")

      assert conn.status == 200
      assert byte_size(conn.resp_body) == @frame_bytes
      assert header(conn, "content-type") =~ "application/octet-stream"
      assert header(conn, "x-display-state") == "live"
      assert header(conn, "x-display-width") == "128"
      assert header(conn, "x-display-height") == "64"
      assert header(conn, "x-poll-seconds") == "15"
      assert header(conn, "cache-control") == "no-store"
      assert header(conn, "etag") =~ ~r/^"[0-9a-f]{32}"$/
    end

    test "returns the same ETag for identical state, and 304 on If-None-Match" do
      :ok =
        Store.put_schedule(WorldCupTracker.Store, [
          build_match("1", kickoff: in_minutes(120)),
          build_match("2", kickoff: in_minutes(300))
        ])

      first = request("/matrix.rgb565?now=#{@now}")
      etag = header(first, "etag")
      assert first.status == 200

      second = request("/matrix.rgb565?now=#{@now}")
      assert header(second, "etag") == etag

      cached = request("/matrix.rgb565?now=#{@now}", [{"if-none-match", etag}])
      assert cached.status == 304
      assert cached.resp_body == ""
      # A 304 still carries the cadence so the device keeps adapting.
      assert header(cached, "x-poll-seconds") == header(first, "x-poll-seconds")
      assert header(cached, "etag") == etag
    end

    test "a fresh goal switches to the burst cadence" do
      live = [state: :live, clock: "23'", kickoff: in_minutes(-23)]

      :ok =
        Store.put_today(WorldCupTracker.Store, [
          build_match("1", live ++ [home_score: 0, away_score: 0])
        ])

      :ok =
        Store.put_today(WorldCupTracker.Store, [
          build_match("1", live ++ [home_score: 1, away_score: 0])
        ])

      conn = request("/matrix.rgb565")

      assert conn.status == 200
      assert header(conn, "x-display-state") == "goal"
      assert header(conn, "x-poll-seconds") == "0.3"
    end
  end

  describe "GET /preview.rgb565" do
    test "serves the raw-encoded frame" do
      :ok =
        Store.put_today(WorldCupTracker.Store, [
          build_match("1",
            state: :live,
            home_score: 2,
            away_score: 1,
            clock: "78'",
            kickoff: in_minutes(-78)
          )
        ])

      preview = request("/preview.rgb565?now=#{@now}")
      device = request("/matrix.rgb565?now=#{@now}")

      assert preview.status == 200
      assert byte_size(preview.resp_body) == @frame_bytes
      assert header(preview, "x-poll-seconds") == "15"
      # Device encode bakes gamma/brightness; preview is raw sRGB.
      assert preview.resp_body != device.resp_body
    end
  end

  describe "poll_seconds/1" do
    test "goal state polls at the burst rate" do
      assert Router.poll_seconds(%{state: :goal}) == 0.3
    end

    test "a live match polls every 15s" do
      assert Router.poll_seconds(%{state: :live}) == 15

      assert Router.poll_seconds(%{state: :now_next, now: @now, live: [%{ht: true}], next: []}) ==
               15
    end

    test "a kickoff within 15 minutes polls every 30s" do
      snap = %{
        state: :now_next,
        now: @now,
        live: [],
        next: [%{kickoff_utc: @now + 10 * @min_ms}]
      }

      assert Router.poll_seconds(snap) == 30
    end

    test "idle polls every 60s" do
      far = %{state: :now_next, now: @now, live: [], next: [%{kickoff_utc: @now + 16 * @min_ms}]}
      empty = %{state: :now_next, now: @now, live: [], next: []}

      assert Router.poll_seconds(far) == 60
      assert Router.poll_seconds(empty) == 60
    end
  end

  describe "GET /healthz" do
    test "reports store counts and freshness" do
      :ok =
        Store.put_today(WorldCupTracker.Store, [
          build_match("1", state: :live, home_score: 0, away_score: 0, clock: "5'"),
          build_match("2", kickoff: in_minutes(180))
        ])

      conn = request("/healthz")

      assert conn.status == 200
      assert header(conn, "content-type") =~ "application/json"

      assert %{
               "matches_cached" => 2,
               "live_count" => 1,
               "last_updated" => %{"today" => today, "schedule" => nil, "standings" => nil}
             } = Jason.decode!(conn.resp_body)

      assert {:ok, _dt, _offset} = DateTime.from_iso8601(today)
    end
  end

  test "unknown paths 404" do
    assert request("/nope").status == 404
  end
end
