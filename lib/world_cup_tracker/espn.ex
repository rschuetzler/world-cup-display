defmodule WorldCupTracker.Espn do
  @moduledoc """
  Client for ESPN's unauthenticated site API (league code `fifa.world`).

  The `parse_*` functions are pure: they take already-decoded JSON maps and
  return normalized data, so they can be tested against captured fixtures.
  The `fetch_*` functions are thin Req wrappers around the parsers.
  """

  alias WorldCupTracker.Match

  @site_base "https://site.api.espn.com/apis/site/v2/sports/soccer/fifa.world"
  @standings_url "https://site.api.espn.com/apis/v2/sports/soccer/fifa.world/standings"
  @user_agent "world-cup-tracker/0.1"

  ## HTTP wrappers

  @doc "Fetches today's scoreboard."
  @spec fetch_scoreboard() :: {:ok, [Match.t()]} | {:error, term()}
  def fetch_scoreboard, do: fetch_scoreboard(Date.utc_today())

  @doc """
  Fetches the scoreboard for a `Date` or a `"YYYYMMDD-YYYYMMDD"` range string.

  The full tournament range is `"20260611-20260719"`; range requests include
  `limit=200` so all 104 matches come back in one call.
  """
  @spec fetch_scoreboard(Date.t() | String.t()) :: {:ok, [Match.t()]} | {:error, term()}
  def fetch_scoreboard(%Date{} = date) do
    do_fetch_scoreboard(Calendar.strftime(date, "%Y%m%d"), [])
  end

  def fetch_scoreboard(dates) when is_binary(dates) do
    extra = if String.contains?(dates, "-"), do: [limit: 200], else: []
    do_fetch_scoreboard(dates, extra)
  end

  defp do_fetch_scoreboard(dates, extra_params) do
    get_json("#{@site_base}/scoreboard", [dates: dates] ++ extra_params, &parse_scoreboard/1)
  end

  @doc "Fetches the match summary (key events / scorers) for an ESPN event id."
  @spec fetch_summary(String.t() | integer()) :: {:ok, map()} | {:error, term()}
  def fetch_summary(event_id) do
    get_json("#{@site_base}/summary", [event: event_id], &parse_summary/1)
  end

  @doc "Fetches group standings for all 12 groups."
  @spec fetch_standings() :: {:ok, [map()]} | {:error, term()}
  def fetch_standings do
    get_json(@standings_url, [], &parse_standings/1)
  end

  defp get_json(url, params, parser) do
    case Req.get(url, params: params, headers: [user_agent: @user_agent]) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, parser.(body)}
      {:ok, %Req.Response{status: 200}} -> {:error, :invalid_body}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Scoreboard

  @doc "Parses a decoded scoreboard payload into `Match` structs sorted by kickoff."
  @spec parse_scoreboard(map()) :: [Match.t()]
  def parse_scoreboard(scoreboard) do
    scoreboard
    |> Map.get("events", [])
    |> Enum.map(&parse_event/1)
    |> Enum.sort_by(& &1.kickoff, DateTime)
  end

  defp parse_event(event) do
    competition = event |> Map.get("competitions", []) |> List.first() || %{}
    status = Map.get(event, "status") || %{}
    state = state_from_status(status)
    competitors = Map.get(competition, "competitors", [])

    %Match{
      source: :espn,
      id: Map.get(event, "id"),
      kickoff: parse_kickoff(Map.get(event, "date")),
      round: round_label(event, competition),
      home: side(competitors, "home", state),
      away: side(competitors, "away", state),
      state: state,
      clock: clock(status, state),
      detail: get_in(status, ["type", "detail"])
    }
  end

  @doc """
  Maps an ESPN `status` map to a match state.

  `"pre"` → `:scheduled`, `"post"` → `:finished`, `"in"` → `:halftime` when
  the status detail mentions halftime, otherwise `:live`.
  """
  @spec state_from_status(map()) :: Match.state()
  def state_from_status(status) do
    case get_in(status, ["type", "state"]) do
      "pre" -> :scheduled
      "post" -> :finished
      "in" -> if halftime?(get_in(status, ["type", "detail"])), do: :halftime, else: :live
      _other -> :scheduled
    end
  end

  defp halftime?(detail) when is_binary(detail) do
    detail |> String.downcase() |> String.contains?("halftime")
  end

  defp halftime?(_), do: false

  # ESPN reports a meaningless "0'" clock pre-match; keep the clock for live,
  # halftime, and finished matches (final clock, e.g. "90'+8'").
  defp clock(_status, :scheduled), do: nil
  defp clock(status, _state), do: Map.get(status, "displayClock")

  # ESPN dates omit seconds: "2026-06-11T19:00Z".
  defp parse_kickoff(date) when is_binary(date) do
    normalized = String.replace(date, ~r/(T\d{2}:\d{2})(Z|[+-]\d{2}:?\d{2})$/, "\\1:00\\2")

    case DateTime.from_iso8601(normalized) do
      {:ok, datetime, _offset} -> DateTime.shift_zone!(datetime, "Etc/UTC")
      {:error, _reason} -> nil
    end
  end

  defp parse_kickoff(_), do: nil

  # The scoreboard's competitions[0].notes is empty for this tournament; the
  # per-event round actually lives in event.season.slug ("group-stage",
  # "semifinals", "final", ...). Prefer a note headline when one exists.
  defp round_label(event, competition) do
    note_headline =
      competition
      |> Map.get("notes")
      |> List.wrap()
      |> Enum.find_value(fn
        %{"headline" => headline} when is_binary(headline) and headline != "" -> headline
        _ -> nil
      end)

    note_headline || humanize_slug(get_in(event, ["season", "slug"]))
  end

  defp humanize_slug(slug) when is_binary(slug) do
    slug |> String.split("-") |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanize_slug(_), do: nil

  defp side(competitors, home_away, state) do
    competitor = Enum.find(competitors, %{}, &(Map.get(&1, "homeAway") == home_away))
    team = Map.get(competitor, "team") || %{}

    %{
      name: Map.get(team, "displayName") || Map.get(team, "name"),
      abbrev: Map.get(team, "abbreviation"),
      score: if(state == :scheduled, do: nil, else: parse_score(Map.get(competitor, "score")))
    }
  end

  # ESPN reports scores as strings ("2").
  defp parse_score(score) when is_integer(score), do: score

  defp parse_score(score) when is_binary(score) do
    case Integer.parse(score) do
      {value, _rest} -> value
      :error -> nil
    end
  end

  defp parse_score(_), do: nil

  ## Summary

  @doc """
  Parses a decoded `/summary` payload into `%{events: [...]}` where each event
  has `:minute`, `:type`, and `:text`. Key events without text (kickoff,
  half markers, ...) are skipped.
  """
  @spec parse_summary(map()) :: %{
          events: [%{minute: String.t(), type: String.t(), text: String.t()}]
        }
  def parse_summary(summary) do
    events =
      summary
      |> Map.get("keyEvents", [])
      |> Enum.reject(&(Map.get(&1, "text") in [nil, ""]))
      |> Enum.map(fn key_event ->
        %{
          minute: get_in(key_event, ["clock", "displayValue"]),
          type: get_in(key_event, ["type", "text"]),
          text: Map.get(key_event, "text")
        }
      end)

    %{events: events}
  end

  ## Standings

  @doc """
  Parses a decoded standings payload into a list of groups:
  `%{name: "Group A", entries: [%{team, abbrev, played, wins, draws, losses, goal_diff, points}]}`.
  """
  @spec parse_standings(map()) :: [map()]
  def parse_standings(standings) do
    standings
    |> Map.get("children", [])
    |> Enum.map(fn group ->
      entries = get_in(group, ["standings", "entries"]) || []

      %{
        name: Map.get(group, "name"),
        entries: Enum.map(entries, &parse_standings_entry/1)
      }
    end)
  end

  defp parse_standings_entry(entry) do
    team = Map.get(entry, "team") || %{}

    stats =
      entry
      |> Map.get("stats", [])
      |> Map.new(fn stat -> {Map.get(stat, "name"), Map.get(stat, "value")} end)

    %{
      team: Map.get(team, "displayName"),
      abbrev: Map.get(team, "abbreviation"),
      played: int_stat(stats, "gamesPlayed"),
      wins: int_stat(stats, "wins"),
      draws: int_stat(stats, "ties"),
      losses: int_stat(stats, "losses"),
      goal_diff: int_stat(stats, "pointDifferential"),
      points: int_stat(stats, "points")
    }
  end

  defp int_stat(stats, name) do
    case Map.get(stats, name) do
      value when is_number(value) -> trunc(value)
      _ -> 0
    end
  end
end
