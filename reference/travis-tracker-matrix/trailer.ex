defmodule TravisTracker.Matrix.Trailer do
  @moduledoc """
  Serializes render regions (see `TravisTracker.Matrix.Regions`) into the
  optional binary trailer appended after the 16 KB base frame. See
  `docs/matrix-display-protocol.md` for the wire format. Scroll strips are
  rendered through the same `Rgb565` correction as the base frame so brightness
  and gamma match.
  """
  alias TravisTracker.Matrix.{Framebuffer, Font, Rgb565}

  @magic "SCRL"
  @version 1

  @spec build([map], :raw | {:corrected, number}) :: binary
  def build([], _mode), do: <<>>

  def build(regions, mode) do
    descriptors = regions |> Enum.map(&descriptor(&1, mode)) |> IO.iodata_to_binary()

    strips =
      regions
      |> Enum.filter(&(&1.kind == :scroll))
      |> Enum.map(&strip(&1, mode))
      |> IO.iodata_to_binary()

    @magic <> <<@version, length(regions)>> <> descriptors <> strips
  end

  defp descriptor(%{kind: :scroll} = r, _mode) do
    <<0, r.x, r.y, r.w, r.h, Font.text_w(r.text)::little-16, r.speed, r.gap, r.mode>>
  end

  defp descriptor(%{kind: :clock} = r, mode) do
    flags = if r.h12, do: 1, else: 0

    <<1, r.cx, r.y, r.scale, Rgb565.to565(r.color, mode)::little-16,
      r.tz_offset::little-signed-16, flags, r.anchor::little-64>>
  end

  defp strip(%{kind: :scroll} = r, mode) do
    sw = Font.text_w(r.text)

    # The strip can be wider than the 128px kiosk frame, so render onto a
    # strip-sized surface — a default 128-wide framebuffer would clip glyphs
    # past column 127 (the tail of a long marquee line would vanish).
    Framebuffer.new(sw, r.h)
    |> Font.text(0, 0, r.text, r.color)
    |> Rgb565.encode_rect(sw, r.h, mode)
  end
end
