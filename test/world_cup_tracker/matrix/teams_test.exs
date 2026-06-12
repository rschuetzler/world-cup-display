defmodule WorldCupTracker.Matrix.TeamsTest do
  use ExUnit.Case, async: true

  alias WorldCupTracker.Matrix.Teams

  # Tier 1: the hand-picked entries from wc-data.js (ITA did not qualify for
  # the 48-team cup and was dropped).
  @hand_picked ~w(USA MEX CAN BRA ARG FRA ENG ESP GER POR NED BEL CRO URU COL JPN KOR SEN MAR AUS SUI)

  # Tier 2: derived from the baked flag assets' accent colors.
  @derived ~w(ALG AUT BIH CIV COD CPV CUW CZE ECU EGY GHA HAI IRN IRQ JOR KSA NOR NZL PAN PAR QAT RSA SCO SWE TUN TUR UZB)

  # teamC1's fallback in wc-data.js: '#e4ecff'.
  @fallback_color {0xE4, 0xEC, 0xFF}

  test "all 48 teams are present with a name and an {r, g, b} color" do
    assert length(Teams.codes()) == 48
    assert Enum.sort(@hand_picked ++ @derived) == Enum.sort(Teams.codes())

    for code <- Teams.codes() do
      assert %{name: name, color: {r, g, b}} = Teams.get(code)
      assert is_binary(name)
      assert Enum.all?([r, g, b], &(&1 in 0..255))
    end
  end

  test "MEX carries the hand-picked color and full name (tier 1 untouched)" do
    assert Teams.color("MEX") == {0x34, 0xC8, 0x78}
    assert Teams.name("MEX") == "MEXICO"
    assert Teams.get("MEX") == %{name: "MEXICO", color: {0x34, 0xC8, 0x78}}
  end

  test "derived teams carry font-safe marquee names" do
    assert Teams.name("BIH") == "BOSNIA-HERZEGOVINA"
    assert Teams.name("CIV") == "IVORY COAST"
    assert Teams.name("TUR") == "TURKIYE"
  end

  test "derived teams get a real flag accent, not the white fallback" do
    qat = Teams.color("QAT")
    assert qat != @fallback_color
    # QAT's maroon field: clearly non-white (red channel dominates).
    assert {r, g, b} = qat
    assert r > g and r > b
  end

  test "unknown codes fall back like the JS helpers" do
    assert Teams.get("XYZ") == nil
    # teamC1 falls back to #e4ecff
    assert Teams.color("XYZ") == @fallback_color
    # teamName falls back to the code itself
    assert Teams.name("XYZ") == "XYZ"
  end

  test "ITA (did not qualify) is gone and takes the unknown-code path" do
    assert Teams.get("ITA") == nil
    assert Teams.name("ITA") == "ITA"
    assert Teams.color("ITA") == @fallback_color
  end
end
