defmodule TravisTracker.Matrix.Rgb565 do
  @moduledoc """
  Encodes a `Framebuffer` to the 16 KB little-endian RGB565 blob the device
  consumes (row-major, top-left origin). `:raw` skips correction (browser
  preview on an sRGB monitor); `{:corrected, scalar}` applies gamma + a global
  brightness scale (the panel path).
  """
  import Bitwise
  alias TravisTracker.Matrix.{Framebuffer, Brightness}

  @spec to565(Framebuffer.rgb(), :raw | {:corrected, number}) :: non_neg_integer
  def to565(rgb, mode) do
    {r, g, b} = correct(rgb, mode)
    (r >>> 3) <<< 11 ||| (g >>> 2) <<< 5 ||| b >>> 3
  end

  @spec encode(Framebuffer.t(), :raw | {:corrected, number}) :: binary
  def encode(fb, mode) do
    for y <- 0..(Framebuffer.height() - 1)//1,
        x <- 0..(Framebuffer.width() - 1)//1,
        into: <<>> do
      <<to565(Framebuffer.get(fb, x, y), mode)::little-16>>
    end
  end

  @doc "Encode the top-left `w`×`h` region of `fb` (origin 0,0) — used for scroll-text strips."
  @spec encode_rect(Framebuffer.t(), pos_integer, pos_integer, :raw | {:corrected, number}) ::
          binary
  def encode_rect(fb, w, h, mode) when w > 0 and h > 0 do
    for y <- 0..(h - 1)//1, x <- 0..(w - 1)//1, into: <<>> do
      <<to565(Framebuffer.get(fb, x, y), mode)::little-16>>
    end
  end

  defp correct(rgb, :raw), do: rgb
  defp correct(rgb, {:corrected, scalar}), do: Brightness.apply(rgb, scalar)
end
