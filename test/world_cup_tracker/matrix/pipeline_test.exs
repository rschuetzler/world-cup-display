defmodule WorldCupTracker.Matrix.PipelineTest do
  use ExUnit.Case, async: true

  alias WorldCupTracker.Matrix.{
    AltCursor,
    Brightness,
    Fmt,
    Font,
    Framebuffer,
    Geist,
    Regions,
    Rgb565,
    Trailer
  }

  @white {255, 255, 255}
  @frame_bytes 128 * 64 * 2

  describe "framebuffer -> font/geist -> rgb565 pipeline" do
    test "renders text into a 16384-byte non-blank RGB565 frame" do
      fb =
        Framebuffer.new()
        |> Font.text(2, 2, "HI", @white)
        |> Geist.big_center(64, 30, "12", @white)

      bin = Rgb565.encode(fb, :raw)

      assert byte_size(bin) == @frame_bytes
      assert bin != :binary.copy(<<0, 0>>, 128 * 64)

      # 'H' row 0 is 0x11 (bits 10001): leftmost column lit, so pixel (2, 2)
      # is white. Row-major: offset = (y * 128 + x) * 2, little-endian u16.
      offset = (2 * 128 + 2) * 2
      assert <<_::binary-size(offset), 0xFFFF::little-16, _::binary>> = bin

      # The Geist numerals actually lit pixels somewhere on the surface.
      assert Enum.any?(fb.px, fn {{_x, y}, _rgb} -> y >= 30 end)
    end

    test "to565 packs channels as (r5 << 11) | (g6 << 5) | b5" do
      assert Rgb565.to565({255, 255, 255}, :raw) == 0xFFFF
      assert Rgb565.to565({0, 0, 0}, :raw) == 0x0000
      assert Rgb565.to565({255, 0, 0}, :raw) == 0xF800
      assert Rgb565.to565({0, 255, 0}, :raw) == 0x07E0
      assert Rgb565.to565({0, 0, 255}, :raw) == 0x001F
    end
  end

  describe "trailer" do
    test "empty region list yields no trailer" do
      assert Trailer.build([], :raw) == <<>>
    end

    test "scroll region serializes to SCRL header, descriptor, and strip" do
      text = "THIS LINE IS FAR TOO LONG TO FIT"
      fb = Regions.scroll_text(Framebuffer.new(), 4, 10, 40, text, @white)

      # Overflowing text records a region instead of drawing inline.
      assert [%{kind: :scroll}] = Framebuffer.regions(fb)
      assert fb.px == %{}

      strip_w = Font.text_w(text)
      trailer = Trailer.build(Framebuffer.regions(fb), :raw)

      assert <<"SCRL", 1, 1, 0, 4, 10, 40, 7, ^strip_w::little-16, speed, gap, 0, strip::binary>> =
               trailer

      assert speed == 24
      assert gap == 28
      assert byte_size(strip) == strip_w * 7 * 2
      assert strip != :binary.copy(<<0, 0>>, strip_w * 7)
    end
  end

  describe "AltCursor" do
    test "advances one slide per poll, guarded against rapid re-requests" do
      server = start_supervised!({AltCursor, name: :alt_cursor_test})

      t0 = 1_000_000
      assert AltCursor.advance("tok", 3, t0, server) == 0
      # Re-request within the 10s guard holds the slide.
      assert AltCursor.advance("tok", 3, t0 + 5_000, server) == 0
      # A genuine poll (>= 10s later) advances by one.
      assert AltCursor.advance("tok", 3, t0 + 15_000, server) == 1
      assert AltCursor.advance("tok", 3, t0 + 30_000, server) == 2
      # Wraps modulo n.
      assert AltCursor.advance("tok", 3, t0 + 45_000, server) == 0
    end
  end

  describe "Fmt" do
    test "fmt_hm and fmt_dur" do
      assert Fmt.fmt_hm(2 * 3600 + 7 * 60) == "2:07"
      assert Fmt.fmt_hm(47 * 60) == "47"
      assert Fmt.fmt_dur(2 * 86_400 + 18 * 3600) == "2D 18H"
      assert Fmt.fmt_dur(4 * 3600 + 12 * 60) == "4H 12M"
      assert Fmt.fmt_dur(30) == "30S"
    end

    test "fmt_clock falls back to --:-- when the zone cannot be resolved" do
      assert Fmt.fmt_clock(0, nil, false) == "--:--"
    end
  end

  describe "Brightness" do
    test "time-of-day curve and gamma" do
      assert Brightness.for_hour(12.0) == 1.0
      assert Brightness.for_hour(2.0) == 0.25
      assert Brightness.for_hour(7.0) == 0.625
      assert Brightness.gamma(0) == 0
      assert Brightness.gamma(255) == 255
      assert Brightness.apply({255, 255, 255}, 1.0) == {255, 255, 255}
      assert Brightness.apply({255, 255, 255}, 0.0) == {0, 0, 0}
    end
  end
end
