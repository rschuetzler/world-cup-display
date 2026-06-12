defmodule WorldCupTracker.Matrix.Palette do
  @moduledoc """
  Named colors for the matrix renderers, ported from the `P` and `WX` maps in
  `priv/static/matrix/renderers.js`. Each is an `{r, g, b}` tuple (0–255).
  """

  # P — from renderers.js:21-25
  @p %{
    white: {0xD4, 0xE3, 0xFF},
    soft: {0x9F, 0xB2, 0xD8},
    dim: {0x5E, 0x6E, 0x92},
    faint: {0x2F, 0x3A, 0x59},
    cyan: {0x54, 0xC6, 0xFF},
    ice: {0x8A, 0xB0, 0xFF},
    green: {0x5C, 0xE0, 0x98},
    amber: {0xFF, 0xB4, 0x54},
    red: {0xFF, 0x6F, 0x6F},
    sun: {0xFF, 0xCE, 0x5C},
    warm: {0xFF, 0xD9, 0xA0},

    # World Cup board palette — from the `P` map in
    # reference/worldcup-design/reference/worldcup/wc-renderers.js. Where the
    # WC hex matches an existing flight token (soft, dim, faint, ice) the
    # existing token is reused; where it differs the WC value gets its own
    # token so the flight tokens stay untouched:
    #   wc_white #e4ecff (flight :white is #d4e3ff)
    #   live     #ff5454 (flight :red   is #ff6f6f)
    #   gold     #ffcf5c (flight :sun   is #ffce5c)
    #   win      #5ce098 (same value as flight :green, named per the handoff)
    wc_white: {0xE4, 0xEC, 0xFF},
    live: {0xFF, 0x54, 0x54},
    gold: {0xFF, 0xCF, 0x5C},
    pitch: {0x46, 0xD0, 0x7F},
    win: {0x5C, 0xE0, 0x98},
    ball: {0xEA, 0xF2, 0xFF}
  }

  # WX — from renderers.js:26
  @wx %{
    sun: {0xFF, 0xCE, 0x5C},
    cloud: {0x9F, 0xB4, 0xD6},
    rain: {0x5C, 0xC6, 0xFF},
    snow: {0xDF, 0xF0, 0xFF},
    moon: {0xCD, 0xD7, 0xEE},
    bolt: {0xFF, 0xD1, 0x66}
  }

  def color(name), do: Map.fetch!(@p, name)
  def weather(name), do: Map.fetch!(@wx, name)
end
