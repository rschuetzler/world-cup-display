defmodule WorldCupTracker.Display.StateTest do
  use ExUnit.Case, async: true

  alias WorldCupTracker.Display.State
  alias WorldCupTracker.Matrix.{Rgb565, WcRenderers}
  alias WorldCupTracker.{Match, Store}

  @now DateTime.to_unix(~U[2026-06-12 19:00:00Z], :millisecond)
  @frame_bytes 128 * 64 * 2

  defp build_match(id, opts \\ []) do
    home = Keyword.get(opts, :home, %{name: "United States", abbrev: "USA", score: nil})
    away = Keyword.get(opts, :away, %{name: "Mexico", abbrev: "MEX", score: nil})

    %Match{
      source: :espn,
      id: id,
      kickoff: Keyword.get(opts, :kickoff, ~U[2026-06-12 17:42:00Z]),
      round: Keyword.get(opts, :round, "Group Stage"),
      home: home,
      away: away,
      state: Keyword.get(opts, :state, :live),
      clock: Keyword.get(opts, :clock, "78'")
    }
  end

  defp side(name, abbrev, score \\ nil), do: %{name: name, abbrev: abbrev, score: score}

  defp goal_event(match, team, at) do
    %{match_id: match.id, team: team, match: match, at: at}
  end

  defp finished_entry(match, at), do: %{match: match, finished_at: at}

  defp start_store do
    name = :"display_state_test_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: name})
    name
  end

  defp in_minutes(minutes), do: DateTime.add(DateTime.utc_now(), minutes * 60, :second)

  defp assert_renders(snap) do
    assert snap |> WcRenderers.render() |> Rgb565.encode(:raw) |> byte_size() == @frame_bytes
  end

  describe "choose/5" do
    test "a fresh goal event beats the live board" do
      match = build_match("1")
      event = goal_event(match, :away, ~U[2026-06-12 18:59:55Z])

      assert {:goal, ^event} = State.choose([match], [event], [], @now)
    end

    test "the most recent fresh goal event wins" do
      match = build_match("1")
      older = goal_event(match, :home, ~U[2026-06-12 18:59:50Z])
      newer = goal_event(match, :away, ~U[2026-06-12 18:59:55Z])

      assert {:goal, ^newer} = State.choose([match], [newer, older], [], @now)
    end

    test "a goal event older than goal_duration_ms is ignored" do
      match = build_match("1")
      event = goal_event(match, :away, ~U[2026-06-12 18:59:43Z])

      assert {:live, ^match} = State.choose([match], [event], [], @now)
      assert {:goal, ^event} = State.choose([match], [event], [], @now, goal_duration_ms: 60_000)
    end

    test "a goal event whose match is no longer in play is ignored" do
      live = build_match("1")
      finished = build_match("2", state: :finished)
      event = goal_event(finished, :home, ~U[2026-06-12 18:59:55Z])

      assert {:live, ^live} = State.choose([live], [event], [], @now)
    end

    test "exactly one live match goes to the live board" do
      match = build_match("1")
      assert {:live, ^match} = State.choose([match], [], [], @now)
    end

    test "with two live matches, the one with a followed team wins the live board" do
      other = build_match("1", home: side("Canada", "CAN", 0), away: side("Bosnia", "BIH", 0))
      usa = build_match("2")

      assert {:live, ^usa} = State.choose([other, usa], [], [], @now)
      assert {:live, ^other} = State.choose([other, usa], [], [], @now, followed_teams: ["CAN"])
    end

    test "two live matches with no followed team go to now & next" do
      a = build_match("1", home: side("Canada", "CAN", 0), away: side("Bosnia", "BIH", 0))
      b = build_match("2", home: side("Brazil", "BRA", 1), away: side("Spain", "ESP", 1))

      assert State.choose([a, b], [], [], @now) == :now_next
    end

    test "no live matches goes to now & next" do
      assert State.choose([], [], [], @now) == :now_next
    end
  end

  describe "choose/5 final hold" do
    test "with nothing live, a recent final holds the board" do
      match = build_match("1", state: :finished, clock: "FT")
      entry = finished_entry(match, ~U[2026-06-12 18:50:00Z])

      assert {:final, ^match} = State.choose([], [], [entry], @now)
    end

    test "the most recently finished match wins" do
      older = build_match("1", state: :finished, clock: "FT")
      newer = build_match("2", state: :finished, clock: "FT")

      entries = [
        finished_entry(older, ~U[2026-06-12 18:45:00Z]),
        finished_entry(newer, ~U[2026-06-12 18:55:00Z])
      ]

      assert {:final, ^newer} = State.choose([], [], entries, @now)
    end

    test "a live match beats a recent final" do
      live = build_match("1")
      final = build_match("2", state: :finished, clock: "FT")
      entry = finished_entry(final, ~U[2026-06-12 18:55:00Z])

      assert {:live, ^live} = State.choose([live], [], [entry], @now)
    end

    test "a fresh goal beats a live match and a recent final" do
      live = build_match("1")
      event = goal_event(live, :home, ~U[2026-06-12 18:59:55Z])
      final = build_match("2", state: :finished, clock: "FT")
      entry = finished_entry(final, ~U[2026-06-12 18:55:00Z])

      assert {:goal, ^event} = State.choose([live], [event], [entry], @now)
    end

    test "a final older than final_hold_ms goes to now & next" do
      match = build_match("1", state: :finished, clock: "FT")
      # 30 minutes ago — outside the default 20-minute hold.
      entry = finished_entry(match, ~U[2026-06-12 18:30:00Z])

      assert State.choose([], [], [entry], @now) == :now_next
      assert {:final, ^match} = State.choose([], [], [entry], @now, final_hold_ms: 60 * 60_000)
    end
  end

  describe "parse_minute/1" do
    test "parses plain and stoppage-time clocks to the base minute" do
      assert State.parse_minute("78'") == 78
      assert State.parse_minute("45'+2'") == 45
      assert State.parse_minute("90'+8'") == 90
      assert State.parse_minute("1'") == 1
    end

    test "nil and unparseable clocks are 0" do
      assert State.parse_minute(nil) == 0
      assert State.parse_minute("HT") == 0
      assert State.parse_minute("") == 0
      assert State.parse_minute("FT") == 0
    end
  end

  describe "stage_label/2" do
    @standings [
      %{
        name: "Group A",
        entries: [%{team: "Canada", abbrev: "CAN"}, %{team: "Bosnia", abbrev: "BIH"}]
      },
      %{
        name: "Group D",
        entries: [%{team: "United States", abbrev: "USA"}, %{team: "Mexico", abbrev: "MEX"}]
      }
    ]

    test "looks up the group letter from the standings for group-stage matches" do
      assert State.stage_label(build_match("1"), @standings) == "GROUP D"

      can = build_match("2", home: side("Canada", "CAN"), away: side("Bosnia", "BIH"))
      assert State.stage_label(can, @standings) == "GROUP A"
    end

    test "matches by name when a side has no abbrev" do
      match = build_match("1", home: side("United States", nil), away: side("Mexico", nil))
      assert State.stage_label(match, @standings) == "GROUP D"
    end

    test "falls back to the upcased round when the standings don't know the teams" do
      match = build_match("1", home: side("Japan", "JPN"), away: side("Ghana", "GHA"))
      assert State.stage_label(match, @standings) == "GROUP STAGE"
      assert State.stage_label(match, []) == "GROUP STAGE"
    end

    test "knockout rounds skip the lookup and upcase the round" do
      match = build_match("1", round: "Semifinals")
      assert State.stage_label(match, @standings) == "SEMIFINALS"
    end

    test "a nil round yields the empty string" do
      match = build_match("1", round: nil)
      assert State.stage_label(match, @standings) == ""
    end
  end

  describe "snapshot/1 integration" do
    test "no live matches: now & next with empty live and the next 3 kickoffs" do
      store = start_store()

      :ok =
        Store.put_schedule(store, [
          build_match("1", state: :scheduled, clock: nil, kickoff: in_minutes(60)),
          build_match("2",
            state: :scheduled,
            clock: nil,
            kickoff: in_minutes(180),
            home: side("Brazil", "BRA"),
            away: side("Spain", "ESP")
          ),
          build_match("3",
            state: :scheduled,
            clock: nil,
            kickoff: in_minutes(300),
            home: side("England", "ENG"),
            away: side("France", "FRA")
          ),
          build_match("4", state: :scheduled, clock: nil, kickoff: in_minutes(400))
        ])

      now = System.system_time(:millisecond)
      snap = State.snapshot(store: store, now: now)

      assert %{state: :now_next, now: ^now, tz: "America/Denver", live: []} = snap

      assert [
               %{home: "USA", away: "MEX"},
               %{home: "BRA", away: "ESP"},
               %{home: "ENG", away: "FRA"}
             ] = snap.next

      assert Enum.all?(snap.next, &(is_integer(&1.kickoff_utc) and &1.tz == "America/Denver"))

      assert_renders(snap)
    end

    test "two unfollowed live matches: now & next with live rows" do
      store = start_store()

      :ok =
        Store.put_schedule(store, [
          build_match("1",
            home: side("Canada", "CAN", 2),
            away: side("Bosnia", "BIH", 1),
            kickoff: in_minutes(-78)
          ),
          build_match("2",
            state: :halftime,
            clock: "45'",
            home: side("Brazil", "BRA", 0),
            away: side("Spain", "ESP", nil),
            kickoff: in_minutes(-50)
          ),
          build_match("3", state: :scheduled, clock: nil, kickoff: in_minutes(120))
        ])

      now = System.system_time(:millisecond)
      snap = State.snapshot(store: store, now: now)

      assert %{state: :now_next, live: live_rows} = snap

      assert [
               %{home: "CAN", away: "BIH", hs: 2, as: 1, ht: false},
               %{home: "BRA", away: "ESP", hs: 0, as: 0, ht: true}
             ] = live_rows

      assert [%{home: "USA", away: "MEX"}] = snap.next

      assert_renders(snap)
    end

    test "one live match: the live board with minute, codes and stage" do
      store = start_store()

      :ok =
        Store.put_schedule(store, [
          build_match("1",
            home: side("United States", "USA", 2),
            away: side("Mexico", "MEX", 1),
            kickoff: in_minutes(-78)
          ),
          build_match("2", state: :scheduled, clock: nil, kickoff: in_minutes(120))
        ])

      :ok =
        Store.put_standings(store, [
          %{name: "Group D", entries: [%{team: "United States", abbrev: "USA"}]}
        ])

      now = System.system_time(:millisecond)
      snap = State.snapshot(store: store, now: now)

      assert %{
               state: :live,
               now: ^now,
               minute: 78,
               hs: 2,
               as: 1,
               match: %{
                 stage: "GROUP D",
                 home: "USA",
                 away: "MEX",
                 venue: "",
                 tz: "America/Denver"
               }
             } = snap

      assert is_integer(snap.match.kickoff_utc)

      assert_renders(snap)
    end

    test "a store-detected goal produces the goal board" do
      store = start_store()

      :ok =
        Store.put_schedule(store, [
          build_match("1",
            home: side("United States", "USA", 1),
            away: side("Mexico", "MEX", 1),
            kickoff: in_minutes(-78)
          )
        ])

      :ok =
        Store.put_today(store, [
          build_match("1",
            home: side("United States", "USA", 1),
            away: side("Mexico", "MEX", 2),
            kickoff: in_minutes(-78)
          )
        ])

      now = System.system_time(:millisecond)
      snap = State.snapshot(store: store, now: now)

      assert %{state: :goal, team: :away, code: "MEX", hs: 1, as: 2} = snap
      assert is_integer(snap.goal_started_at)
      assert now - snap.goal_started_at < 5_000
      assert %{home: "USA", away: "MEX"} = snap.match

      assert_renders(snap)
      # Mid-celebration frames render too (phase B and C are time-dependent).
      assert_renders(%{snap | now: snap.goal_started_at + 5_000})
      assert_renders(%{snap | now: snap.goal_started_at + 14_000})
    end

    test "a just-finished match holds the live board with final: true" do
      store = start_store()

      :ok =
        Store.put_today(store, [
          build_match("1",
            home: side("United States", "USA", 2),
            away: side("Mexico", "MEX", 1),
            kickoff: in_minutes(-110)
          )
        ])

      :ok =
        Store.put_today(store, [
          build_match("1",
            state: :finished,
            clock: "FT",
            home: side("United States", "USA", 2),
            away: side("Mexico", "MEX", 1),
            kickoff: in_minutes(-110)
          )
        ])

      now = System.system_time(:millisecond)
      snap = State.snapshot(store: store, now: now)

      assert %{
               state: :live,
               final: true,
               now: ^now,
               hs: 2,
               as: 1,
               match: %{home: "USA", away: "MEX"}
             } = snap

      # "FT" parses to minute 0; the renderer ignores the minute when final.
      assert snap.minute == 0

      assert_renders(snap)
    end

    test "an expired final hold falls back to now & next" do
      store = start_store()

      :ok =
        Store.put_today(store, [
          build_match("1",
            home: side("United States", "USA", 2),
            away: side("Mexico", "MEX", 1),
            kickoff: in_minutes(-110)
          )
        ])

      :ok =
        Store.put_today(store, [
          build_match("1",
            state: :finished,
            clock: "FT",
            home: side("United States", "USA", 2),
            away: side("Mexico", "MEX", 1),
            kickoff: in_minutes(-110)
          )
        ])

      Process.sleep(15)
      now = System.system_time(:millisecond)

      assert %{state: :live, final: true} = State.snapshot(store: store, now: now)
      assert %{state: :now_next} = State.snapshot(store: store, now: now, final_hold_ms: 5)
    end

    test "nil abbrevs fall back to the first three letters of the name" do
      store = start_store()

      :ok =
        Store.put_schedule(store, [
          build_match("1",
            round: "Semifinals",
            home: side("Winner Match 57", nil, 0),
            away: side("Winner Match 58", nil, 0),
            kickoff: in_minutes(-10),
            clock: "10'"
          )
        ])

      snap = State.snapshot(store: store, now: System.system_time(:millisecond))

      assert %{state: :live, match: %{stage: "SEMIFINALS", home: "WIN", away: "WIN"}} = snap
      assert_renders(snap)
    end
  end
end
