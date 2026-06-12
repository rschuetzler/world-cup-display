defmodule TravisTracker.Matrix.AltCursor do
  @moduledoc """
  Per-display rotation cursor for the alternating matrix face.

  The device re-polls the baked RGB565 frame every ~15s and only sees a new
  slide when it polls, so the *effective* dwell of each slide is the poll
  interval — not the nominal alternation period. Deriving the slide from
  wall-clock then aliases against the poll cadence: when the two periods line
  up a slide can stick for two polls (~30s).

  Instead we advance exactly one slide per poll here. Each `advance/3` for a
  token bumps the cursor, guarded by `@min_advance_ms` so a rapid duplicate /
  revalidation request within one dwell doesn't skip a slide. State is
  ephemeral — on restart the rotation simply restarts from 0.
  """
  use GenServer

  # Must sit comfortably below the alternating poll interval (15s) but above
  # request retry / revalidation timescales: a genuine poll advances once, a
  # quick re-request holds the current slide.
  @min_advance_ms 10_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Return the slide index (`0..n-1`) to render for `token` now, advancing the
  cursor by one if at least `@min_advance_ms` has elapsed since its last
  advance. `now_ms` is wall-clock epoch milliseconds (passed in so the logic is
  deterministic and testable).
  """
  def advance(token, n, now_ms, server \\ __MODULE__) when n > 0 do
    GenServer.call(server, {:advance, token, n, now_ms})
  end

  @doc false
  # Pure cursor step. `nil` (never seen) → start at index 0, stamping the time.
  # Otherwise advance by one iff the guard interval has elapsed, else hold.
  def step(nil, now_ms, _min_ms), do: {0, now_ms}
  def step({idx, at_ms}, now_ms, min_ms) when now_ms - at_ms >= min_ms, do: {idx + 1, now_ms}
  def step({idx, at_ms}, _now_ms, _min_ms), do: {idx, at_ms}

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:advance, token, n, now_ms}, _from, state) do
    {raw, at_ms} = step(Map.get(state, token), now_ms, @min_advance_ms)
    {:reply, Integer.mod(raw, n), Map.put(state, token, {raw, at_ms})}
  end
end
