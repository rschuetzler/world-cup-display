defmodule WorldCupTracker.Store do
  @moduledoc """
  Owns the current tournament state: the match schedule (with today's fresher
  data merged in by match id), group standings, recent goal events, and
  last-update timestamps.

  Writes go through the GenServer; reads go straight to a protected ETS table
  so readers (the serving layer, the poller's cadence choice) never block on
  the writer.

  Goal events are edge-detected on write: when an incoming match's home or
  away score is strictly greater than the stored score for the same match id
  (both integers — `nil -> 0` is a score appearing, not a goal) and the match
  is `:live` or `:halftime`, a `%{match_id, team, match, at}` event is
  recorded. Events are kept for `goal_retention_ms` (default 60s) and pruned
  on every write and filtered on every read.

  Full-time transitions are edge-detected the same way: when a stored match
  goes from `:live`/`:halftime` to `:finished`, its `finished_at` is recorded.
  A match first seen as `:finished` (e.g. schedule backfill on boot) gets no
  `finished_at` — only observed transitions count. Entries are kept for
  #{div(60 * 60 * 1000, 60_000)} minutes (pruned on write) and filtered per
  read via `recently_finished/2`.
  """

  use GenServer

  alias WorldCupTracker.Match

  @default_retention_ms 60_000
  # Finished transitions outlive goal events: long enough to cover any
  # plausible post-game hold config, short enough to stay tiny.
  @finished_retention_ms 60 * 60 * 1000
  @live_states [:live, :halftime]
  # A match whose kickoff has passed but the feed still reports `:scheduled`
  # (the "kicked off, not yet flagged live" gap) stays in `next_matches` for
  # this grace window so it keeps being featured (as "SOON") instead of
  # vanishing. Mirrors the poller's ±15-min `soon` cadence window.
  @kickoff_grace_ms 15 * 60 * 1000
  @empty_last_updated %{schedule: nil, today: nil, standings: nil}

  @type goal_event :: %{
          match_id: String.t(),
          team: :home | :away,
          match: Match.t(),
          at: DateTime.t()
        }

  ## Lifecycle

  @doc """
  Starts the store.

  Options:

    * `:name` — GenServer name and ETS table name (default `#{inspect(__MODULE__)}`)
    * `:goal_retention_ms` — how long goal events are kept (default #{@default_retention_ms})
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  ## Writes

  @doc "Replaces/merges the full schedule into the store (merge by match id)."
  @spec put_schedule(atom(), [Match.t()]) :: :ok
  def put_schedule(store \\ __MODULE__, matches) when is_list(matches) do
    GenServer.call(store, {:put_matches, :schedule, matches})
  end

  @doc "Merges today's (fresher) matches into the store by match id."
  @spec put_today(atom(), [Match.t()]) :: :ok
  def put_today(store \\ __MODULE__, matches) when is_list(matches) do
    GenServer.call(store, {:put_matches, :today, matches})
  end

  @doc "Stores the latest group standings."
  @spec put_standings(atom(), [map()]) :: :ok
  def put_standings(store \\ __MODULE__, standings) when is_list(standings) do
    GenServer.call(store, {:put_standings, standings})
  end

  ## Reads (straight from ETS)

  @doc "All known matches, sorted by kickoff."
  @spec schedule(atom()) :: [Match.t()]
  def schedule(store \\ __MODULE__) do
    store
    |> lookup(:matches, %{})
    |> Map.values()
    |> sort_by_kickoff()
  end

  @doc "Matches currently in play (`:live` or `:halftime`), sorted by kickoff."
  @spec live_matches(atom()) :: [Match.t()]
  def live_matches(store \\ __MODULE__) do
    store |> schedule() |> Enum.filter(&(&1.state in @live_states))
  end

  @doc """
  The next `n` `:scheduled` matches, soonest first.

  Includes a match whose kickoff passed up to #{div(@kickoff_grace_ms, 60_000)}
  minutes ago but the feed still calls `:scheduled` — the gap between the clock
  hitting kickoff and the source flipping the match to `:live` — so it stays
  featured (rendered as "SOON") rather than dropping off the board.
  """
  @spec next_matches(atom(), non_neg_integer()) :: [Match.t()]
  def next_matches(store \\ __MODULE__, n) when is_integer(n) and n >= 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -@kickoff_grace_ms, :millisecond)

    store
    |> schedule()
    |> Enum.filter(fn match ->
      match.state == :scheduled and match.kickoff != nil and
        DateTime.compare(match.kickoff, cutoff) != :lt
    end)
    |> Enum.take(n)
  end

  @doc "The latest group standings (empty list until first fetch)."
  @spec standings(atom()) :: [map()]
  def standings(store \\ __MODULE__) do
    lookup(store, :standings, [])
  end

  @doc "Goal events from the last `goal_retention_ms`, oldest first."
  @spec goal_events(atom()) :: [goal_event()]
  def goal_events(store \\ __MODULE__) do
    retention = lookup(store, :retention_ms, @default_retention_ms)
    now = DateTime.utc_now()

    store
    |> lookup(:goal_events, [])
    |> Enum.filter(&fresh?(&1, now, retention))
  end

  @doc """
  Matches observed transitioning to `:finished` within the last `within_ms`,
  most recent first, as `%{match: match, finished_at: finished_at}` — `match`
  is the current stored match (so later merges show through).
  """
  @spec recently_finished(atom(), non_neg_integer()) ::
          [%{match: Match.t(), finished_at: DateTime.t()}]
  def recently_finished(store \\ __MODULE__, within_ms) do
    now = DateTime.utc_now()
    matches = lookup(store, :matches, %{})

    store
    |> lookup(:finished, [])
    |> Enum.filter(fn %{finished_at: at} ->
      DateTime.diff(now, at, :millisecond) <= within_ms
    end)
    |> Enum.sort_by(&DateTime.to_unix(&1.finished_at, :millisecond), :desc)
    # A VAR-style finished -> live -> finished flip records twice; the most
    # recent transition wins.
    |> Enum.uniq_by(& &1.match_id)
    |> Enum.flat_map(fn %{match_id: id, finished_at: at} ->
      case matches do
        %{^id => match} -> [%{match: match, finished_at: at}]
        _ -> []
      end
    end)
  end

  @doc "Last successful update time per data kind."
  @spec last_updated(atom()) :: %{
          schedule: DateTime.t() | nil,
          today: DateTime.t() | nil,
          standings: DateTime.t() | nil
        }
  def last_updated(store \\ __MODULE__) do
    lookup(store, :last_updated, @empty_last_updated)
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    retention = Keyword.get(opts, :goal_retention_ms, @default_retention_ms)
    table = :ets.new(name, [:named_table, :protected, :set, read_concurrency: true])
    :ets.insert(table, {:retention_ms, retention})
    {:ok, %{table: table, retention: retention}}
  end

  @impl true
  def handle_call({:put_matches, kind, matches}, _from, state) do
    now = DateTime.utc_now()
    old_map = lookup(state.table, :matches, %{})

    new_events = detect_goals(old_map, matches, now)
    merged = Enum.reduce(matches, old_map, &Map.put(&2, &1.id, &1))

    events =
      lookup(state.table, :goal_events, [])
      |> Kernel.++(new_events)
      |> Enum.filter(&fresh?(&1, now, state.retention))

    finished =
      lookup(state.table, :finished, [])
      |> Kernel.++(detect_finished(old_map, matches, now))
      |> Enum.filter(fn %{finished_at: at} ->
        DateTime.diff(now, at, :millisecond) <= @finished_retention_ms
      end)

    last_updated = Map.put(lookup(state.table, :last_updated, @empty_last_updated), kind, now)

    :ets.insert(state.table, [
      {:matches, merged},
      {:goal_events, events},
      {:finished, finished},
      {:last_updated, last_updated}
    ])

    {:reply, :ok, state}
  end

  def handle_call({:put_standings, standings}, _from, state) do
    now = DateTime.utc_now()

    last_updated =
      Map.put(lookup(state.table, :last_updated, @empty_last_updated), :standings, now)

    :ets.insert(state.table, [{:standings, standings}, {:last_updated, last_updated}])
    {:reply, :ok, state}
  end

  ## Internals

  defp detect_goals(old_map, matches, now) do
    for match <- matches,
        match.state in @live_states,
        old = Map.get(old_map, match.id),
        team <- [:home, :away],
        goal?(Map.fetch!(old, team).score, Map.fetch!(match, team).score) do
      %{match_id: match.id, team: team, match: match, at: now}
    end
  end

  defp goal?(old_score, new_score) when is_integer(old_score) and is_integer(new_score) do
    new_score > old_score
  end

  defp goal?(_old_score, _new_score), do: false

  # Only observed in-play -> :finished transitions count, mirroring goal
  # detection: a match first seen as :finished (schedule backfill on boot)
  # never gets a finished_at.
  defp detect_finished(old_map, matches, now) do
    for match <- matches,
        match.state == :finished,
        old = Map.get(old_map, match.id),
        old.state in @live_states do
      %{match_id: match.id, finished_at: now}
    end
  end

  defp fresh?(%{at: at}, now, retention_ms) do
    DateTime.diff(now, at, :millisecond) <= retention_ms
  end

  defp sort_by_kickoff(matches) do
    Enum.sort_by(matches, & &1.kickoff, fn
      nil, _b -> false
      _a, nil -> true
      a, b -> DateTime.compare(a, b) != :gt
    end)
  end

  defp lookup(table, key, default) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end
end
