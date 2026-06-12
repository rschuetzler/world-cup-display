defmodule WorldCupTracker.Matrix.Framebuffer do
  @moduledoc """
  A logical 128×64 RGB surface for the LED matrix. Stored as a sparse map of
  only the lit pixels (`{x, y} => {r, g, b}`); everything unset is black. All
  drawing helpers are pure and return an updated framebuffer.

  Mirrors the semantics of `priv/static/matrix/led-core.js`: `add/4` is additive
  and clamps each channel at 255 (so overlapping writes stack), `set/4` replaces,
  `rect/6` is an additive fill. Off-panel coordinates are silently ignored so
  callers can blit near the edges without bounds-checking.

  Note: `set/4` takes no alpha argument (unlike the JS `set`); callers that need dimming should pass a pre-scaled `{r,g,b}` tuple.
  """

  @w 128
  @h 64

  # `w`/`h` are per-instance so off-buffer writes clip to the actual surface.
  # The kiosk frame is the 128×64 default; wider surfaces (e.g. marquee text
  # strips, which can exceed 128px) pass explicit dims via `new/2` so glyphs
  # past column 127 aren't silently dropped.
  defstruct px: %{}, regions: [], w: @w, h: @h

  @type rgb :: {0..255, 0..255, 0..255}
  @type t :: %__MODULE__{
          px: %{optional({integer, integer}) => rgb},
          regions: [map],
          w: pos_integer,
          h: pos_integer
        }

  @spec width() :: pos_integer()
  def width, do: @w

  @spec height() :: pos_integer()
  def height, do: @h

  @spec new() :: t
  def new, do: %__MODULE__{}

  @spec new(pos_integer, pos_integer) :: t
  def new(w, h) when w > 0 and h > 0, do: %__MODULE__{w: w, h: h}

  @spec regions(t) :: [map]
  def regions(%__MODULE__{regions: regions}), do: regions

  @spec put_region(t, map) :: t
  def put_region(%__MODULE__{regions: regions} = fb, region),
    do: %{fb | regions: regions ++ [region]}

  @spec clear(t) :: t
  def clear(%__MODULE__{} = fb), do: %{fb | px: %{}}

  @spec get(t, integer, integer) :: rgb
  def get(%__MODULE__{px: px}, x, y), do: Map.get(px, {x, y}, {0, 0, 0})

  @spec set(t, integer, integer, rgb) :: t
  def set(%__MODULE__{px: px, w: w, h: h} = fb, x, y, rgb)
      when x in 0..(w - 1)//1 and y in 0..(h - 1)//1,
      do: %{fb | px: Map.put(px, {x, y}, rgb)}

  def set(fb, _x, _y, _rgb), do: fb

  @spec add(t, integer, integer, rgb, number) :: t
  def add(fb, x, y, rgb, a \\ 1.0)

  def add(%__MODULE__{px: px, w: w, h: h} = fb, x, y, {r, g, b}, a)
      when x in 0..(w - 1)//1 and y in 0..(h - 1)//1 do
    {cr, cg, cb} = Map.get(px, {x, y}, {0, 0, 0})

    blended =
      {min(255, round(cr + r * a)), min(255, round(cg + g * a)), min(255, round(cb + b * a))}

    %{fb | px: Map.put(px, {x, y}, blended)}
  end

  def add(fb, _x, _y, _rgb, _a), do: fb

  @spec rect(t, integer, integer, integer, integer, rgb, number) :: t
  def rect(fb, x, y, w, h, rgb, a \\ 1.0) do
    for xx <- 0..(w - 1)//1, yy <- 0..(h - 1)//1, reduce: fb do
      acc -> add(acc, x + xx, y + yy, rgb, a)
    end
  end

  def hline(fb, x, y, w, rgb, a \\ 1.0), do: rect(fb, x, y, w, 1, rgb, a)
  def vline(fb, x, y, h, rgb, a \\ 1.0), do: rect(fb, x, y, 1, h, rgb, a)
end
