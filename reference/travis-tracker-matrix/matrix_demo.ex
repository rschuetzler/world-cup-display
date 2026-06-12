defmodule TravisTrackerWeb.MatrixDemo do
  @moduledoc """
  Stateless, wall-clock-driven rotation through the display-state fixtures for
  the matrix panel's demo mode. The state shown is a pure function of the clock
  and the dwell time — no stored cursor, so multiple panels stay in sync and it
  survives restarts.
  """
  alias TravisTrackerWeb.DisplayFixtures

  @doc """
  Picks the demo state for `now` given `dwell_seconds`, returning
  `{state, fixture_map}`. Index = floor(now_ms / dwell_ms) mod state_count.
  """
  def current_fixture(%DateTime{} = now, dwell_seconds)
      when is_integer(dwell_seconds) and dwell_seconds > 0 do
    states = DisplayFixtures.states()
    now_ms = DateTime.to_unix(now, :millisecond)
    index = now_ms |> div(dwell_seconds * 1000) |> rem(length(states))
    state = Enum.at(states, index)
    {state, DisplayFixtures.fixture(state, now)}
  end
end
