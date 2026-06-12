defmodule WorldCupTracker.Matrix.Glyphs do
  @moduledoc """
  Pixel-art icons and route markers for the LED matrix, ported from
  `priv/static/matrix/fonts.js` (lines 192–315).

  All drawing functions are pure: they accept a `Framebuffer`, paint onto it,
  and return the updated framebuffer. Coordinates follow the JS conventions
  (top-left origin, x right, y down).

  ## Weather icons
  - `disc/5,6` — filled circle (the core primitive)
  - `ring/5,6` — 1-pixel-wide ring
  - `cloud/4,5` — puffy cloud shape, ~16×9, anchored at top-left
  - `draw_weather/5` — full weather glyph selected by a kind atom
  - `weather_kind/2` — maps an OpenWeather icon code or condition string → kind atom

  ## Route markers
  - `arrow/4,5` — clean right-pointing arrow (~9×7)
  - `chevron/4,5` — single ">" chevron (~7×7)
  - `plane/4,5` — top-down jet silhouette (~11×9, nose at right)
  """

  alias WorldCupTracker.Matrix.{Framebuffer, Palette}

  # ── primitive shapes ──────────────────────────────────────────────────────

  @doc """
  Filled disc centred at `(cx, cy)` with radius `r`.

  Uses the same slightly-generous radius formula as the JS original
  (`r*r + r*0.4`) so that small radii produce readable filled circles.
  """
  @spec disc(Framebuffer.t(), integer, integer, integer, Framebuffer.rgb(), number) ::
          Framebuffer.t()
  def disc(fb, cx, cy, r, rgb, a \\ 1.0) do
    r2 = r * r + r * 0.4

    for dy <- -r..r, dx <- -r..r, dx * dx + dy * dy <= r2, reduce: fb do
      acc -> Framebuffer.add(acc, cx + dx, cy + dy, rgb, a)
    end
  end

  @doc """
  1-pixel-wide ring centred at `(cx, cy)` with outer radius `r`.
  """
  @spec ring(Framebuffer.t(), integer, integer, integer, Framebuffer.rgb(), number) ::
          Framebuffer.t()
  def ring(fb, cx, cy, r, rgb, a \\ 1.0) do
    outer = r * r + r * 0.4
    inner = (r - 1) * (r - 1)

    for dy <- -r..r, dx <- -r..r, (d = dx * dx + dy * dy) <= outer and d > inner, reduce: fb do
      acc -> Framebuffer.add(acc, cx + dx, cy + dy, rgb, a)
    end
  end

  @doc """
  Puffy cloud shape, ~16×9 pixels, with its top-left at `(x, y)`.
  """
  @spec cloud(Framebuffer.t(), integer, integer, Framebuffer.rgb(), number) :: Framebuffer.t()
  def cloud(fb, x, y, rgb, a \\ 1.0) do
    fb
    |> disc(x + 5, y + 5, 3, rgb, a)
    |> disc(x + 10, y + 4, 4, rgb, a)
    |> disc(x + 13, y + 6, 3, rgb, a)
    |> Framebuffer.rect(x + 3, y + 6, 12, 3, rgb, a)
  end

  # ── weather ───────────────────────────────────────────────────────────────

  @doc """
  Normalises an OpenWeather icon code and/or a plain-text condition string
  into one of the kind atoms used by `draw_weather/5`.

  The icon code takes precedence when present. The prefix table:

  | Prefix | Kind     |
  |--------|----------|
  | `01`   | `:clear` / `:night` (suffix `n`) |
  | `02`, `03` | `:partly` / `:partly_night` (suffix `n`) |
  | `04`   | `:cloud` |
  | `09`, `10` | `:rain` |
  | `11`   | `:storm` |
  | `13`   | `:snow`  |
  | `50`   | `:cloud` |

  When there is no usable icon the condition string is matched by substring
  (case-insensitive). Unknown inputs default to `:partly`.
  """
  @spec weather_kind(String.t() | nil, String.t() | nil) ::
          :clear | :night | :partly | :partly_night | :cloud | :rain | :snow | :storm
  def weather_kind(icon, condition) do
    if icon do
      prefix = String.slice(icon, 0, 2)
      night = String.slice(icon, 2, 1) == "n"

      case prefix do
        "01" -> if(night, do: :night, else: :clear)
        "02" -> if(night, do: :partly_night, else: :partly)
        "03" -> if(night, do: :partly_night, else: :partly)
        "04" -> :cloud
        "09" -> :rain
        "10" -> :rain
        "11" -> :storm
        "13" -> :snow
        "50" -> :cloud
        _ -> weather_kind_from_condition(condition)
      end
    else
      weather_kind_from_condition(condition)
    end
  end

  defp weather_kind_from_condition(condition) do
    s = String.downcase(condition || "")

    cond do
      String.contains?(s, "storm") or String.contains?(s, "thunder") -> :storm
      String.contains?(s, "snow") -> :snow
      String.contains?(s, "rain") or String.contains?(s, "drizzle") -> :rain
      String.contains?(s, "partly") -> :partly
      String.contains?(s, "cloud") -> :cloud
      String.contains?(s, "clear") -> :clear
      true -> :partly
    end
  end

  @doc """
  Renders a weather glyph in a ~16-pixel-wide box with its top-left at
  `(x, y)`.

  `kind` is one of `:clear, :night, :partly, :partly_night, :cloud, :rain, :snow, :storm`.
  `weather_palette` is a map of `%{sun: rgb, cloud: rgb, rain: rgb, snow: rgb,
  moon: rgb, bolt: rgb}`; pass `Palette.weather/1` values or any custom map.
  """
  @spec draw_weather(
          Framebuffer.t(),
          integer,
          integer,
          :clear | :night | :partly | :partly_night | :cloud | :rain | :snow | :storm | atom,
          %{atom => Framebuffer.rgb()}
        ) :: Framebuffer.t()
  def draw_weather(fb, x, y, kind, weather_palette) do
    sun = Map.get(weather_palette, :sun, Palette.weather(:sun))
    cl = Map.get(weather_palette, :cloud, Palette.weather(:cloud))
    rain = Map.get(weather_palette, :rain, Palette.weather(:rain))
    snow = Map.get(weather_palette, :snow, Palette.weather(:snow))
    moon = Map.get(weather_palette, :moon, Palette.weather(:moon))
    bolt = Map.get(weather_palette, :bolt, Palette.weather(:bolt))

    # Dark colour used to "bite out" the crescent moon shape (#06070a)
    crescent_dark = {6, 7, 10}

    case kind do
      :clear ->
        rays = [{8, 0}, {8, 12}, {2, 6}, {14, 6}, {4, 2}, {12, 2}, {4, 10}, {12, 10}]

        fb
        |> disc(x + 8, y + 6, 3, sun)
        |> then(fn f ->
          Enum.reduce(rays, f, fn {rx, ry}, acc ->
            Framebuffer.add(acc, x + rx, y + ry, sun)
          end)
        end)

      :night ->
        fb
        |> disc(x + 8, y + 6, 4, moon)
        |> disc(x + 10, y + 4, 4, crescent_dark)

      :partly ->
        mini_rays = [{5, 0}, {1, 4}, {9, 4}, {2, 1}, {8, 1}]

        fb
        |> disc(x + 5, y + 4, 2, sun)
        |> then(fn f ->
          Enum.reduce(mini_rays, f, fn {rx, ry}, acc ->
            Framebuffer.add(acc, x + rx, y + ry, sun)
          end)
        end)
        |> cloud(x + 2, y + 4, cl)

      :partly_night ->
        fb
        |> disc(x + 5, y + 4, 2, moon)
        |> disc(x + 6, y + 3, 2, crescent_dark)
        |> cloud(x + 2, y + 4, cl)

      :cloud ->
        cloud(fb, x, y + 2, cl)

      :rain ->
        drops = [{5, 0}, {9, 0}, {13, 0}]

        fb
        |> cloud(x, y, cl)
        |> then(fn f ->
          Enum.reduce(drops, f, fn {rx, ry}, acc ->
            acc
            |> Framebuffer.add(x + rx, y + 10 + ry, rain)
            |> Framebuffer.add(x + rx - 1, y + 12 + ry, rain)
          end)
        end)

      :snow ->
        flakes = [{5, 11}, {9, 12}, {13, 11}]

        fb
        |> cloud(x, y, cl)
        |> then(fn f ->
          Enum.reduce(flakes, f, fn {rx, ry}, acc ->
            Framebuffer.add(acc, x + rx, y + ry, snow)
          end)
        end)

      :storm ->
        fb
        |> cloud(x, y, cl)
        |> Framebuffer.add(x + 8, y + 10, bolt)
        |> Framebuffer.add(x + 7, y + 11, bolt)
        |> Framebuffer.add(x + 9, y + 11, bolt)
        |> Framebuffer.add(x + 7, y + 12, bolt)
        |> Framebuffer.add(x + 8, y + 13, bolt)

      _ ->
        cloud(fb, x, y + 2, cl)
    end
  end

  # ── route markers ─────────────────────────────────────────────────────────

  @doc """
  Clean right-pointing arrow, ~9×7 pixels, centred at `(cx, cy)`.

  This is the default route-segment separator between airports.
  """
  @spec arrow(Framebuffer.t(), integer, integer, Framebuffer.rgb(), number) :: Framebuffer.t()
  def arrow(fb, cx, cy, rgb, a \\ 1.0) do
    cx = round(cx)
    cy = round(cy)

    fb
    |> Framebuffer.rect(cx - 4, cy, 9, 1, rgb, a)
    |> Framebuffer.add(cx + 1, cy - 3, rgb, a)
    |> Framebuffer.add(cx + 2, cy - 2, rgb, a)
    |> Framebuffer.add(cx + 3, cy - 1, rgb, a)
    |> Framebuffer.add(cx + 1, cy + 3, rgb, a)
    |> Framebuffer.add(cx + 2, cy + 2, rgb, a)
    |> Framebuffer.add(cx + 3, cy + 1, rgb, a)
  end

  @doc """
  Single ">" chevron, ~7×7 pixels, centred at `(cx, cy)`.
  """
  @spec chevron(Framebuffer.t(), integer, integer, Framebuffer.rgb(), number) :: Framebuffer.t()
  def chevron(fb, cx, cy, rgb, a \\ 1.0) do
    cx = round(cx)
    cy = round(cy)

    Enum.reduce(0..3, fb, fn i, acc ->
      acc
      |> Framebuffer.add(cx - 2 + i, cy - 3 + i, rgb, a)
      |> Framebuffer.add(cx - 2 + i, cy + 3 - i, rgb, a)
    end)
  end

  @doc """
  Map-style top-down jet silhouette, ~11×9 pixels, centred at `(cx, cy)`,
  nose pointing right.

  Built from solid rectangular shapes so it reads clearly at 1 px per LED.
  """
  @spec plane(Framebuffer.t(), integer, integer, Framebuffer.rgb(), number) :: Framebuffer.t()
  def plane(fb, cx, cy, rgb, a \\ 1.0) do
    cx = round(cx)
    cy = round(cy)

    fb
    |> Framebuffer.rect(cx - 4, cy - 1, 9, 3, rgb, a)
    |> Framebuffer.add(cx + 5, cy, rgb, a)
    |> Framebuffer.rect(cx - 1, cy - 4, 2, 9, rgb, a)
    |> Framebuffer.rect(cx - 4, cy - 2, 1, 5, rgb, a)
  end
end
