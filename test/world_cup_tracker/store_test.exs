defmodule WorldCupTracker.StoreTest do
  use ExUnit.Case, async: true

  alias WorldCupTracker.{Match, Store}

  defp start_store(opts \\ []) do
    name = :"store_test_#{System.unique_integer([:positive])}"
    start_supervised!({Store, Keyword.put(opts, :name, name)})
    name
  end

  defp build_match(id, opts \\ []) do
    %Match{
      source: :espn,
      id: id,
      kickoff: Keyword.get(opts, :kickoff, ~U[2026-06-12 19:00:00Z]),
      round: "Group Stage",
      home: %{name: "Canada", abbrev: "CAN", score: Keyword.get(opts, :home_score)},
      away: %{name: "Bosnia", abbrev: "BIH", score: Keyword.get(opts, :away_score)},
      state: Keyword.get(opts, :state, :scheduled),
      clock: Keyword.get(opts, :clock)
    }
  end

  defp in_minutes(minutes), do: DateTime.add(DateTime.utc_now(), minutes * 60, :second)

  describe "schedule/1" do
    test "returns matches sorted by kickoff" do
      store = start_store()

      :ok =
        Store.put_schedule(store, [
          build_match("3", kickoff: ~U[2026-06-14 01:00:00Z]),
          build_match("1", kickoff: ~U[2026-06-12 19:00:00Z]),
          build_match("2", kickoff: ~U[2026-06-12 22:00:00Z])
        ])

      assert ["1", "2", "3"] = store |> Store.schedule() |> Enum.map(& &1.id)
    end

    test "is empty before any put" do
      store = start_store()
      assert Store.schedule(store) == []
    end
  end

  describe "merge by id" do
    test "put_today overlays fresher data onto the schedule" do
      store = start_store()
      :ok = Store.put_schedule(store, [build_match("1"), build_match("2")])

      :ok =
        Store.put_today(store, [
          build_match("1", state: :live, home_score: 1, away_score: 0, clock: "23'")
        ])

      schedule = Store.schedule(store)
      assert length(schedule) == 2

      live = Enum.find(schedule, &(&1.id == "1"))
      assert live.state == :live
      assert live.home.score == 1
      assert live.clock == "23'"

      assert %Match{state: :scheduled} = Enum.find(schedule, &(&1.id == "2"))
    end
  end

  describe "live_matches/1" do
    test "returns only :live and :halftime matches" do
      store = start_store()

      :ok =
        Store.put_schedule(store, [
          build_match("1", state: :finished, home_score: 2, away_score: 1),
          build_match("2", state: :live, home_score: 0, away_score: 0),
          build_match("3", state: :halftime, home_score: 1, away_score: 0),
          build_match("4", state: :scheduled)
        ])

      assert ["2", "3"] = store |> Store.live_matches() |> Enum.map(& &1.id) |> Enum.sort()
    end
  end

  describe "next_matches/2" do
    test "returns the next n scheduled matches with kickoff at or after now" do
      store = start_store()

      :ok =
        Store.put_schedule(store, [
          build_match("past", kickoff: in_minutes(-90)),
          build_match("soon", kickoff: in_minutes(10)),
          build_match("later", kickoff: in_minutes(120)),
          build_match("tomorrow", kickoff: in_minutes(60 * 24)),
          build_match("live",
            state: :live,
            kickoff: in_minutes(-30),
            home_score: 0,
            away_score: 0
          )
        ])

      assert ["soon", "later", "tomorrow"] =
               store |> Store.next_matches(3) |> Enum.map(& &1.id)

      assert ["soon", "later"] = store |> Store.next_matches(2) |> Enum.map(& &1.id)
    end

    test "keeps a just-kicked-off match the feed still calls scheduled" do
      store = start_store()

      :ok =
        Store.put_schedule(store, [
          # Kicked off 2 min ago but ESPN/FIFA haven't flipped it to :live yet.
          build_match("kicking_off", kickoff: in_minutes(-2)),
          build_match("upcoming", kickoff: in_minutes(45)),
          # Past the grace window — a postponement shouldn't haunt the board.
          build_match("stale", kickoff: in_minutes(-30))
        ])

      assert ["kicking_off", "upcoming"] =
               store |> Store.next_matches(5) |> Enum.map(& &1.id)
    end
  end

  describe "standings" do
    test "put_standings stores and standings/1 reads" do
      store = start_store()
      groups = [%{name: "Group A", entries: []}]
      :ok = Store.put_standings(store, groups)
      assert Store.standings(store) == groups
    end
  end

  describe "goal events" do
    test "score increase on a live match fires an event with the right team" do
      store = start_store()
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 0, away_score: 0)])
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 1, away_score: 0)])

      assert [event] = Store.goal_events(store)
      assert event.match_id == "1"
      assert event.team == :home
      assert %Match{home: %{score: 1}} = event.match
      assert %DateTime{} = event.at
    end

    test "away score increase fires an :away event; both sides can fire at once" do
      store = start_store()
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 1, away_score: 1)])
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 2, away_score: 2)])

      assert [:away, :home] =
               store |> Store.goal_events() |> Enum.map(& &1.team) |> Enum.sort()
    end

    test "nil -> 0 (score appearing) is not a goal" do
      store = start_store()
      :ok = Store.put_today(store, [build_match("1", state: :scheduled)])
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 0, away_score: 0)])

      assert Store.goal_events(store) == []
    end

    test "first sight of a match never fires, even with a nonzero score" do
      store = start_store()
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 2, away_score: 0)])

      assert Store.goal_events(store) == []
    end

    test "repeat put with the same score does not re-fire" do
      store = start_store()
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 0, away_score: 0)])
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 1, away_score: 0)])
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 1, away_score: 0)])

      assert [%{team: :home}] = Store.goal_events(store)
    end

    test "score increase on a finished match does not fire" do
      store = start_store()
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 0, away_score: 0)])

      :ok =
        Store.put_today(store, [build_match("1", state: :finished, home_score: 1, away_score: 0)])

      assert Store.goal_events(store) == []
    end

    test "put_schedule also edge-detects goals" do
      store = start_store()
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 0, away_score: 0)])

      :ok =
        Store.put_schedule(store, [build_match("1", state: :live, home_score: 0, away_score: 1)])

      assert [%{team: :away}] = Store.goal_events(store)
    end

    test "events are pruned after the retention window" do
      store = start_store(goal_retention_ms: 30)
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 0, away_score: 0)])
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 1, away_score: 0)])

      assert [_event] = Store.goal_events(store)

      Process.sleep(50)
      assert Store.goal_events(store) == []

      # A write also physically prunes expired events.
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 1, away_score: 0)])
      assert Store.goal_events(store) == []
    end
  end

  describe "recently_finished/2" do
    @hold_ms 20 * 60_000

    test "a live -> finished transition records finished_at" do
      store = start_store()
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 2, away_score: 1)])

      :ok =
        Store.put_today(store, [build_match("1", state: :finished, home_score: 2, away_score: 1)])

      assert [%{match: %Match{id: "1", state: :finished}, finished_at: %DateTime{}}] =
               Store.recently_finished(store, @hold_ms)
    end

    test "a halftime -> finished transition also counts" do
      store = start_store()

      :ok =
        Store.put_today(store, [build_match("1", state: :halftime, home_score: 0, away_score: 0)])

      :ok =
        Store.put_today(store, [build_match("1", state: :finished, home_score: 0, away_score: 0)])

      assert [%{match: %Match{id: "1"}}] = Store.recently_finished(store, @hold_ms)
    end

    test "a match first seen as :finished gets no finished_at" do
      store = start_store()

      :ok =
        Store.put_schedule(store, [
          build_match("1", state: :finished, home_score: 2, away_score: 1)
        ])

      assert Store.recently_finished(store, @hold_ms) == []
    end

    test "repeated finished puts neither duplicate nor refresh the timestamp" do
      store = start_store()
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 1, away_score: 0)])

      :ok =
        Store.put_today(store, [build_match("1", state: :finished, home_score: 1, away_score: 0)])

      assert [%{finished_at: at}] = Store.recently_finished(store, @hold_ms)

      Process.sleep(15)

      :ok =
        Store.put_today(store, [build_match("1", state: :finished, home_score: 1, away_score: 0)])

      assert [%{finished_at: ^at}] = Store.recently_finished(store, @hold_ms)
    end

    test "within_ms filters out older transitions" do
      store = start_store()
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 0, away_score: 0)])

      :ok =
        Store.put_today(store, [build_match("1", state: :finished, home_score: 0, away_score: 0)])

      Process.sleep(20)
      assert Store.recently_finished(store, 5) == []
      assert [%{match: %Match{id: "1"}}] = Store.recently_finished(store, @hold_ms)
    end

    test "entries come back most recently finished first" do
      store = start_store()

      :ok =
        Store.put_today(store, [
          build_match("1", state: :live, home_score: 0, away_score: 0),
          build_match("2", state: :live, home_score: 0, away_score: 0)
        ])

      :ok =
        Store.put_today(store, [build_match("1", state: :finished, home_score: 0, away_score: 0)])

      Process.sleep(15)

      :ok =
        Store.put_today(store, [build_match("2", state: :finished, home_score: 0, away_score: 0)])

      assert ["2", "1"] =
               store |> Store.recently_finished(@hold_ms) |> Enum.map(& &1.match.id)
    end

    test "the returned match is the current stored match, not the transition-time one" do
      store = start_store()
      :ok = Store.put_today(store, [build_match("1", state: :live, home_score: 1, away_score: 0)])

      :ok =
        Store.put_today(store, [build_match("1", state: :finished, home_score: 1, away_score: 0)])

      assert [%{finished_at: at}] = Store.recently_finished(store, @hold_ms)

      # A later correction merges through without re-recording the transition.
      :ok =
        Store.put_today(store, [build_match("1", state: :finished, home_score: 2, away_score: 0)])

      assert [%{match: %Match{home: %{score: 2}}, finished_at: ^at}] =
               Store.recently_finished(store, @hold_ms)
    end
  end

  describe "last_updated/1" do
    test "is all nil before any writes" do
      store = start_store()
      assert %{schedule: nil, today: nil, standings: nil} = Store.last_updated(store)
    end

    test "tracks each kind independently" do
      store = start_store()
      :ok = Store.put_schedule(store, [build_match("1")])
      assert %{schedule: %DateTime{}, today: nil, standings: nil} = Store.last_updated(store)

      :ok = Store.put_today(store, [build_match("1")])
      :ok = Store.put_standings(store, [])

      assert %{schedule: %DateTime{}, today: %DateTime{}, standings: %DateTime{}} =
               Store.last_updated(store)
    end
  end
end
