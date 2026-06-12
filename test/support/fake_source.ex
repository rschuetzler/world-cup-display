defmodule WorldCupTracker.FakeSource do
  @moduledoc """
  A `WorldCupTracker.Source` fake for tests.

  Canned responses live in `:persistent_term`, so tests using this module
  must run with `async: false`. `configure/1` accepts:

    * `:scoreboard` — `{:ok, matches}` / `{:error, reason}`, or a 1-arity
      function of the `dates` argument
    * `:standings` — `{:ok, groups}` / `{:error, reason}`
    * `:notify` — a pid; every call is reported as
      `{WorldCupTracker.FakeSource, {:scoreboard, dates}}` or
      `{WorldCupTracker.FakeSource, :standings}`
  """

  @behaviour WorldCupTracker.Source

  def configure(opts) do
    :persistent_term.put({__MODULE__, :scoreboard}, Keyword.get(opts, :scoreboard, {:ok, []}))
    :persistent_term.put({__MODULE__, :standings}, Keyword.get(opts, :standings, {:ok, []}))
    :persistent_term.put({__MODULE__, :notify}, Keyword.get(opts, :notify))
    :ok
  end

  @impl true
  def scoreboard(dates) do
    notify({:scoreboard, dates})

    case :persistent_term.get({__MODULE__, :scoreboard}, {:ok, []}) do
      fun when is_function(fun, 1) -> fun.(dates)
      response -> response
    end
  end

  @impl true
  def standings do
    notify(:standings)
    :persistent_term.get({__MODULE__, :standings}, {:ok, []})
  end

  defp notify(message) do
    case :persistent_term.get({__MODULE__, :notify}, nil) do
      pid when is_pid(pid) -> send(pid, {__MODULE__, message})
      _ -> :ok
    end
  end
end
