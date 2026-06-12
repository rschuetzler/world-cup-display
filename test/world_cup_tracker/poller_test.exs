defmodule WorldCupTracker.PollerTest do
  # async: false — FakeSource keeps its canned responses in :persistent_term.
  use ExUnit.Case, async: false

  alias WorldCupTracker.{FakeSource, Match, Poller, Store}

  @intervals [live_interval: 11, soon_interval: 22, idle_interval: 33]

  setup do
    store = :"poller_test_store_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: store})
    {:ok, store: store}
  end

  defp start_poller(store, opts \\ []) do
    name = :"poller_test_#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      store: store,
      source: FakeSource,
      poll_on_start?: true,
      # Long intervals so timers never fire mid-test.
      live_interval: 60_000,
      soon_interval: 60_000,
      idle_interval: 60_000,
      schedule_interval: 3_600_000
    ]

    start_supervised!({Poller, Keyword.merge(defaults, opts)})
    name
  end

  defp build_match(id, opts) do
    %Match{
      source: :espn,
      id: id,
      kickoff: Keyword.get(opts, :kickoff, ~U[2026-06-12 19:00:00Z]),
      home: %{name: "USA", abbrev: "USA", score: Keyword.get(opts, :home_score)},
      away: %{name: "Paraguay", abbrev: "PAR", score: Keyword.get(opts, :away_score)},
      state: Keyword.get(opts, :state, :scheduled)
    }
  end

  defp in_minutes(minutes), do: DateTime.add(DateTime.utc_now(), minutes * 60, :second)
  defp seconds_ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  describe "startup" do
    test "fetches schedule, standings, and today's scoreboard into the store", %{store: store} do
      groups = [%{name: "Group A", entries: []}]

      FakeSource.configure(
        scoreboard: {:ok, [build_match("100", kickoff: ~U[2026-06-13 19:00:00Z])]},
        standings: {:ok, groups},
        notify: self()
      )

      poller = start_poller(store)

      # Full-tournament range first, then standings, then today's window.
      assert_receive {FakeSource, {:scoreboard, "20260611-20260719"}}
      assert_receive {FakeSource, :standings}
      assert_receive {FakeSource, {:scoreboard, today_range}}
      assert today_range == Poller.today_range()
      assert today_range =~ ~r/^\d{8}-\d{8}$/

      # Sync with the poller, then read the store.
      assert is_integer(Poller.next_interval(poller))
      assert [%Match{id: "100"}] = Store.schedule(store)
      assert Store.standings(store) == groups

      assert %{schedule: %DateTime{}, today: %DateTime{}, standings: %DateTime{}} =
               Store.last_updated(store)
    end

    test "survives fetch errors: no crash, store keeps last-good (empty) data", %{store: store} do
      FakeSource.configure(
        scoreboard: {:error, :econnrefused},
        standings: {:error, {:status, 500}},
        notify: self()
      )

      poller = start_poller(store)

      assert_receive {FakeSource, {:scoreboard, "20260611-20260719"}}
      assert is_integer(Poller.next_interval(poller))
      assert Process.alive?(Process.whereis(poller))
      assert Store.schedule(store) == []
      assert Store.standings(store) == []
    end

    test "a failed poll does not clear previously stored data", %{store: store} do
      FakeSource.configure(
        scoreboard: {:ok, [build_match("100", state: :live, home_score: 0, away_score: 0)]},
        notify: self()
      )

      poller = start_poller(store)
      assert is_integer(Poller.next_interval(poller))
      assert [%Match{id: "100"}] = Store.schedule(store)

      FakeSource.configure(scoreboard: {:error, :timeout}, notify: self())
      assert :ok = Poller.force_poll(poller)
      assert [%Match{id: "100", state: :live}] = Store.schedule(store)
    end

    test "poll_on_start?: false starts inert and fetches nothing", %{store: store} do
      FakeSource.configure(scoreboard: {:ok, []}, notify: self())
      poller = start_poller(store, poll_on_start?: false)

      refute_receive {FakeSource, _}, 50
      assert Poller.next_interval(poller) == nil
      assert Store.schedule(store) == []
    end
  end

  describe "force_poll/1" do
    test "fetches today's scoreboard on demand", %{store: store} do
      FakeSource.configure(scoreboard: {:ok, []}, notify: self())
      poller = start_poller(store, poll_on_start?: false)

      assert :ok = Poller.force_poll(poller)
      assert_receive {FakeSource, {:scoreboard, range}}
      assert range == Poller.today_range()
      assert is_integer(Poller.next_interval(poller))
    end
  end

  describe "choose_interval/4 (pure cadence choice)" do
    test "live match selects live_interval" do
      matches = [build_match("1", state: :live, home_score: 0, away_score: 0)]
      assert Poller.choose_interval(matches, [], DateTime.utc_now(), @intervals) == 11
    end

    test "halftime match selects live_interval" do
      matches = [build_match("1", state: :halftime, home_score: 1, away_score: 0)]
      assert Poller.choose_interval(matches, [], DateTime.utc_now(), @intervals) == 11
    end

    test "scheduled match kicking off within 15 minutes selects soon_interval" do
      matches = [build_match("1", kickoff: in_minutes(10))]
      assert Poller.choose_interval(matches, [], DateTime.utc_now(), @intervals) == 22
    end

    test "scheduled match just past kickoff but not yet live selects soon_interval" do
      matches = [build_match("1", kickoff: in_minutes(-2))]
      assert Poller.choose_interval(matches, [], DateTime.utc_now(), @intervals) == 22
    end

    test "scheduled match more than 15 minutes out selects idle_interval" do
      matches = [build_match("1", kickoff: in_minutes(45))]
      assert Poller.choose_interval(matches, [], DateTime.utc_now(), @intervals) == 33
    end

    test "finished matches and empty schedule select idle_interval" do
      finished = [
        build_match("1",
          state: :finished,
          kickoff: in_minutes(-120),
          home_score: 2,
          away_score: 1
        )
      ]

      assert Poller.choose_interval(finished, [], DateTime.utc_now(), @intervals) == 33
      assert Poller.choose_interval([], [], DateTime.utc_now(), @intervals) == 33
    end

    test "a goal event within the last 20s holds live_interval even with no live match" do
      matches = [
        build_match("1",
          state: :finished,
          kickoff: in_minutes(-120),
          home_score: 1,
          away_score: 0
        )
      ]

      events = [%{match_id: "1", team: :home, at: seconds_ago(5)}]
      assert Poller.choose_interval(matches, events, DateTime.utc_now(), @intervals) == 11
    end

    test "a goal event older than 20s no longer forces live_interval" do
      events = [%{match_id: "1", team: :home, at: seconds_ago(30)}]
      assert Poller.choose_interval([], events, DateTime.utc_now(), @intervals) == 33
    end

    test "uses default intervals when none are given" do
      assert Poller.choose_interval([], [], DateTime.utc_now()) == 600_000
    end
  end

  describe "today_range/1" do
    test "covers yesterday through tomorrow in UTC" do
      assert Poller.today_range(~D[2026-06-12]) == "20260611-20260613"
      assert Poller.today_range(~D[2026-07-01]) == "20260630-20260702"
    end
  end
end
