defmodule WorldCupTracker.Display.State do
  @moduledoc """
  Pure snapshot builder between the data layer (`WorldCupTracker.Store`) and
  the board renderers (`WorldCupTracker.Matrix.WcRenderers`).

  `snapshot/1` reads the store and produces exactly one of the three snapshot
  shapes `WcRenderers.render/1` consumes (see
  `WorldCupTracker.Matrix.DisplayFixtures` for the canonical shapes), chosen
  in priority order:

    * `:goal`     — a goal event younger than `:goal_duration_ms` whose match
      is still in play (most recent event wins)
    * `:live`     — exactly one match in play, or — with several in play — the
      first one involving a followed team
    * final hold  — nothing in play but a match finished within
      `:final_hold_ms`: the same `:live`-shaped snapshot with `final: true`,
      so the just-ended score stays up with a FINAL banner
    * `:now_next` — everything else: several unfollowed live matches, or none

  No process: the serving layer calls `snapshot/1` per request. Inputs are
  injectable for tests (`:store`, `:now` in epoch ms), and the config keys
  `:timezone`, `:followed_teams`, `:goal_duration_ms` and `:final_hold_ms`
  read the `:world_cup_tracker` app env with per-call opts overrides.
  """

  alias WorldCupTracker.{Match, Store}

  @default_timezone "America/Denver"
  @default_followed_teams ["USA"]
  @default_goal_duration_ms 16_500
  # How long the live board stays up (as a FINAL hold) after a match ends.
  @default_final_hold_ms 20 * 60 * 1000

  # Now & Next draws live rows at y=10/y=20 and next rows at y=39/48/57.
  # Idle (no live rows) it features the first next kickoff as a hero up top
  # and the remaining three below — so it wants up to 4 next matches.
  @max_live_rows 2
  @next_count 4

  @typedoc "Snapshot consumed by `WorldCupTracker.Matrix.WcRenderers.render/1`."
  @type snapshot :: map()

  @doc """
  Builds the snapshot for the current store contents.

  Options:

    * `:store` — store name to read from (default `WorldCupTracker.Store`)
    * `:now` — current time in epoch ms (default `System.system_time/1`)
    * `:timezone`, `:followed_teams`, `:goal_duration_ms`, `:final_hold_ms` —
      app-env overrides
  """
  @spec snapshot(keyword()) :: snapshot()
  def snapshot(opts \\ []) do
    store = Keyword.get(opts, :store, Store)
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:millisecond) end)
    live_matches = Store.live_matches(store)
    final_hold_ms = config(opts, :final_hold_ms, @default_final_hold_ms)
    recent_finals = Store.recently_finished(store, final_hold_ms)

    case choose(live_matches, Store.goal_events(store), recent_finals, now, opts) do
      {:goal, event} ->
        match = Enum.find(live_matches, &(&1.id == event.match_id))
        goal_snapshot(match, event, store, now, opts)

      {:live, match} ->
        live_snapshot(match, store, now, opts)

      {:final, match} ->
        final_snapshot(match, store, now, opts)

      :now_next ->
        now_next_snapshot(live_matches, store, now, opts)
    end
  end

  @doc """
  Picks which board to show, in priority order:

  1. `{:goal, event}` — the most recent goal event younger than
     `:goal_duration_ms` whose match is still in `live_matches`
  2. `{:live, match}` — the only match in play, or, with several in play, the
     first involving a followed team
  3. `:now_next` — several unfollowed live matches
  4. `{:final, match}` — nothing in play, but a match finished within
     `:final_hold_ms` (the most recently finished wins)
  5. `:now_next` — otherwise

  `recent_finals` is `Store.recently_finished/2`-shaped:
  `[%{match: match, finished_at: datetime}]`.
  """
  @spec choose(
          [Match.t()],
          [Store.goal_event()],
          [%{match: Match.t(), finished_at: DateTime.t()}],
          integer(),
          keyword()
        ) ::
          {:goal, Store.goal_event()} | {:live, Match.t()} | {:final, Match.t()} | :now_next
  def choose(live_matches, goal_events, recent_finals, now, opts \\ []) do
    goal_duration_ms = config(opts, :goal_duration_ms, @default_goal_duration_ms)
    live_ids = MapSet.new(live_matches, & &1.id)

    fresh_goal =
      goal_events
      |> Enum.filter(fn event ->
        MapSet.member?(live_ids, event.match_id) and now - to_ms(event.at) < goal_duration_ms
      end)
      |> Enum.sort_by(&to_ms(&1.at))
      |> List.last()

    cond do
      fresh_goal ->
        {:goal, fresh_goal}

      match?([_], live_matches) ->
        {:live, hd(live_matches)}

      live_matches == [] ->
        case recent_final(recent_finals, now, opts) do
          nil -> :now_next
          match -> {:final, match}
        end

      true ->
        followed = config(opts, :followed_teams, @default_followed_teams)

        case Enum.find(live_matches, &followed?(&1, followed)) do
          nil -> :now_next
          match -> {:live, match}
        end
    end
  end

  # The most recently finished match still inside the :final_hold_ms window.
  defp recent_final(recent_finals, now, opts) do
    final_hold_ms = config(opts, :final_hold_ms, @default_final_hold_ms)

    recent_finals
    |> Enum.filter(fn %{finished_at: at} -> now - to_ms(at) < final_hold_ms end)
    |> Enum.sort_by(&to_ms(&1.finished_at))
    |> List.last()
    |> case do
      nil -> nil
      %{match: match} -> match
    end
  end

  @doc """
  Base minute from a `Match` display clock: `"78'"` → `78`, `"45'+2'"` → `45`,
  `"90'+8'"` → `90`. `nil` or unparseable (e.g. `"HT"`) → `0`.
  """
  # TODO(2026-06-12): WcRenderers derives 1st-vs-2nd half from this minute
  # alone (<= 45 → "1ST HALF"), which is a stopgap — ESPN carries a
  # status.period field we don't put on `Match` yet. A live-window probe runs
  # today (2026-06-12); if `Match` gains `:period`, pass it through instead of
  # inferring the half from the minute.
  @spec parse_minute(String.t() | nil) :: non_neg_integer()
  def parse_minute(nil), do: 0

  def parse_minute(clock) when is_binary(clock) do
    case clock |> String.trim() |> Integer.parse() do
      {minute, _rest} when minute >= 0 -> minute
      _ -> 0
    end
  end

  @doc """
  The stage line for the `:live` board, e.g. `"GROUP D"` or `"SEMIFINALS"`.

  ESPN's group-stage `round` is the generic `"Group Stage"`, so for group-stage
  matches the group letter is looked up from the standings (the group whose
  entries contain either side, by team name or abbrev). Knockout rounds — and
  group-stage matches the standings don't know yet — fall back to the upcased
  round; a `nil` round yields `""`.
  """
  @spec stage_label(Match.t(), [map()]) :: String.t()
  def stage_label(%Match{} = match, standings) do
    group_stage? = is_binary(match.round) and String.downcase(match.round) =~ "group"

    with true <- group_stage?,
         %{name: name} when is_binary(name) <-
           Enum.find(standings, &group_has_side?(&1, match)) do
      String.upcase(name)
    else
      _ -> String.upcase(match.round || "")
    end
  end

  ## Snapshot builders

  defp now_next_snapshot(live_matches, store, now, opts) do
    tz = config(opts, :timezone, @default_timezone)
    followed = config(opts, :followed_teams, @default_followed_teams)

    # The board fits two live rows; followed teams get first claim.
    {followed_live, other_live} = Enum.split_with(live_matches, &followed?(&1, followed))

    live_rows =
      (followed_live ++ other_live)
      |> Enum.take(@max_live_rows)
      |> Enum.map(fn match ->
        %{
          home: code(match.home),
          away: code(match.away),
          hs: score(match.home),
          as: score(match.away),
          kickoff_utc: to_ms(match.kickoff) || now,
          ht: match.state == :halftime
        }
      end)

    next_rows =
      store
      |> Store.next_matches(@next_count)
      |> Enum.map(fn match ->
        %{
          home: code(match.home),
          away: code(match.away),
          kickoff_utc: to_ms(match.kickoff),
          tz: tz
        }
      end)

    %{state: :now_next, now: now, tz: tz, live: live_rows, next: next_rows}
  end

  defp live_snapshot(match, store, now, opts) do
    %{
      state: :live,
      now: now,
      minute: parse_minute(match.clock),
      hs: score(match.home),
      as: score(match.away),
      match: %{
        stage: stage_label(match, Store.standings(store)),
        home: code(match.home),
        away: code(match.away),
        # `Match` carries no venue and the renderer never reads it; "" keeps
        # shape parity with DisplayFixtures.
        venue: "",
        tz: config(opts, :timezone, @default_timezone),
        kickoff_utc: to_ms(match.kickoff) || now
      }
    }
  end

  # The post-game FINAL hold: the :live board shape (state: :live) with
  # final: true so WcRenderers swaps minute/LIVE/clock for FINAL / FULL TIME.
  defp final_snapshot(match, store, now, opts) do
    match
    |> live_snapshot(store, now, opts)
    |> Map.put(:final, true)
  end

  defp goal_snapshot(match, event, store, now, opts) do
    match
    |> live_snapshot(store, now, opts)
    |> Map.merge(%{
      state: :goal,
      goal_started_at: to_ms(event.at),
      team: event.team,
      code: code(Map.fetch!(match, event.team))
    })
  end

  ## Internals

  defp followed?(match, followed_teams) do
    code(match.home) in followed_teams or code(match.away) in followed_teams
  end

  # 3-letter display code for a match side. Knockout placeholders may carry a
  # nil abbrev — fall back to the first three letters of the name, upcased.
  defp code(%{abbrev: abbrev}) when is_binary(abbrev) and abbrev != "", do: abbrev

  defp code(%{name: name}) when is_binary(name),
    do: name |> String.slice(0, 3) |> String.upcase()

  defp code(_side), do: ""

  # nil score → 0 so the live/goal boards always have a number to draw.
  defp score(%{score: score}) when is_integer(score), do: score
  defp score(_side), do: 0

  defp group_has_side?(group, match) do
    names = for side <- [match.home, match.away], is_binary(side.name), do: side.name
    abbrevs = for side <- [match.home, match.away], is_binary(side.abbrev), do: side.abbrev

    group
    |> Map.get(:entries, [])
    |> Enum.any?(fn entry ->
      Map.get(entry, :team) in names or Map.get(entry, :abbrev) in abbrevs
    end)
  end

  defp to_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)
  defp to_ms(nil), do: nil

  defp config(opts, key, default) do
    Keyword.get(opts, key, Application.get_env(:world_cup_tracker, key, default))
  end
end
