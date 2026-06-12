defmodule WorldCupTracker.Matrix.WcRenderersTest do
  use ExUnit.Case, async: true

  alias WorldCupTracker.Matrix.{DisplayFixtures, Palette, Rgb565, WcRenderers}

  @frame_bytes 128 * 64 * 2
  @black_frame :binary.copy(<<0, 0>>, 128 * 64)

  defp frame(snap), do: snap |> WcRenderers.render() |> Rgb565.encode(:raw)

  describe "frame envelope" do
    test "every board renders a 16384-byte non-black RGB565 frame" do
      snaps = [
        DisplayFixtures.now_next(),
        DisplayFixtures.now_next_idle(),
        DisplayFixtures.live(),
        DisplayFixtures.goal(500),
        DisplayFixtures.goal(6_000),
        DisplayFixtures.goal(14_000)
      ]

      for snap <- snaps do
        bin = frame(snap)
        assert byte_size(bin) == @frame_bytes
        refute bin == @black_frame
      end
    end
  end

  describe ":now_next" do
    test "draws gold minute digits in the right column and white score pixels" do
      fb = WcRenderers.render(DisplayFixtures.now_next())
      gold = Palette.color(:gold)
      white = Palette.color(:wc_white)

      # Minute "78" / "HT" right-aligned at x=124 over the two live rows
      # (y=10 and y=20, glyphs 7px tall).
      assert Enum.any?(fb.px, fn {{x, y}, c} ->
               c == gold and x in 108..124 and y in 10..27
             end)

      # The "2-1" / "1-1" scores render in the board white inside the live rows.
      assert Enum.any?(fb.px, fn {{x, y}, c} ->
               c == white and x in 30..60 and y in 10..27
             end)
    end
  end

  describe "countdown_label/1" do
    test "formats deltas with a floored leading unit and minute remainder" do
      min = 60_000
      hr = 60 * min

      assert WcRenderers.countdown_label(30_000) == "SOON"
      assert WcRenderers.countdown_label(-10_000) == "SOON"
      assert WcRenderers.countdown_label(14 * min) == "14M"
      assert WcRenderers.countdown_label(2 * hr + 14 * min) == "2H 14M"
      assert WcRenderers.countdown_label(26 * hr) == "1D 2H"
    end

    test "exact unit boundaries" do
      assert WcRenderers.countdown_label(60_000) == "1M"
      assert WcRenderers.countdown_label(3_600_000) == "1H 0M"
    end
  end

  describe ":now_next idle header" do
    @live_red Palette.color(:live)

    defp header_pixels(fb), do: Enum.filter(fb.px, fn {{_x, y}, _c} -> y in 0..8 end)

    test "no live matches: countdown header, no live-red pixels anywhere up top" do
      fb = WcRenderers.render(DisplayFixtures.now_next_idle())
      bin = Rgb565.encode(fb, :raw)
      assert byte_size(bin) == @frame_bytes

      header = header_pixels(fb)
      refute Enum.any?(header, fn {{_x, _y}, c} -> c == @live_red end)

      # "KICKOFF" in soft, then the gold countdown ("47M" for the fixture).
      assert Enum.any?(header, fn {{_x, _y}, c} -> c == Palette.color(:soft) end)
      assert Enum.any?(header, fn {{_x, _y}, c} -> c == Palette.color(:gold) end)
    end

    test "empty next list falls back to WORLD CUP, still no live red" do
      snap = %{DisplayFixtures.now_next_idle() | next: []}
      fb = WcRenderers.render(snap)
      header = header_pixels(fb)

      refute Enum.any?(header, fn {{_x, _y}, c} -> c == @live_red end)
      assert Enum.any?(header, fn {{_x, _y}, c} -> c == Palette.color(:soft) end)
    end

    test "with live rows present the header keeps the live-red LIVE pill" do
      fb = WcRenderers.render(DisplayFixtures.now_next())
      assert Enum.any?(header_pixels(fb), fn {{_x, _y}, c} -> c == @live_red end)
    end
  end

  describe ":live" do
    test "progress fill width tracks the minute" do
      # Rightmost strongly-green pixel on the bar row (trough is faint
      # {47,58,89}; both the pitch fill and the ball head push green ≥ 200).
      extent = fn minute ->
        fb = WcRenderers.render(%{DisplayFixtures.live() | minute: minute})

        fb.px
        |> Enum.filter(fn {{_x, y}, {_r, g, _b}} -> y == 46 and g >= 200 end)
        |> Enum.map(fn {{x, _y}, _c} -> x end)
        |> Enum.max()
      end

      lit = fn minute -> round(112 * minute / 90) end
      assert extent.(80) - extent.(10) == lit.(80) - lit.(10)
      assert extent.(80) > extent.(10)
    end
  end

  describe ":live final hold" do
    @win Palette.color(:win)

    defp status_row(fb), do: Enum.filter(fb.px, fn {{_x, y}, _c} -> y in 0..8 end)

    test "live_final renders a full non-black frame" do
      bin = frame(DisplayFixtures.live_final())
      assert byte_size(bin) == @frame_bytes
      refute bin == @black_frame
    end

    test "the status row swaps the LIVE cluster for FINAL in :win" do
      fb = WcRenderers.render(DisplayFixtures.live_final())
      status = status_row(fb)

      refute Enum.any?(status, fn {{_x, _y}, c} -> c == Palette.color(:live) end)
      assert Enum.any?(status, fn {{x, _y}, c} -> c == @win and x in 94..124 end)
    end

    test "the regular live board keeps LIVE red and shows no :win up top" do
      fb = WcRenderers.render(DisplayFixtures.live())
      status = status_row(fb)

      assert Enum.any?(status, fn {{_x, _y}, c} -> c == Palette.color(:live) end)
      refute Enum.any?(status, fn {{_x, _y}, c} -> c == @win end)
    end

    test "the progress bar fills end to end with no ball head" do
      fb = WcRenderers.render(DisplayFixtures.live_final())
      ball = Palette.color(:ball)

      bar_max =
        fb.px
        |> Enum.filter(fn {{_x, y}, {_r, g, _b}} -> y == 46 and g >= 200 end)
        |> Enum.map(fn {{x, _y}, _c} -> x end)
        |> Enum.max()

      # full 112px fill: x in 8..119, and nothing drawn in the ball white
      assert bar_max == 119
      refute Enum.any?(fb.px, fn {{_x, y}, c} -> y in 44..48 and c == ball end)
    end

    test "nothing ticks: frames are identical across now" do
      now = DisplayFixtures.default_now()

      assert frame(DisplayFixtures.live_final(now)) ==
               frame(DisplayFixtures.live_final(now + 600))
    end
  end

  describe ":goal" do
    test "frames at t=500/6000/14000 are pairwise different" do
      frames = for t <- [500, 6_000, 14_000], do: frame(DisplayFixtures.goal(t))
      assert frames |> Enum.uniq() |> length() == 3
    end

    test "t >= 16500 hands back to the :live board" do
      goal_snap = DisplayFixtures.goal(17_000)
      assert frame(goal_snap) == frame(%{goal_snap | state: :live})
    end
  end

  describe "determinism" do
    test "the same snap always renders identical bytes" do
      for snap <- [
            DisplayFixtures.now_next(),
            DisplayFixtures.now_next_idle(),
            DisplayFixtures.live(),
            DisplayFixtures.goal(800)
          ] do
        assert frame(snap) == frame(snap)
      end
    end

    test "the blink dot follows the 600ms cycle off snap.now" do
      now = DisplayFixtures.default_now()
      a = frame(DisplayFixtures.now_next(now))
      b = frame(DisplayFixtures.now_next(now + 600))
      refute a == b
    end
  end
end
