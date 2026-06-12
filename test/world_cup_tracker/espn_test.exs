defmodule WorldCupTracker.EspnTest do
  use ExUnit.Case, async: true

  alias WorldCupTracker.{Espn, Match}

  defp fixture(name) do
    [__DIR__, "..", "fixtures", name]
    |> Path.join()
    |> File.read!()
    |> JSON.decode!()
  end

  describe "parse_scoreboard/1 (finished fixture)" do
    setup do
      %{matches: Espn.parse_scoreboard(fixture("espn_scoreboard_finished.json"))}
    end

    test "parses the finished Mexico vs South Africa match", %{matches: matches} do
      match = Enum.find(matches, &(&1.home.name == "Mexico"))

      assert %Match{source: :espn, id: "760415"} = match
      assert match.state == :finished
      assert match.clock == "90'+8'"
      assert match.detail == "FT"
      assert match.kickoff == ~U[2026-06-11 19:00:00Z]
      assert match.home == %{name: "Mexico", abbrev: "MEX", score: 2}
      assert match.away == %{name: "South Africa", abbrev: "RSA", score: 0}
    end

    test "parses both finished matches", %{matches: matches} do
      assert length(matches) == 2
      assert Enum.all?(matches, &(&1.state == :finished))

      korea = Enum.find(matches, &(&1.home.name == "South Korea"))
      assert korea.home.score == 2
      assert korea.away.name == "Czechia"
      assert korea.away.score == 1
    end
  end

  describe "parse_scoreboard/1 (range fixture)" do
    setup do
      %{matches: Espn.parse_scoreboard(fixture("espn_scoreboard_range.json"))}
    end

    test "knockout placeholders parse as scheduled with nil scores", %{matches: matches} do
      final = Enum.find(matches, &(&1.id == "760517"))

      assert final.state == :scheduled
      assert final.home.score == nil
      assert final.away.score == nil
      assert final.clock == nil
      assert final.home.name == "Semifinal 1 Winner"
      assert final.away.name == "Semifinal 2 Winner"
      assert final.round == "Final"
    end

    test "matches are sorted by kickoff", %{matches: matches} do
      kickoffs = Enum.map(matches, & &1.kickoff)
      assert kickoffs == Enum.sort(kickoffs, DateTime)
      assert length(matches) == 6
    end
  end

  describe "parse_summary/1" do
    test "includes the Quiñones goal and skips empty-text key events" do
      %{events: events} = Espn.parse_summary(fixture("espn_summary_finished.json"))

      goal =
        Enum.find(events, fn event ->
          event.type == "Goal" and String.contains?(event.text, "Julián Quiñones")
        end)

      assert goal.minute == "9'"
      assert Enum.all?(events, &(is_binary(&1.text) and &1.text != ""))
    end
  end

  describe "parse_standings/1" do
    test "parses all 12 groups with Mexico leading Group A" do
      groups = Espn.parse_standings(fixture("espn_standings.json"))

      assert length(groups) == 12

      group_a = Enum.find(groups, &(&1.name == "Group A"))
      mexico = Enum.find(group_a.entries, &(&1.team == "Mexico"))

      assert mexico.played == 1
      assert mexico.wins == 1
      assert mexico.draws == 0
      assert mexico.losses == 0
      assert mexico.goal_diff == 2
      assert mexico.points == 3
    end
  end

  describe "state_from_status/1" do
    test "in + Halftime detail maps to :halftime" do
      status = %{"type" => %{"state" => "in", "detail" => "Halftime"}}
      assert Espn.state_from_status(status) == :halftime
    end

    test "halftime detection is case-insensitive contains" do
      status = %{"type" => %{"state" => "in", "detail" => "HALFTIME"}}
      assert Espn.state_from_status(status) == :halftime
    end

    test "in with a normal clock detail maps to :live" do
      status = %{"type" => %{"state" => "in", "detail" => "67'"}}
      assert Espn.state_from_status(status) == :live
    end

    test "pre maps to :scheduled and post maps to :finished" do
      assert Espn.state_from_status(%{"type" => %{"state" => "pre", "detail" => "Sat"}}) ==
               :scheduled

      assert Espn.state_from_status(%{"type" => %{"state" => "post", "detail" => "FT"}}) ==
               :finished
    end
  end
end
