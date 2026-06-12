defmodule WorldCupTracker.Matrix.WcRenderers do
  @moduledoc """
  The World Cup boards, ported 1:1 from
  `reference/worldcup-design/reference/worldcup/wc-renderers.js`:

    * `:now_next` — live scores up top + the next kickoffs below
    * `:live`     — one match: big flags, big score, minute, match progress.
      With `final: true` (the post-game hold) the live cluster becomes a
      steady `FINAL` (`:win` accent), the bar fills end-to-end with no ball
      head, and the bottom row reads `FULL TIME` instead of the ticking clock
    * `:goal`     — the ~16.5s goal-celebration takeover, a pure function of
      `snap.now - snap.goal_started_at`; at t ≥ 16500ms it hands back to the
      `:live` board.

  Every renderer is a pure `fb, snap -> fb`. All animation reads `snap.now`
  (epoch ms) — never the wall clock — so the same snapshot always renders the
  same bytes. The JS sim's tweak toggles are baked to fixed values, mirroring
  the flight port's convention:

    * `clock24` on (24-hour kickoff clocks)
    * `flagTint` off — codes use the design's fallback colors (leading-team
      white / trailing soft on Now & Next; home white / away ice on Live),
      exactly as the handoff layout sections describe them
    * `flagIcons` on unless the snapshot carries `flags: false`, which selects
      the codes-only hero fallback (`heroScore` in the JS)

  Big numerals use the native Geist Pixel Square bitmap resampled to the
  requested height — a direct port of `nativeGlyph`/`nativeBits` from
  `reference/worldcup-design/reference/matrix/fontblit.js` (the existing
  `Matrix.Geist` only blits at the design cap height of 19; these boards need
  h=20 and h=18).
  """

  alias WorldCupTracker.Matrix.{Flags, Fmt, Font, Framebuffer, Glyphs, Palette, Teams}

  @tz_db Tz.TimeZoneDatabase

  # Literal colors used by the goal celebration (not palette tokens in the JS).
  @goal_white {0xFF, 0xFF, 0xFF}
  @sparkle_white {0xDF, 0xE8, 0xFF}

  @spec render(map) :: Framebuffer.t()
  def render(%{state: state} = snap), do: dispatch(Framebuffer.new(), state, snap)

  defp dispatch(fb, :now_next, snap), do: now_next(fb, snap)
  defp dispatch(fb, :live, snap), do: live(fb, snap)
  defp dispatch(fb, :goal, snap), do: goal(fb, snap)

  # ── shared helpers ───────────────────────────────────────────────────────

  defp pal(name), do: Palette.color(name)

  defp blink?(now), do: rem(div(now, 600), 2) == 0

  defp show_flags?(snap), do: Map.get(snap, :flags, true)

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # Advance of a 5×7 string as the JS drawText returns it (6px per char,
  # including the trailing gap — one more than Font.text_w/1).
  defp text_adv(str), do: String.length(str) * 6

  # Kickoff label (Fmt.fmtKO): bare HH:MM if it's today, else weekday + time.
  defp ko(ms, tz, now) do
    t = Fmt.fmt_clock(ms, tz, false)
    if day_key(ms, tz) == day_key(now, tz), do: t, else: Fmt.fmt_weekday(ms, tz) <> " " <> t
  end

  defp day_key(ms, tz) do
    with %DateTime{} = utc <- DateTime.from_unix!(ms, :millisecond),
         {:ok, dt} <- DateTime.shift_zone(utc, tz || "", @tz_db) do
      DateTime.to_date(dt)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp hline(fb, x, y, w, c), do: Framebuffer.rect(fb, x, y, w, 1, c, 1.0)

  defp dot(fb, cx, cy, r, c), do: Glyphs.disc(fb, cx, cy, r, c)

  defp mini_flag(fb, x, y, w, h, code, true = _flags?), do: Flags.draw(fb, x, y, w, h, code)
  defp mini_flag(fb, _x, _y, _w, _h, _code, false), do: fb

  # ════════════════════════════════════════════════════════════════════════
  #  NOW & NEXT — live scores up top, the next kickoffs below.
  # ════════════════════════════════════════════════════════════════════════
  defp now_next(fb, snap) do
    now = snap.now
    tz = snap.tz
    f? = show_flags?(snap)

    fb = now_next_header(fb, snap)

    # Idle (no live matches) with a next kickoff cached: the empty y=9..29
    # band features that match as a big-flag hero, and the NEXT rows below
    # show the kickoffs AFTER it. With live rows up top the band belongs to
    # them and the NEXT rows are simply the next three kickoffs. Either way
    # at most three rows are drawn — a 4-deep next list never runs off-panel.
    idle_hero? = snap.live == [] and snap.next != []

    {fb, rows} =
      if idle_hero? do
        {idle_hero(fb, hd(snap.next), now, tz, f?), snap.next |> Enum.drop(1) |> Enum.take(3)}
      else
        # live rows: flag · code · score · code · flag · minute
        fb =
          snap.live
          |> Enum.with_index()
          |> Enum.reduce(fb, fn {m, i}, acc ->
            now_next_live_row(acc, m, 10 + i * 10, now, f?)
          end)

        {fb, Enum.take(snap.next, 3)}
      end

    # divider + NEXT label
    label_end = 4 + Font.text_w("NEXT") + 4

    fb =
      fb
      |> Font.text(4, 31, "NEXT", pal(:dim))
      |> hline(label_end, 34, 124 - label_end, pal(:faint))

    # Next kickoffs. Every row shares ONE column grid derived from the widest
    # kickoff time so the codes, flags, "V" and times line up vertically.
    gap = 2
    code_w = Font.text_w("AAA")
    home_x = if f?, do: 16, else: 3
    home_end = home_x + code_w

    # Enum.max default: an empty row list (cold start, tournament over, or a
    # lone hero match) must render a valid frame, not crash the serving layer.
    max_time_w =
      rows
      |> Enum.map(fn m -> ko_w(ko(m.kickoff_utc, m[:tz] || tz, now), gap) end)
      |> Enum.max(fn -> 0 end)

    away_right = min(80, 124 - max_time_w - 4)
    away_code_right_for = fn ar -> ar - if(f?, do: 12, else: 0) end

    # V centres on a whole pixel only when the code gap is odd → nudge away +1px
    away_right =
      if rem(away_code_right_for.(away_right) - code_w - home_end, 2) == 0,
        do: away_right + 1,
        else: away_right

    away_flag_x = away_right - if(f?, do: 10, else: 0)
    away_code_right = away_code_right_for.(away_right)
    away_start = away_code_right - code_w
    v_x = div(home_end + away_start - Font.text_w("V"), 2)

    rows
    |> Enum.with_index()
    |> Enum.reduce(fb, fn {m, i}, acc ->
      ny = 39 + i * 9
      time = ko(m.kickoff_utc, m[:tz] || tz, now)

      {wd, cl} =
        case String.split(time, " ", parts: 2) do
          [w, c] -> {w, c}
          [c] -> {nil, c}
        end

      acc =
        acc
        |> mini_flag(3, ny, 10, 7, m.home, f?)
        |> Font.text(home_x, ny, m.home, pal(:soft))
        |> mini_flag(away_flag_x, ny, 10, 7, m.away, f?)
        |> Font.text_right(away_code_right, ny, m.away, pal(:soft))
        |> Font.text(v_x, ny, "V", pal(:dim))
        |> Font.text_right(124, ny, cl, pal(:soft))

      if wd,
        do: Font.text_right(acc, 124 - Font.text_w(cl) - gap, ny, wd, pal(:dim)),
        else: acc
    end)
  end

  # The featured next kickoff, drawn in the y=9..29 band the live rows would
  # otherwise occupy: a 26×17 flag per side at the live board's hero geometry
  # (x=6 and x=122-26), with two lines centred on x=64 between them —
  # "HOME V AWAY" (codes white, V dim) over the kickoff label (gold time,
  # dim weekday when it isn't today). `flags: false` keeps the same two
  # centred lines with no flags (the codes-only hero fallback).
  defp idle_hero(fb, m, now, tz, f?) do
    {fw, fh, fy} = {26, 17, 10}

    fb =
      if f? do
        fb
        |> Flags.draw(6, fy, fw, fh, m.home)
        |> Flags.draw(122 - fw, fy, fw, fh, m.away)
      else
        fb
      end

    # line 1: "HOME V AWAY" on the shared 6px-per-char advance, centred as one
    # string so the V lands exactly between the codes.
    x0 = round(64 - Font.text_w(m.home <> " V " <> m.away) / 2)

    fb =
      fb
      |> Font.text(x0, 12, m.home, pal(:wc_white))
      |> Font.text(x0 + text_adv(m.home <> " "), 12, "V", pal(:dim))
      |> Font.text(x0 + text_adv(m.home <> " V "), 12, m.away, pal(:wc_white))

    # line 2: the kickoff label, centred as a single unit — bare gold HH:MM
    # when it's today, dim weekday + tight 2px gap + gold time otherwise.
    gap = 2
    time = ko(m.kickoff_utc, m[:tz] || tz, now)

    case String.split(time, " ", parts: 2) do
      [cl] ->
        Font.text_center(fb, 64, 21, cl, pal(:gold))

      [wd, cl] ->
        tx = round(64 - ko_w(time, gap) / 2)

        fb
        |> Font.text(tx, 21, wd, pal(:dim))
        |> Font.text(tx + Font.text_w(wd) + gap, 21, cl, pal(:gold))
    end
  end

  # Header at y=1. With live matches: pulsing dot + LIVE, exactly as the
  # design spec. Idle (no live matches): a countdown to the earliest next
  # kickoff ("KICKOFF 2H 14M"), or just "WORLD CUP" when nothing is cached.
  # The weekday stays right-aligned at x=124 in every case.
  defp now_next_header(fb, %{live: [_ | _]} = snap) do
    now = snap.now
    fb = if blink?(now), do: dot(fb, 6, 4, 1, pal(:live)), else: fb

    fb
    |> Font.text(11, 1, "LIVE", pal(:live))
    |> Font.text_right(124, 1, Fmt.fmt_weekday(now, snap.tz), pal(:dim))
  end

  defp now_next_header(fb, %{live: []} = snap) do
    now = snap.now

    fb =
      case snap.next do
        [] ->
          Font.text(fb, 4, 1, "WORLD CUP", pal(:soft))

        next ->
          next_ko = next |> Enum.map(& &1.kickoff_utc) |> Enum.min()
          countdown_x = 4 + Font.text_w("KICKOFF") + 4

          fb
          |> Font.text(4, 1, "KICKOFF", pal(:soft))
          |> Font.text(countdown_x, 1, countdown_label(next_ko - now), pal(:gold))
      end

    Font.text_right(fb, 124, 1, Fmt.fmt_weekday(now, snap.tz), pal(:dim))
  end

  @minute_ms 60_000
  @hour_ms 60 * @minute_ms
  @day_ms 24 * @hour_ms

  @doc """
  Compact countdown label for `delta_ms` until kickoff: the leading unit is
  floored, the second is the remainder.

      >= 24h   "1D 2H"
      >= 1h    "2H 14M"
      >= 1min  "14M"
      < 1min   "SOON"   (including slightly negative — kickoff has passed but
                         the feed hasn't flipped the match to live yet)
  """
  @spec countdown_label(integer) :: String.t()
  def countdown_label(delta_ms) when delta_ms < @minute_ms, do: "SOON"

  def countdown_label(delta_ms) when delta_ms < @hour_ms,
    do: "#{div(delta_ms, @minute_ms)}M"

  def countdown_label(delta_ms) when delta_ms < @day_ms,
    do: "#{div(delta_ms, @hour_ms)}H #{div(rem(delta_ms, @hour_ms), @minute_ms)}M"

  def countdown_label(delta_ms),
    do: "#{div(delta_ms, @day_ms)}D #{div(rem(delta_ms, @day_ms), @hour_ms)}H"

  defp now_next_live_row(fb, m, y, now, f?) do
    minute = max(0, div(now - m.kickoff_utc, 60_000))
    # no trailing "'" so digits right-align with the clocks below
    status = if m[:ht], do: "HT", else: Integer.to_string(minute)

    lead =
      cond do
        m.hs > m.as -> :h
        m.as > m.hs -> :a
        true -> nil
      end

    score = "#{m.hs}-#{m.as}"
    x = 3
    fb = mini_flag(fb, x, y, 10, 7, m.home, f?)
    x = if f?, do: x + 13, else: x
    fb = Font.text(fb, x, y, m.home, code_col(lead == :h))
    x = x + text_adv(m.home) + 3
    fb = Font.text(fb, x, y, score, pal(:wc_white))
    x = x + text_adv(score) + 3
    fb = Font.text(fb, x, y, m.away, code_col(lead == :a))
    x = x + text_adv(m.away) + 2

    fb
    |> mini_flag(x, y, 10, 7, m.away, f?)
    |> Font.text_right(124, y, status, pal(:gold))
  end

  defp code_col(true = _leading?), do: pal(:wc_white)
  defp code_col(false), do: pal(:soft)

  # Width of a kickoff label drawn with the tight 2px weekday gap.
  defp ko_w(time, gap) do
    case String.split(time, " ", parts: 2) do
      [wd, cl] -> Font.text_w(wd) + gap + Font.text_w(cl)
      [t] -> Font.text_w(t)
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  #  LIVE — one match: big flags, big score, minute, match progress.
  # ════════════════════════════════════════════════════════════════════════
  defp live(fb, snap) do
    m = snap.match
    now = snap.now
    final? = Map.get(snap, :final, false) == true
    minute = snap.minute |> max(0) |> min(95)
    hs = snap.hs |> max(0) |> min(9)
    as = snap.as |> max(0) |> min(9)
    score = "#{hs}-#{as}"

    # status row: stage left; right side is the live cluster (minute, LIVE,
    # pulsing dot) — or, on the post-game hold, a steady FINAL in the design's
    # result accent.
    fb = Font.text(fb, 4, 2, m.stage, pal(:soft))

    fb =
      if final?,
        do: Font.text_right(fb, 124, 2, "FINAL", pal(:win)),
        else: live_status(fb, minute, now)

    fb =
      if show_flags?(snap) do
        # big-flag hero: a 26×17 flag over each code, big score centred between
        {fw, fh, fy} = {26, 17, 11}

        fb
        |> Flags.draw(6, fy, fw, fh, m.home)
        |> Flags.draw(122 - fw, fy, fw, fh, m.away)
        |> Font.text_center(6 + div(fw, 2), fy + fh + 2, m.home, pal(:wc_white))
        |> Font.text_center(122 - div(fw, 2), fy + fh + 2, m.away, pal(:ice))
        |> big_center(64, 13, score, 20, pal(:wc_white))
      else
        hero_score(fb, 14, m.home, m.away, score, pal(:wc_white), pal(:ice), pal(:wc_white))
      end

    fb = hline(fb, 8, 40, 112, pal(:faint))

    if final? do
      # full pitch fill, no ball head, no ticking clock — the game is over
      fb
      |> match_bar(8, 46, 112, 90, pal(:pitch), false)
      |> Font.text_right(120, 54, "FULL TIME", pal(:soft))
    else
      half = if minute <= 45, do: "1ST HALF", else: "2ND HALF"

      fb
      |> match_bar(8, 46, 112, minute, pal(:pitch), true)
      |> Font.text(8, 54, "#{minute}:#{pad2(rem(div(now, 1000), 60))}", pal(:wc_white))
      |> Font.text_right(120, 54, half, pal(:soft))
    end
  end

  # The in-play status cluster, right-packed to x=124: minute, LIVE, pulse dot.
  defp live_status(fb, minute, now) do
    rx = 124
    fb = Font.text_right(fb, rx, 2, "#{minute}'", pal(:gold))
    rx = rx - Font.text_w("#{minute}'") - 5
    fb = Font.text_right(fb, rx, 2, "LIVE", pal(:live))

    if blink?(now),
      do: dot(fb, rx - Font.text_w("LIVE") - 4, 5, 1, pal(:live)),
      else: fb
  end

  # ORIG s-s DEST hero — codes flank a big centred score (flags-off fallback).
  defp hero_score(fb, y, home, away, score, home_col, away_col, score_col) do
    fb
    |> Font.text_2x(6, y, home, home_col)
    |> Font.text_2x(122 - Font.text_2x_w(away), y, away, away_col)
    |> big_center(64, y - 2, score, 18, score_col)
  end

  # Match-progress bar (0..90), faint trough + pitch fill; `ball?` adds the
  # rolling ball head (dropped on the FINAL hold — nothing is rolling).
  defp match_bar(fb, x, y, w, minute, color, ball?) do
    pct = minute / 90
    pct = pct |> max(0) |> min(1)

    fb =
      Enum.reduce(0..(w - 1), fb, fn i, acc -> Framebuffer.add(acc, x + i, y, pal(:faint), 1) end)

    lit = round(pct * w)

    fb =
      Enum.reduce(0..(lit - 1)//1, fb, fn i, acc -> Framebuffer.add(acc, x + i, y, color, 1) end)

    # half (45') tick
    fb = Framebuffer.add(fb, x + round(w / 2), y - 1, pal(:dim), 1)
    if ball?, do: dot(fb, x + lit, y, 1, pal(:ball)), else: fb
  end

  # ════════════════════════════════════════════════════════════════════════
  #  GOAL CELEBRATION — pure function of t = now - goal_started_at.
  #    A (0–1.6s)   strobe burst + flashing GOAL!
  #    B (1.6–13s)  giant GOOOOOOOOOOL marquee over chevrons + sparkles
  #    C (13–16.5s) freeze-frame score reveal, then hand back to :live
  # ════════════════════════════════════════════════════════════════════════
  defp goal(fb, snap) do
    t = snap.now - snap.goal_started_at
    if t >= 16_500, do: live(fb, snap), else: goal_celebration(fb, t, snap)
  end

  defp goal_celebration(fb, t, snap) do
    sec = t / 1000
    col = Teams.color(snap.code)
    hs = snap.hs |> max(0) |> min(9)
    as = snap.as |> max(0) |> min(9)
    f? = show_flags?(snap)

    cond do
      # ── Phase A — strobe burst ──
      sec < 1.6 ->
        on = rem(trunc(sec / 0.13), 2) == 0

        fb
        |> full_wash(col, if(on, do: 0.42, else: 0.10))
        |> sparkles(t, col)
        |> draw_2x_center(64, 18, "GOAL!", if(on, do: @goal_white, else: col))
        |> draw_2x_center(64, 34, snap.code, if(on, do: col, else: @goal_white))

      # ── Phase B — the GOOOOOOOOOOL marquee ──
      sec < 13 ->
        msg =
          "G" <> String.duplicate("O", 26) <> "L!   " <> Teams.name(snap.code) <> " SCORES!   "

        m_w = Font.text_2x_w(msg) + 14
        base = -rem(trunc((sec - 1.6) * 52), m_w)

        fb =
          fb
          |> chevrons(sec, col)
          |> dash_row(17, col, sec)
          |> dash_row(37, col, sec)

        fb =
          base
          |> Stream.iterate(&(&1 + m_w))
          |> Enum.take_while(&(&1 < 128 + m_w))
          |> Enum.reduce(fb, fn x, acc -> Font.text_2x(acc, x, 22, msg, @goal_white) end)

        fb
        |> flag_ribbon(sec, snap.code, 52, f?)
        |> sparkles(t, col)

      # ── Phase C — freeze-frame score reveal ──
      true ->
        rt = sec - 13
        flash = rem(trunc(rt / 0.28), 2) == 0
        {fw, fy} = {26, 20}

        fb
        |> chevrons(sec, col)
        |> sparkles(t, col)
        |> draw_2x_center(64, 1, snap.code <> " GOAL!", if(flash, do: col, else: @goal_white))
        |> mini_flag(6, fy, fw, 17, snap.match.home, f?)
        |> mini_flag(122 - fw, fy, fw, 17, snap.match.away, f?)
        |> big_center(64, 22, "#{hs}-#{as}", 20, @goal_white)
        |> Font.text_center(64, 50, "WHAT A GOAL", pal(:gold))
    end
  end

  defp draw_2x_center(fb, cx, y, str, color),
    do: Font.text_2x(fb, round(cx - Font.text_2x_w(str) / 2), y, str, color)

  # Full-panel wash in the team colour.
  defp full_wash(fb, col, a), do: Framebuffer.rect(fb, 0, 0, 128, 64, col, a)

  # Stadium camera-flash sparkles, scattered + twinkling. Deterministic per t:
  # position is a fixed hash of the sparkle index ((i*53)%123, (i*29)%60) and
  # visibility is a pure phase function of (t, i) — a direct port of the JS.
  defp sparkles(fb, t, col) do
    Enum.reduce(0..25, fb, fn i, acc ->
      phase = t / 1000 * (1.3 + rem(i, 5) * 0.27) + i * 1.7

      if phase - trunc(phase) > 0.16 do
        acc
      else
        hx = rem(i * 53, 123) + 2
        hy = rem(i * 29, 60) + 2
        c = if rem(i, 3) == 0, do: col, else: @sparkle_white
        acc = Framebuffer.add(acc, hx, hy, c, 1)

        if rem(i, 4) == 0 do
          acc
          |> Framebuffer.add(hx - 1, hy, c, 0.5)
          |> Framebuffer.add(hx + 1, hy, c, 0.5)
          |> Framebuffer.add(hx, hy - 1, c, 0.5)
          |> Framebuffer.add(hx, hy + 1, c, 0.5)
        else
          acc
        end
      end
    end)
  end

  # Moving diagonal chevron wash in the team colour (dim background).
  defp chevrons(fb, sec, col) do
    s = trunc(sec * 18)

    for y <- 0..63, x <- 0..127, rem(x + y + s, 14) < 2, reduce: fb do
      acc -> Framebuffer.add(acc, x, y, col, 0.16)
    end
  end

  # Animated dashed rule (ticker frame).
  defp dash_row(fb, y, col, sec) do
    off = trunc(sec * 22)

    for x <- 0..127, rem(x + off, 6) < 3, reduce: fb do
      acc -> Framebuffer.add(acc, x, y, col, 0.55)
    end
  end

  # A continuous ribbon of the scoring team's flag, scrolling.
  defp flag_ribbon(fb, sec, code, y, true = _flags?) do
    if Flags.has?(code) do
      cell = 12 + 4
      base = -rem(trunc(sec * 26), cell)

      base
      |> Stream.iterate(&(&1 + cell))
      |> Enum.take_while(&(&1 < 128))
      |> Enum.reduce(fb, fn x, acc -> Flags.draw(acc, x, y, 12, 8, code) end)
    else
      fb
    end
  end

  defp flag_ribbon(fb, _sec, _code, _y, false), do: fb

  # ── native Geist numerals at arbitrary heights ───────────────────────────
  #
  # Port of `nativeGlyph` / `nativeBits` / `fitCenter` from
  # reference/worldcup-design/reference/matrix/fontblit.js: the design-size
  # bitmap (cap height 19) is area-resampled by scale = h/19 with the same
  # 0.42 coverage threshold, glyphs composed on real advance widths, then the
  # inked string is trimmed and centred.

  @geist_path Application.app_dir(:world_cup_tracker, "priv/matrix/geist-native.json")
  @external_resource @geist_path
  @geist Jason.decode!(File.read!(@geist_path))
  @geist_cap @geist["meta"]["cap_height_cells"]
  @geist_glyphs @geist["glyphs"]
  @geist_space_adv get_in(@geist_glyphs, [" ", "advance"]) || 10

  # Big numerals centred on cx at cap height h (the JS `bigCenter`).
  defp big_center(fb, cx, y, str, h, color) do
    {w, placed} = geist_bits(str, h)
    x0 = round(cx - w / 2)

    for %{x: gx, top: top, lit: lit} <- placed, {ox, oy} <- lit, reduce: fb do
      acc -> Framebuffer.add(acc, x0 + gx + ox, y + top + oy, color, 1.0)
    end
  end

  # Compose a string on real advance widths; returns {inked_width, placed}.
  defp geist_bits(str, h) do
    scale = h / @geist_cap
    space_adv = round(@geist_space_adv * scale)

    {placed, _pen} =
      str
      |> String.graphemes()
      |> Enum.reduce({[], 0}, fn ch, {acc, pen} ->
        case if(ch == " ", do: {:empty, space_adv}, else: geist_glyph(ch, scale)) do
          {:empty, adv} -> {acc, pen + adv}
          {:glyph, g} -> {[%{g | x: pen + g.x} | acc], pen + g.adv}
        end
      end)

    case placed do
      [] ->
        {1, []}

      ps ->
        min_x = ps |> Enum.map(& &1.x) |> Enum.min()
        max_x = ps |> Enum.map(&(&1.x + &1.w)) |> Enum.max()
        {max(1, max_x - min_x), Enum.map(ps, &%{&1 | x: &1.x - min_x})}
    end
  end

  # One glyph resampled to `scale`; {:glyph, %{x(lsb), top, w, adv, lit}} or
  # {:empty, advance} for unknown/inkless characters (mirrors nativeGlyph).
  defp geist_glyph(ch, scale) do
    case @geist_glyphs[ch] do
      %{"bitmap" => bm, "width" => src_w, "yoff" => yoff, "xoff" => xoff, "advance" => adv}
      when src_w > 0 and bm != [] ->
        g_w = max(1, round(src_w * scale))
        g_h = max(1, round(length(bm) * scale))
        inv = 1 / scale

        lit =
          for oy <- 0..(g_h - 1)//1,
              ox <- 0..(g_w - 1)//1,
              resample_lit?(bm, ox, oy, inv),
              do: {ox, oy}

        {:glyph,
         %{
           x: round(xoff * scale),
           top: round((@geist_cap - yoff) * scale),
           w: g_w,
           adv: round(adv * scale),
           lit: lit
         }}

      %{"advance" => adv} ->
        {:empty, round(adv * scale)}

      nil ->
        {:empty, round(@geist_glyphs["0"]["advance"] * scale)}
    end
  end

  # Area-average the source cells covered by output pixel (ox, oy); lit when
  # coverage > 0.42. Out-of-range source cells count toward the total but are
  # unlit, exactly as the JS's undefined-row reads behave.
  defp resample_lit?(bm, ox, oy, inv) do
    sy0 = oy * inv
    sy1 = (oy + 1) * inv
    sx0 = ox * inv
    sx1 = (ox + 1) * inv

    {lit, tot} =
      for sy <- trunc(Float.floor(sy0))..(trunc(Float.ceil(sy1)) - 1)//1,
          sx <- trunc(Float.floor(sx0))..(trunc(Float.ceil(sx1)) - 1)//1,
          reduce: {0, 0} do
        {l, t} ->
          row = Enum.at(bm, sy)
          cell = if row, do: Enum.at(row, sx) || 0, else: 0
          {l + cell, t + 1}
      end

    tot > 0 and lit / tot > 0.42
  end
end
