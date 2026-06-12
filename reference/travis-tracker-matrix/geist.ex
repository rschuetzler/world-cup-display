defmodule TravisTracker.Matrix.Geist do
  @moduledoc """
  Native Geist Pixel Square numerals (the idle/layover clock), ported from
  `nativeGlyph`/`nativeBits` in `priv/static/matrix/fontblit.js`, specialized to
  the only size the renderers use — cap height 19, i.e. scale 1.0 → a pixel-exact
  1:1 blit of the glyph bitmaps in `priv/matrix/geist-native.json`.
  """
  alias TravisTracker.Matrix.Framebuffer, as: FB

  @json_path Application.app_dir(:travis_tracker, "priv/matrix/geist-native.json")
  @external_resource @json_path
  @font Jason.decode!(File.read!(@json_path))
  @cap @font["meta"]["cap_height_cells"]
  @glyphs @font["glyphs"]
  @space_adv @glyphs[" "]["advance"] || 10

  # placed glyph: {x, top, width, lit} where lit is a list of {gx, gy}
  defp placed(str) do
    str
    |> String.graphemes()
    |> Enum.reduce({0, []}, fn ch, {pen, acc} ->
      case @glyphs[ch] do
        nil ->
          {pen + @space_adv, acc}

        %{"bitmap" => bm, "xoff" => xoff, "yoff" => yoff, "advance" => adv, "width" => w} ->
          lit =
            for {row, gy} <- Enum.with_index(bm), {1, gx} <- Enum.with_index(row), do: {gx, gy}

          {pen + adv, [{pen + xoff, @cap - yoff, w, lit} | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  @doc "Inked width of a string in the native numerals."
  def string_w(str) do
    case placed(str) do
      [] ->
        1

      ps ->
        min_x = ps |> Enum.map(fn {x, _t, _w, _l} -> x end) |> Enum.min()
        max_x = ps |> Enum.map(fn {x, _t, w, _l} -> x + w end) |> Enum.max()
        max(1, max_x - min_x)
    end
  end

  def big_center(fb, cx, y, str, color, a \\ 1.0),
    do: blit(fb, round(cx - string_w(str) / 2), y, str, color, a)

  defp blit(fb, x0, y0, str, color, a) do
    ps = placed(str)
    min_x = ps |> Enum.map(fn {x, _t, _w, _l} -> x end) |> Enum.min(fn -> 0 end)

    for {gx0, top, _w, lit} <- ps, {gx, gy} <- lit, reduce: fb do
      acc -> FB.add(acc, x0 + (gx0 - min_x) + gx, y0 + top + gy, color, a)
    end
  end
end
