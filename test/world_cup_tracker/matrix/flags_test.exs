defmodule WorldCupTracker.Matrix.FlagsTest do
  use ExUnit.Case, async: true

  alias WorldCupTracker.Matrix.{Flags, Framebuffer}

  # Asset palette entries the assertions touch (LED-tuned, from gen_flags.py
  # output in priv/matrix/flags.json).
  @red {0xEE, 0x3B, 0x3B}
  @white {0xEE, 0xF2, 0xFF}
  # "black" flag fields render as dim grey, not unlit
  @dim_black {0x26, 0x2B, 0x38}
  @grey {0x3A, 0x41, 0x50}

  # The three sizes the boards draw, which have baked bitmaps.
  @board_sizes [{26, 17}, {12, 8}, {10, 7}]

  # Draw a flag at the origin of a fresh framebuffer and return it.
  defp flag(code, w, h), do: Flags.draw(Framebuffer.new(), 0, 0, w, h, code)

  describe "codes/0 and has?/1" do
    test "all 48 World Cup teams have a baked flag" do
      assert length(Flags.codes()) == 48
      assert Flags.codes() == Enum.sort(Flags.codes())
      assert Enum.all?(Flags.codes(), &Flags.has?/1)
    end

    test "teams the procedural samplers never covered are now present" do
      for code <- ~w(BIH QAT PAR HAI CUW CPV) do
        assert Flags.has?(code), "expected baked flag for #{code}"
      end
    end

    test "unknown codes are not claimed" do
      refute Flags.has?("ZZZ")
    end
  end

  describe "baked bitmaps at 26x17" do
    test "GER's black stripe is the dim grey, not pure black" do
      fb = flag("GER", 26, 17)
      assert Framebuffer.get(fb, 0, 0) == @dim_black
      refute Framebuffer.get(fb, 0, 0) == {0, 0, 0}
    end

    test "JPN is a red disc on white" do
      fb = flag("JPN", 26, 17)
      assert Framebuffer.get(fb, 13, 8) == @red
      assert Framebuffer.get(fb, 0, 0) == @white
      assert Framebuffer.get(fb, 25, 16) == @white
    end
  end

  describe "draw/6" do
    # Exact board sizes blit the baked bitmap; 20x13 exercises the
    # nearest-neighbor path from the 26x17 art.
    for {w, h} <- @board_sizes ++ [{20, 13}] do
      test "fills exactly the #{w}x#{h} rect and nothing outside it" do
        {w, h} = {unquote(w), unquote(h)}
        {ox, oy} = {5, 5}
        fb = Flags.draw(Framebuffer.new(), ox, oy, w, h, "FRA")

        # Assets are fully opaque, so every cell in the rect is lit...
        for fx <- 0..(w - 1), fy <- 0..(h - 1) do
          assert Framebuffer.get(fb, ox + fx, oy + fy) != {0, 0, 0}
        end

        # ...and only those cells were written.
        assert map_size(fb.px) == w * h

        for {x, y} <- [
              {ox - 1, oy},
              {ox, oy - 1},
              {ox + w, oy},
              {ox, oy + h},
              {ox + w, oy + h}
            ] do
          assert Framebuffer.get(fb, x, y) == {0, 0, 0}
        end
      end
    end

    test "odd sizes nearest-neighbor scale from the 26x17 art" do
      # NN source for (0,0) at any size is the 26x17 origin pixel: GER's
      # top-left is the dim-grey black stripe.
      fb = flag("GER", 20, 13)
      assert Framebuffer.get(fb, 0, 0) == @dim_black
    end

    test "unknown code draws the JS grey/dim checker box" do
      fb = Flags.draw(Framebuffer.new(), 0, 0, 4, 4, "ZZZ")
      assert Framebuffer.get(fb, 0, 0) == @dim_black
      assert Framebuffer.get(fb, 1, 0) == @grey
      assert map_size(fb.px) == 16
    end

    test "all 48 flags draw at every board size with no holes" do
      for code <- Flags.codes(), {w, h} <- @board_sizes do
        fb = flag(code, w, h)
        assert map_size(fb.px) == w * h, "#{code} left holes at #{w}x#{h}"
      end
    end
  end
end
