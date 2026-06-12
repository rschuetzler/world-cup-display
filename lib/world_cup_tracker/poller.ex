defmodule WorldCupTracker.Poller do
  @moduledoc """
  Drives upstream fetching on an adaptive cadence and feeds the
  `WorldCupTracker.Store`.

  On startup it fetches the full tournament schedule and standings, then
  polls today's scoreboard (a UTC day range spanning yesterday–tomorrow, so a
  Denver-evening match that lands on the next UTC date is always covered).
  The full schedule + standings are refreshed every `schedule_interval`.

  The delay until the next scoreboard poll is chosen by `choose_interval/4`:

    * any match `:live`/`:halftime`, or a goal event in the last ~20s
      → `live_interval` (default 20s)
    * any `:scheduled` match kicking off within 15 minutes → `soon_interval`
      (default 60s)
    * otherwise → `idle_interval` (default 10 min)

  Fetch errors never crash the poller and never clear the store — the last
  good data stays, a warning is logged, and the next tick retries.

  Configuration is read from `Application.get_env(:world_cup_tracker, key)`
  with built-in defaults; `start_link/1` opts override both. Keys: `:source`,
  `:store`, `:live_interval`, `:soon_interval`, `:idle_interval`,
  `:schedule_interval`, `:poll_on_start?`.
  """

  use GenServer

  require Logger

  alias WorldCupTracker.Store

  @tournament_range "20260611-20260719"
  @soon_window_ms 15 * 60 * 1000
  @goal_burst_ms 20_000
  @live_states [:live, :halftime]

  @defaults [
    source: WorldCupTracker.Source.Espn,
    store: WorldCupTracker.Store,
    live_interval: 20_000,
    soon_interval: 60_000,
    idle_interval: 600_000,
    schedule_interval: 3_600_000,
    poll_on_start?: true
  ]

  ## Public API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Polls today's scoreboard immediately and reschedules the next tick."
  @spec force_poll(GenServer.server()) :: :ok
  def force_poll(server \\ __MODULE__) do
    GenServer.call(server, :force_poll)
  end

  @doc "The delay (ms) chosen after the most recent poll, or `nil` before the first."
  @spec next_interval(GenServer.server()) :: non_neg_integer() | nil
  def next_interval(server \\ __MODULE__) do
    GenServer.call(server, :next_interval)
  end

  @doc """
  Pure cadence choice: returns the next poll delay in ms given the known
  matches, recent goal events (`%{at: DateTime}`), and the current time.

  Interval values come from `opts` (`:live_interval`, `:soon_interval`,
  `:idle_interval`), falling back to the module defaults.
  """
  @spec choose_interval([WorldCupTracker.Match.t()], [map()], DateTime.t(), keyword()) ::
          non_neg_integer()
  def choose_interval(matches, goal_events, now, opts \\ []) do
    config = Keyword.merge(@defaults, opts)

    cond do
      Enum.any?(matches, &(&1.state in @live_states)) -> config[:live_interval]
      recent_goal?(goal_events, now) -> config[:live_interval]
      kickoff_soon?(matches, now) -> config[:soon_interval]
      true -> config[:idle_interval]
    end
  end

  @doc "The `\"YYYYMMDD-YYYYMMDD\"` range for `today - 1` to `today + 1`."
  @spec today_range(Date.t()) :: String.t()
  def today_range(today \\ Date.utc_today()) do
    "#{date_param(Date.add(today, -1))}-#{date_param(Date.add(today, 1))}"
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    config = build_config(opts)

    state = %{
      config: config,
      poll_timer: nil,
      next_interval: nil
    }

    if config[:poll_on_start?] do
      {:ok, state, {:continue, :startup}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:startup, state) do
    refresh_schedule(state)
    Process.send_after(self(), :refresh_schedule, state.config[:schedule_interval])
    {:noreply, poll_and_reschedule(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    {:noreply, poll_and_reschedule(state)}
  end

  def handle_info(:refresh_schedule, state) do
    refresh_schedule(state)
    Process.send_after(self(), :refresh_schedule, state.config[:schedule_interval])
    {:noreply, state}
  end

  @impl true
  def handle_call(:force_poll, _from, state) do
    {:reply, :ok, poll_and_reschedule(state)}
  end

  def handle_call(:next_interval, _from, state) do
    {:reply, state.next_interval, state}
  end

  ## Internals

  defp build_config(opts) do
    Enum.map(@defaults, fn {key, default} ->
      value =
        Keyword.get_lazy(opts, key, fn ->
          Application.get_env(:world_cup_tracker, key, default)
        end)

      {key, value}
    end)
  end

  defp poll_and_reschedule(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)

    poll_today(state)

    interval =
      choose_interval(
        Store.schedule(state.config[:store]),
        Store.goal_events(state.config[:store]),
        DateTime.utc_now(),
        state.config
      )

    timer = Process.send_after(self(), :poll, interval)
    %{state | poll_timer: timer, next_interval: interval}
  end

  defp poll_today(state) do
    case state.config[:source].scoreboard(today_range()) do
      {:ok, matches} ->
        Store.put_today(state.config[:store], matches)

      {:error, reason} ->
        Logger.warning("Poller: today's scoreboard fetch failed: #{inspect(reason)}")
    end
  end

  defp refresh_schedule(state) do
    source = state.config[:source]
    store = state.config[:store]

    case source.scoreboard(@tournament_range) do
      {:ok, matches} ->
        Store.put_schedule(store, matches)

      {:error, reason} ->
        Logger.warning("Poller: schedule fetch failed: #{inspect(reason)}")
    end

    case source.standings() do
      {:ok, standings} ->
        Store.put_standings(store, standings)

      {:error, reason} ->
        Logger.warning("Poller: standings fetch failed: #{inspect(reason)}")
    end

    :ok
  end

  defp recent_goal?(goal_events, now) do
    Enum.any?(goal_events, fn %{at: at} ->
      DateTime.diff(now, at, :millisecond) <= @goal_burst_ms
    end)
  end

  # A :scheduled match counts as "soon" from 15 minutes before kickoff until
  # 15 minutes after (covers feeds that flip to "in" a little late) — but a
  # long-passed kickoff that never went live (postponement) won't pin us at
  # the soon cadence forever.
  defp kickoff_soon?(matches, now) do
    Enum.any?(matches, fn match ->
      match.state == :scheduled and match.kickoff != nil and
        abs(DateTime.diff(match.kickoff, now, :millisecond)) <= @soon_window_ms
    end)
  end

  defp date_param(date), do: Calendar.strftime(date, "%Y%m%d")
end
