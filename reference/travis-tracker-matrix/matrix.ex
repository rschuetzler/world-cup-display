defmodule TravisTracker.Matrix do
  @moduledoc """
  Public entry point for matrix rendering. `render/1` turns a raw display
  snapshot (fixture map or live struct) into a `Framebuffer`; `to_rgb565/2`
  encodes the device/preview bytes. Both normalize the snapshot internally.
  """
  alias TravisTracker.Matrix.{
    Snapshot,
    Renderers,
    Rgb565,
    Brightness,
    Framebuffer,
    Trailer,
    Geist
  }

  @spec render(map | struct) :: TravisTracker.Matrix.Framebuffer.t()
  def render(snapshot), do: snapshot |> Snapshot.normalize() |> Renderers.render()

  @doc """
  Encode a snapshot to the 16 KB RGB565 blob, optionally with a region trailer.

  Options:
  - `:mode` — `:raw` (browser preview) or `:corrected` (device; default).
  - `:brightness` — override scalar (0.0–1.0); only used in `:corrected` mode.
  - `:live_clock` — when `true`, clock regions are emitted to the trailer (device
    path) and the base frame leaves them blank. When `false` (default), clock
    regions are baked into the base frame before encoding.
  """
  @spec to_rgb565(map | struct, keyword) :: binary
  def to_rgb565(snapshot, opts \\ []) do
    norm = Snapshot.normalize(snapshot)
    fb = Renderers.render(norm)
    live_clock? = Keyword.get(opts, :live_clock, false)

    encode_mode =
      case Keyword.get(opts, :mode, :corrected) do
        :raw ->
          :raw

        :corrected ->
          scalar =
            case Keyword.get(opts, :brightness) do
              nil -> Brightness.for_zone(norm.timezone, norm.now)
              b when is_number(b) -> max(0.0, min(1.0, b))
            end

          {:corrected, scalar}
      end

    regions = Framebuffer.regions(fb)

    {base_fb, trailer_regions} =
      if live_clock? do
        # Clock pixels are absent from base (clock_region records metadata only);
        # emit all regions to the trailer.
        {fb, regions}
      else
        # Bake clock regions into the base frame; only scroll regions go to
        # the trailer (scroll regions must always be in the trailer — baking
        # a marquee into the base frame would only show the initial position).
        clock_regions = Enum.filter(regions, &(&1.kind == :clock))
        scroll_regions = Enum.filter(regions, &(&1.kind == :scroll))
        baked_fb = Enum.reduce(clock_regions, fb, &bake_clock(&2, &1))
        {baked_fb, scroll_regions}
      end

    base = Rgb565.encode(base_fb, encode_mode)
    trailer = Trailer.build(trailer_regions, encode_mode)
    base <> trailer
  end

  # Bake a clock region into the base frame (gallery/web path). Gamma/brightness
  # correction is applied later by Rgb565.encode, so the raw region color is used.
  defp bake_clock(fb, region),
    do: Geist.big_center(fb, region.cx, region.y, region.str, region.color)
end
