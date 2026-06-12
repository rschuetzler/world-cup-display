defmodule WorldCupTracker.FifaTest do
  use ExUnit.Case, async: true

  alias WorldCupTracker.{Fifa, Match}

  defp fixture(name) do
    [__DIR__, "..", "fixtures", name]
    |> Path.join()
    |> File.read!()
    |> JSON.decode!()
  end

  describe "parse_calendar/1" do
    setup do
      %{matches: Fifa.parse_calendar(fixture("fifa_calendar.json"))}
    end

    test "parses all 104 matches sorted by kickoff", %{matches: matches} do
      assert length(matches) == 104

      kickoffs = Enum.map(matches, & &1.kickoff)
      assert Enum.all?(kickoffs, &match?(%DateTime{}, &1))
      assert kickoffs == Enum.sort(kickoffs, DateTime)
    end

    test "parses the finished Mexico vs South Africa match", %{matches: matches} do
      match = Enum.find(matches, &(&1.home.name == "Mexico"))

      assert %Match{source: :fifa, id: "400021443"} = match
      assert match.state == :finished
      assert match.clock == "98'"
      assert match.detail == nil
      assert match.round == "Group A"
      assert match.kickoff == ~U[2026-06-11 19:00:00Z]
      assert match.home == %{name: "Mexico", abbrev: "MEX", score: 2}
      assert match.away == %{name: "South Africa", abbrev: "RSA", score: 0}
    end

    test "parses the finished Korea Republic vs Czechia match", %{matches: matches} do
      match = Enum.find(matches, &(&1.home.name == "Korea Republic"))

      assert match.state == :finished
      assert match.home.score == 2
      assert match.away == %{name: "Czechia", abbrev: "CZE", score: 1}
    end

    test "parses an upcoming group-stage match as scheduled", %{matches: matches} do
      match = Enum.find(matches, &(&1.id == "400021449"))

      assert match.state == :scheduled
      assert match.round == "Group B"
      assert match.home.score == nil
      assert match.away.score == nil
      assert match.clock == nil
    end

    test "parses a knockout placeholder match without crashing", %{matches: matches} do
      match = Enum.find(matches, &(&1.id == "400021518"))

      assert match.state == :scheduled
      assert match.round == "Round of 32"
      assert match.home == %{name: "2A", abbrev: nil, score: nil}
      assert match.away == %{name: "2B", abbrev: nil, score: nil}
    end
  end

  describe "parse_live/1" do
    test "keeps only World Cup matches and reuses the match parser" do
      world_cup_match = %{
        "IdCompetition" => "17",
        "IdMatch" => "400021443",
        "Date" => "2026-06-11T19:00:00Z",
        "MatchStatus" => 3,
        "MatchTime" => "54'",
        "GroupName" => [%{"Locale" => "en-GB", "Description" => "Group A"}],
        "Home" => %{
          "TeamName" => [%{"Locale" => "en-GB", "Description" => "Mexico"}],
          "Abbreviation" => "MEX"
        },
        "Away" => %{
          "TeamName" => [%{"Locale" => "en-GB", "Description" => "South Africa"}],
          "Abbreviation" => "RSA"
        },
        "HomeTeamScore" => 1,
        "AwayTeamScore" => 0
      }

      other_competition = %{world_cup_match | "IdCompetition" => "103", "IdMatch" => "999"}

      [match] = Fifa.parse_live(%{"Results" => [other_competition, world_cup_match]})

      assert %Match{source: :fifa, id: "400021443", state: :live, clock: "54'"} = match
      assert match.home == %{name: "Mexico", abbrev: "MEX", score: 1}
      assert match.away == %{name: "South Africa", abbrev: "RSA", score: 0}
    end
  end

  describe "state_from_status/1" do
    test "maps known MatchStatus codes" do
      assert Fifa.state_from_status(0) == :finished
      assert Fifa.state_from_status(1) == :scheduled
      assert Fifa.state_from_status(3) == :live
    end

    test "falls back to :scheduled for unknown codes" do
      assert Fifa.state_from_status(7) == :scheduled
      assert Fifa.state_from_status(nil) == :scheduled
    end
  end
end
