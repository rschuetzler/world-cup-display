defmodule WorldCupTracker.Fifa do
  @moduledoc """
  Client for FIFA's unauthenticated API (`api.fifa.com`), used as a fallback
  and cross-check for the primary ESPN source.

  The `parse_*` functions are pure: they take already-decoded JSON maps and
  return normalized data, so they can be tested against captured fixtures.
  The `fetch_*` functions are thin Req wrappers around the parsers.
  """

  alias WorldCupTracker.Match

  @api_base "https://api.fifa.com/api/v3"
  @user_agent "world-cup-tracker/0.1"
  @id_competition "17"
  @id_season "285023"

  ## HTTP wrappers

  @doc "Fetches the full tournament calendar (all 104 matches)."
  @spec fetch_calendar() :: {:ok, [Match.t()]} | {:error, term()}
  def fetch_calendar do
    params = [
      idCompetition: @id_competition,
      idSeason: @id_season,
      language: "en",
      count: 500
    ]

    get_json("#{@api_base}/calendar/matches", params, &parse_calendar/1)
  end

  @doc "Fetches all currently live matches, filtered to the World Cup."
  @spec fetch_live() :: {:ok, [Match.t()]} | {:error, term()}
  def fetch_live do
    get_json("#{@api_base}/live/football/now", [language: "en"], &parse_live/1)
  end

  defp get_json(url, params, parser) do
    case Req.get(url, params: params, headers: [user_agent: @user_agent]) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, parser.(body)}
      {:ok, %Req.Response{status: 200}} -> {:error, :invalid_body}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Calendar

  @doc "Parses a decoded calendar payload into `Match` structs sorted by kickoff."
  @spec parse_calendar(map()) :: [Match.t()]
  def parse_calendar(calendar) do
    calendar
    |> Map.get("Results", [])
    |> Enum.map(&parse_match/1)
    |> Enum.sort_by(& &1.kickoff, DateTime)
  end

  @doc """
  Parses a decoded `/live/football/now` payload.

  The live endpoint returns the same `Results` list of match objects as the
  calendar, but spans all competitions, so matches are filtered to the World
  Cup (`IdCompetition == "17"`).
  """
  @spec parse_live(map()) :: [Match.t()]
  def parse_live(live) do
    live
    |> Map.get("Results", [])
    |> Enum.filter(&(Map.get(&1, "IdCompetition") == @id_competition))
    |> Enum.map(&parse_match/1)
    |> Enum.sort_by(& &1.kickoff, DateTime)
  end

  defp parse_match(match) do
    state = state_from_status(Map.get(match, "MatchStatus"))

    %Match{
      source: :fifa,
      id: Map.get(match, "IdMatch"),
      kickoff: parse_kickoff(Map.get(match, "Date")),
      round: round_label(match),
      home: side(Map.get(match, "Home"), Map.get(match, "HomeTeamScore"), "PlaceHolderA", match),
      away: side(Map.get(match, "Away"), Map.get(match, "AwayTeamScore"), "PlaceHolderB", match),
      state: state,
      clock: clock(match, state),
      detail: nil
    }
  end

  @doc """
  Maps a FIFA `MatchStatus` code to a match state.

  `0` → `:finished`, `1` → `:scheduled`, `3` → `:live`. The 3-is-live mapping
  and any halftime/`Period` mapping are unverified until we observe a live
  match (a probe is scheduled for that); unknown codes fall back to
  `:scheduled`.
  """
  @spec state_from_status(integer() | nil) :: Match.state()
  def state_from_status(0), do: :finished
  def state_from_status(1), do: :scheduled
  def state_from_status(3), do: :live
  def state_from_status(_other), do: :scheduled

  # FIFA reports MatchTime as absolute minutes ("98'", no "90'+8'" form).
  defp clock(_match, :scheduled), do: nil
  defp clock(match, _state), do: Map.get(match, "MatchTime")

  # FIFA dates are full ISO8601 with seconds: "2026-06-11T19:00:00Z".
  defp parse_kickoff(date) when is_binary(date) do
    case DateTime.from_iso8601(date) do
      {:ok, datetime, _offset} -> DateTime.shift_zone!(datetime, "Etc/UTC")
      {:error, _reason} -> nil
    end
  end

  defp parse_kickoff(_), do: nil

  # Group-stage matches carry GroupName ("Group A"); knockout matches have an
  # empty GroupName, so fall back to StageName ("Round of 32", "Final", ...).
  defp round_label(match) do
    localized(Map.get(match, "GroupName")) || localized(Map.get(match, "StageName"))
  end

  defp localized([%{"Description" => description} | _rest]) when is_binary(description) do
    description
  end

  defp localized(_), do: nil

  # Knockout matches have `Home`/`Away` set to null until the teams are
  # decided; FIFA provides PlaceHolderA/PlaceHolderB labels ("2A", "W73", ...)
  # instead, which we surface as the side name.
  defp side(nil, _score, placeholder_key, match) do
    %{name: Map.get(match, placeholder_key), abbrev: nil, score: nil}
  end

  defp side(team, score, _placeholder_key, _match) do
    %{
      name: localized(Map.get(team, "TeamName")),
      abbrev: Map.get(team, "Abbreviation"),
      score: if(is_integer(score), do: score, else: nil)
    }
  end
end
