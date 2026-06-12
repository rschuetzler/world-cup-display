defmodule WorldCupTracker.Source do
  @moduledoc """
  Behaviour for upstream match-data sources.

  The poller talks to a source module rather than `WorldCupTracker.Espn`
  directly so tests can substitute a fake (see `WorldCupTracker.FakeSource`
  in `test/support`).
  """

  alias WorldCupTracker.Match

  @doc """
  Fetches the scoreboard for a `Date` or a `"YYYYMMDD-YYYYMMDD"` range string.
  """
  @callback scoreboard(dates :: String.t() | Date.t()) :: {:ok, [Match.t()]} | {:error, term()}

  @doc "Fetches group standings."
  @callback standings() :: {:ok, [map()]} | {:error, term()}

  defmodule Espn do
    @moduledoc "Default `WorldCupTracker.Source` backed by ESPN's site API."

    @behaviour WorldCupTracker.Source

    @impl true
    defdelegate scoreboard(dates), to: WorldCupTracker.Espn, as: :fetch_scoreboard

    @impl true
    defdelegate standings, to: WorldCupTracker.Espn, as: :fetch_standings
  end
end
