defmodule WorldCupTracker.Matrix.DisplayFixtures do
  @moduledoc """
  Snapshot fixtures for the World Cup boards, ported from the `Fixtures` map in
  `reference/worldcup-design/reference/worldcup/wc-data.js` (`nowNext`, `live`),
  plus a `:goal` fixture the JS builds at runtime via `fireGoal`.

  All timestamps are epoch ms. The JS computes fixtures against the live wall
  clock; here `now` defaults to a fixed anchor (`default_now/0`) so tests and
  previews are deterministic, and every match anchor is derived from it with
  the same offsets the JS uses.
  """

  @min 60_000
  @hr 60 * @min

  # Friday 2026-06-12 15:00 EDT — mid-afternoon on a matchday, so the first
  # two "next" kickoffs land today (bare HH:MM) and the +21h one lands
  # tomorrow (weekday-prefixed), exercising both kickoff-label forms.
  @default_now DateTime.to_unix(~U[2026-06-12 19:00:00Z], :millisecond)

  @doc "The fixed `now` anchor all fixtures default to."
  def default_now, do: @default_now

  @doc "Now & Next board: two live matches + the next three kickoffs."
  def now_next(now \\ @default_now) do
    %{
      state: :now_next,
      now: now,
      tz: "America/New_York",
      live: [
        %{home: "USA", away: "MEX", hs: 2, as: 1, kickoff_utc: now - 78 * @min, ht: false},
        %{home: "ARG", away: "CRO", hs: 1, as: 1, kickoff_utc: now - 45 * @min, ht: true}
      ],
      next: [
        %{
          home: "BRA",
          away: "ESP",
          kickoff_utc: now + 2 * @hr + 14 * @min,
          tz: "America/New_York"
        },
        %{home: "ENG", away: "FRA", kickoff_utc: now + 5 * @hr, tz: "America/New_York"},
        %{home: "NED", away: "GER", kickoff_utc: now + 21 * @hr, tz: "America/New_York"}
      ]
    }
  end

  @doc """
  Now & Next board with no live matches: the idle header (kickoff countdown
  instead of the LIVE pill), the earliest kickoff (~47 minutes out) featured
  as the big-flag hero, and the three kickoffs after it in the NEXT rows —
  3 hours, a day, and ~26 hours out.
  """
  def now_next_idle(now \\ @default_now) do
    %{
      state: :now_next,
      now: now,
      tz: "America/New_York",
      live: [],
      next: [
        %{home: "BRA", away: "ESP", kickoff_utc: now + 47 * @min, tz: "America/New_York"},
        %{home: "ENG", away: "FRA", kickoff_utc: now + 3 * @hr, tz: "America/New_York"},
        %{home: "NED", away: "GER", kickoff_utc: now + 24 * @hr, tz: "America/New_York"},
        %{home: "GER", away: "POR", kickoff_utc: now + 26 * @hr, tz: "America/New_York"}
      ]
    }
  end

  @doc "Live-match board: USA v MEX 2-1, 78th minute."
  def live(now \\ @default_now) do
    %{
      state: :live,
      now: now,
      minute: 78,
      hs: 2,
      as: 1,
      match: %{
        stage: "GROUP D",
        home: "USA",
        away: "MEX",
        venue: "LOS ANGELES",
        tz: "America/Los_Angeles",
        kickoff_utc: now - 78 * @min
      }
    }
  end

  @doc """
  Live board on the post-game FINAL hold: USA v MEX 2-1, full time. Same
  shape as `live/1` (state stays `:live`) plus `final: true`.
  """
  def live_final(now \\ @default_now) do
    live(now) |> Map.merge(%{final: true, minute: 90})
  end

  @doc """
  Goal celebration `t_ms` milliseconds in: the live snap with the scoring side
  recorded (MEX equalising-then-leading away goal, per the JS sim's canonical
  `MEXICO SCORES!` demo) and `goal_started_at` back-dated so
  `now - goal_started_at == t_ms`.
  """
  def goal(t_ms, now \\ @default_now) do
    live(now)
    |> Map.merge(%{
      state: :goal,
      goal_started_at: now - t_ms,
      team: :away,
      code: "MEX"
    })
  end
end
