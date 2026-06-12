defmodule WorldCupTracker.Matrix.Teams do
  @moduledoc """
  World Cup team table, ported from the `TEAMS` map in
  `reference/worldcup-design/reference/worldcup/wc-flags.js`'s sibling
  `wc-data.js`. Maps a 3-letter code to the full country name (the goal
  marquee uses names; the boards use codes) and the team's accent color.

  The color is the LED-friendly flag accent used when "flag tint" is on —
  tuned for a fine-pitch panel: bright, single-chroma, never muddy. (Generic
  country marks only — no federation emblems.)

  The 48 teams come in two tiers:

    * **Hand-picked** — the entries ported from `wc-data.js`. Their names and
      accent colors are design-authoritative and kept verbatim. (The original
      reference had 22; ITA did not qualify for the 48-team cup and has no
      flag asset, so its entry was dropped — unknown-code fallbacks cover it.)
    * **Derived** — the other 27 teams. Names are font-safe ASCII (the goal
      marquee renders "<NAME> SCORES!"); colors are the `"accent"` field the
      designer asset pipeline bakes into `priv/matrix/flags.json`
      (see `tools/gen_flags.py`), loaded at compile time.

  Unknown codes fall back like the JS helpers do: `name/1` returns the code
  itself, and `color/1` returns `#e4ecff` — the design's "white" text color
  (note: brighter than `Palette.color(:white)`, which is the flight build's
  `#d4e3ff`).
  """

  @typedoc "A team entry: full name plus the LED-tuned flag accent color."
  @type team :: %{name: String.t(), color: WorldCupTracker.Matrix.Framebuffer.rgb()}

  # teamC1's fallback in wc-data.js: '#e4ecff'.
  @fallback_color {0xE4, 0xEC, 0xFF}

  # ── tier 1: hand-picked — from wc-data.js:18-41 (c1 hex → {r, g, b}) ───────
  @hand_picked %{
    "USA" => %{name: "USA", color: {0x5B, 0x8C, 0xFF}},
    "MEX" => %{name: "MEXICO", color: {0x34, 0xC8, 0x78}},
    "CAN" => %{name: "CANADA", color: {0xFF, 0x5C, 0x5C}},
    "BRA" => %{name: "BRAZIL", color: {0xFF, 0xD2, 0x3F}},
    "ARG" => %{name: "ARGENTINA", color: {0x6C, 0xC4, 0xF5}},
    "FRA" => %{name: "FRANCE", color: {0x5B, 0x8C, 0xFF}},
    "ENG" => %{name: "ENGLAND", color: {0xD7, 0xE2, 0xFB}},
    "ESP" => %{name: "SPAIN", color: {0xFF, 0x5C, 0x5C}},
    "GER" => %{name: "GERMANY", color: {0xFF, 0xCE, 0x5C}},
    "POR" => %{name: "PORTUGAL", color: {0xFF, 0x6F, 0x6F}},
    "NED" => %{name: "NETHERLANDS", color: {0xFF, 0x9D, 0x3C}},
    "BEL" => %{name: "BELGIUM", color: {0xFF, 0xCE, 0x5C}},
    "CRO" => %{name: "CROATIA", color: {0xFF, 0x5C, 0x5C}},
    "URU" => %{name: "URUGUAY", color: {0x6C, 0xC4, 0xF5}},
    "COL" => %{name: "COLOMBIA", color: {0xFF, 0xD2, 0x3F}},
    "JPN" => %{name: "JAPAN", color: {0x5B, 0x8C, 0xFF}},
    "KOR" => %{name: "KOREA", color: {0xFF, 0x5C, 0x5C}},
    "SEN" => %{name: "SENEGAL", color: {0x34, 0xC8, 0x78}},
    "MAR" => %{name: "MOROCCO", color: {0xFF, 0x5C, 0x5C}},
    "AUS" => %{name: "AUSTRALIA", color: {0xFF, 0xD2, 0x3F}},
    "SUI" => %{name: "SWITZERLAND", color: {0xFF, 0x5C, 0x5C}}
  }

  # ── tier 2: derived — accent color from the baked flag assets ──────────────
  @json_path Application.app_dir(:world_cup_tracker, "priv/matrix/flags.json")
  @external_resource @json_path
  @accents Map.new(Jason.decode!(File.read!(@json_path)), fn {code, %{"accent" => hex}} ->
             <<r, g, b>> = Base.decode16!(hex, case: :lower)
             {code, {r, g, b}}
           end)

  @derived_names %{
    "ALG" => "ALGERIA",
    "AUT" => "AUSTRIA",
    "BIH" => "BOSNIA-HERZEGOVINA",
    "CIV" => "IVORY COAST",
    "COD" => "DR CONGO",
    "CPV" => "CABO VERDE",
    "CUW" => "CURACAO",
    "CZE" => "CZECHIA",
    "ECU" => "ECUADOR",
    "EGY" => "EGYPT",
    "GHA" => "GHANA",
    "HAI" => "HAITI",
    "IRN" => "IRAN",
    "IRQ" => "IRAQ",
    "JOR" => "JORDAN",
    "KSA" => "SAUDI ARABIA",
    "NOR" => "NORWAY",
    "NZL" => "NEW ZEALAND",
    "PAN" => "PANAMA",
    "PAR" => "PARAGUAY",
    "QAT" => "QATAR",
    "RSA" => "SOUTH AFRICA",
    "SCO" => "SCOTLAND",
    "SWE" => "SWEDEN",
    "TUN" => "TUNISIA",
    "TUR" => "TURKIYE",
    "UZB" => "UZBEKISTAN"
  }

  # Map.fetch! so a missing flag asset is a compile error, not a silent hole.
  @derived Map.new(@derived_names, fn {code, name} ->
             {code, %{name: name, color: Map.fetch!(@accents, code)}}
           end)

  # Hand-picked entries win on any overlap (they are design-authoritative).
  @teams Map.merge(@derived, @hand_picked)

  @doc "The full team entry for `code`, or `nil` if unknown."
  @spec get(String.t()) :: team | nil
  def get(code), do: Map.get(@teams, code)

  @doc "Full country name (`teamName` in the JS). Unknown codes echo the code."
  @spec name(String.t()) :: String.t()
  def name(code) do
    case get(code) do
      %{name: name} -> name
      nil -> code
    end
  end

  @doc "Flag accent color (`teamC1` in the JS). Unknown codes get neutral white."
  @spec color(String.t()) :: WorldCupTracker.Matrix.Framebuffer.rgb()
  def color(code) do
    case get(code) do
      %{color: color} -> color
      nil -> @fallback_color
    end
  end

  @doc "All known 3-letter codes."
  @spec codes() :: [String.t()]
  def codes, do: Map.keys(@teams)
end
