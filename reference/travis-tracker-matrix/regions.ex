defmodule TravisTracker.Matrix.Regions do
  @moduledoc """
  Helpers that either draw text inline or record a *region* on the framebuffer
  for the trailer (`TravisTracker.Matrix.Trailer`). A region is the contract the
  device/gallery use to animate locally: scroll an overflowing line, or render
  the live clock. The base frame leaves recorded regions blank.
  """
  alias TravisTracker.Matrix.{Framebuffer, Font}

  @scroll_h 7

  @doc """
  Draw `text` in the window `[x, x+w)` at `y`. If it fits, draw it inline
  (`align: :left | :center`). If it overflows `w`, record a `:scroll` region and
  leave the band blank so the device/gallery pan it.
  """
  def scroll_text(fb, x, y, w, text, color, opts \\ []) do
    text = String.upcase(text)

    tw = Font.text_w(text)

    if tw <= w do
      tx =
        case Keyword.get(opts, :align, :left) do
          :center -> round(x + (w - tw) / 2)
          _ -> x
        end

      Font.text(fb, tx, y, text, color)
    else
      Framebuffer.put_region(fb, %{
        kind: :scroll,
        x: x,
        y: y,
        w: w,
        h: @scroll_h,
        text: text,
        color: color,
        speed: Keyword.get(opts, :speed, 24),
        gap: Keyword.get(opts, :gap, 28),
        mode: 0
      })
    end
  end

  @doc """
  Record a `:clock` region centered at `cx`, top `y`, carrying the formatted
  string `str` (for the baked/gallery path) plus the data the device needs to
  re-render it locally: current tz offset (minutes), the server anchor epoch
  (ms), and 12/24h.
  """
  def clock_region(fb, cx, y, str, color, opts) do
    Framebuffer.put_region(fb, %{
      kind: :clock,
      cx: cx,
      y: y,
      scale: 1,
      str: str,
      color: color,
      tz_offset: Keyword.fetch!(opts, :tz_offset),
      anchor: Keyword.fetch!(opts, :anchor),
      h12: Keyword.get(opts, :h12, false)
    })
  end
end
