defmodule WorldCupTracker.Matrix.Brightness do
  @moduledoc """
  Time-of-day brightness scaling + gamma correction, applied by `Matrix.Rgb565`
  when encoding the device frame. The canonical framebuffer stays full-range;
  correction is applied only at encode time. The display's local timezone drives
  auto-dimming (full by day, dim overnight).
  """
  @db Tz.TimeZoneDatabase

  @day 1.0
  @night 0.25

  # Precompute gamma 2.2 as a 0..255 -> 0..255 lookup tuple at compile time.
  @gamma (for v <- 0..255 do
            round(:math.pow(v / 255, 2.2) * 255)
          end)
         |> List.to_tuple()

  @doc "Brightness scalar 0.25..1.0 for a local hour-of-day (float 0.0..24.0)."
  def for_hour(h) when h >= 8.0 and h <= 18.0, do: @day
  def for_hour(h) when h >= 6.0 and h < 8.0, do: lerp(@night, @day, (h - 6.0) / 2.0)
  def for_hour(h) when h > 18.0 and h <= 22.0, do: lerp(@day, @night, (h - 18.0) / 4.0)
  def for_hour(_h), do: @night

  @doc "Gamma-2.2 corrected value for a 0..255 channel."
  def gamma(v) when v in 0..255, do: elem(@gamma, v)

  @doc "Gamma-correct each channel of an {r,g,b}, then scale by `scalar` (0..1), clamped 0..255."
  def apply({r, g, b}, scalar) do
    {scale(r, scalar), scale(g, scalar), scale(b, scalar)}
  end

  @doc "Brightness scalar for a display timezone at epoch-ms `now`."
  def for_zone(tz, now_ms) do
    dt = now_ms |> DateTime.from_unix!(:millisecond) |> DateTime.shift_zone!(tz, @db)
    for_hour(dt.hour + dt.minute / 60.0)
  end

  defp scale(c, scalar), do: min(255, round(gamma(c) * scalar))
  defp lerp(a, b, t), do: a + (b - a) * t
end
