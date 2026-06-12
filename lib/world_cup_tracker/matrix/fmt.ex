defmodule WorldCupTracker.Matrix.Fmt do
  @moduledoc """
  Clock/date/duration formatting for the matrix renderers, ported from `Fmt` in
  `priv/static/matrix/fixtures.js`. Takes epoch-ms + IANA tz so callers pass the
  snapshot's `*_utc` integers directly.
  """

  @db Tz.TimeZoneDatabase
  @weekdays {"MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"}
  @months {"JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"}

  defp local(ms, tz) do
    with %DateTime{} = utc <- DateTime.from_unix!(ms, :millisecond),
         {:ok, dt} <- DateTime.shift_zone(utc, tz || "", @db) do
      {:ok, dt}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc "HH:MM, zero-padded. h12? renders 1–12 (caller strips the leading zero)."
  def fmt_clock(ms, tz, h12?) do
    case local(ms, tz) do
      {:ok, dt} ->
        hour = if h12?, do: rem(rem(dt.hour + 11, 12) + 1, 13), else: dt.hour
        "#{pad2(hour)}:#{pad2(dt.minute)}"

      :error ->
        "--:--"
    end
  end

  @doc "Current UTC offset of `tz` at `ms`, in minutes (e.g. -360 for MDT). 0 on error."
  def offset_minutes(ms, tz) do
    case local(ms, tz) do
      {:ok, dt} -> div(dt.utc_offset + dt.std_offset, 60)
      :error -> 0
    end
  end

  def fmt_meridiem(ms, tz) do
    case local(ms, tz) do
      {:ok, dt} -> if dt.hour < 12, do: "AM", else: "PM"
      :error -> ""
    end
  end

  def fmt_weekday(ms, tz) do
    case local(ms, tz) do
      {:ok, dt} -> elem(@weekdays, Date.day_of_week(DateTime.to_date(dt)) - 1)
      :error -> ""
    end
  end

  def fmt_month_day(ms, tz) do
    case local(ms, tz) do
      {:ok, dt} -> "#{elem(@months, dt.month - 1)} #{dt.day}"
      :error -> ""
    end
  end

  def fmt_num_date(ms, tz) do
    case local(ms, tz) do
      {:ok, dt} -> "#{dt.month}/#{dt.day}"
      :error -> ""
    end
  end

  @doc ~S(h:mm with hours, or bare minutes — "2:07" / "47".)
  def fmt_hm(secs) do
    secs = max(0, trunc(secs))
    h = div(secs, 3600)
    m = div(rem(secs, 3600), 60)
    if h > 0, do: "#{h}:#{pad2(m)}", else: "#{m}"
  end

  @doc ~S("2D 18H" / "2D" at ≥24h; "4H 12M" / "47M" / "30S" below.)
  def fmt_dur(secs) do
    secs = max(0, trunc(secs))
    d = div(secs, 86_400)
    h = div(rem(secs, 86_400), 3600)
    m = div(rem(secs, 3600), 60)

    cond do
      d > 0 and h > 0 -> "#{d}D #{h}H"
      d > 0 -> "#{d}D"
      h > 0 -> "#{h}H #{m}M"
      m > 0 -> "#{m}M"
      true -> "#{secs}S"
    end
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
