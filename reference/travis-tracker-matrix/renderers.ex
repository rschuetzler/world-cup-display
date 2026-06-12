defmodule TravisTracker.Matrix.Renderers do
  @moduledoc """
  One function per kiosk display state, rendering to a `Framebuffer`. Ported 1:1
  from `priv/static/matrix/renderers.js`. The clock is read from `snap.now`
  (epoch ms, deterministic); the preview-only tweak toggles are baked to fixed
  defaults: labels=cities, clock24, marker=arrow, Geist numerals.
  """
  alias TravisTracker.Matrix.{Framebuffer, Font, Glyphs, Fmt, Palette, Regions}

  # The shared weather palette, built once and threaded into draw_weather.
  defp wx do
    %{
      sun: Palette.weather(:sun),
      cloud: Palette.weather(:cloud),
      rain: Palette.weather(:rain),
      snow: Palette.weather(:snow),
      moon: Palette.weather(:moon),
      bolt: Palette.weather(:bolt)
    }
  end

  @spec render(map) :: Framebuffer.t()
  def render(%{state: state} = snap), do: dispatch(Framebuffer.new(), state, snap)

  # Render one alternating member onto an existing framebuffer (no fresh fb),
  # dispatching on its own state — mirrors the JS MEMBER_FN table.
  defp render_member(fb, %{state: state} = member), do: dispatch(fb, state, member)

  # State → renderer dispatch. Both render/1 (fresh fb) and render_member/2
  # (existing fb) funnel through here so members reuse the same boards.
  defp dispatch(fb, :idle, snap), do: idle(fb, snap)
  defp dispatch(fb, :trip_pending, snap), do: trip_pending(fb, snap)
  defp dispatch(fb, :layover, snap), do: layover(fb, snap)
  defp dispatch(fb, :pre_flight, snap), do: pre_flight(fb, snap)
  defp dispatch(fb, :taxiing, snap), do: taxiing(fb, snap)
  defp dispatch(fb, :in_flight, snap), do: in_flight(fb, snap)
  defp dispatch(fb, :post_flight, snap), do: post_flight(fb, snap)
  defp dispatch(fb, :alternating, snap), do: alternating(fb, snap)
  defp dispatch(fb, _other, snap), do: idle(fb, snap)

  # ── IDLE — resting face: big clock, date, weather strip. ───────────────
  defp idle(fb, snap) do
    tz = snap.timezone
    now = snap.now

    fb
    |> Regions.clock_region(64, 3, fmt_clk(now, tz), Palette.color(:white),
      tz_offset: Fmt.offset_minutes(now, tz),
      anchor: now,
      h12: false
    )
    # Vertical rhythm is tightened by 1px per gap (clock→date→line→weather→
    # description) so the description clears the alternation indicator pills at
    # y=61. Each row below the clock shifts up by the count of tightened gaps
    # above it: date -1, line -2, weather row -3, description -4.
    |> Font.text_center(
      64,
      25,
      Fmt.fmt_weekday(now, tz) <> " " <> Fmt.fmt_month_day(now, tz),
      Palette.color(:cyan)
    )
    |> Framebuffer.hline(18, 34, 92, Palette.color(:faint))
    |> Glyphs.draw_weather(
      8,
      36,
      Glyphs.weather_kind(snap.weather_icon, snap.weather_condition),
      wx()
    )
    |> Font.text(30, 38, fmt_temp(snap.weather_temperature_f), Palette.color(:white))
    # Location label: the home-airport IATA when present (compact 3-char code),
    # else the weather-city override's city name (no IATA). The override is a
    # free-form "City, State, Country" string ("Orem, UT, US") — keep only the
    # leading city token, since the rest won't fit the panel.
    |> Font.text_right(
      122,
      38,
      loc_label(snap.weather_iata || snap.weather_city),
      Palette.color(:cyan)
    )
    |> Font.text_center(64, 52, String.upcase(snap.weather_condition || ""), Palette.color(:soft))
  end

  # ── TRIP PENDING — booked but hours out; big countdown. ────────────────
  defp trip_pending(fb, snap) do
    f = snap.next_flight
    now = snap.now
    secs = div(f[:scheduled_depart_utc] - now, 1000)

    right = "#{f[:airline_iata]}#{f[:flight_number]}"
    {left, lc} = title_or(snap, "NEXT TRIP", Palette.color(:soft), title_chars(right))

    fb
    |> Font.text(4, 2, left, lc)
    |> Font.text_right(124, 2, right, Palette.color(:dim))
    |> hero_codes(
      12,
      f[:origin_iata],
      f[:destination_iata],
      Palette.color(:white),
      Palette.color(:cyan),
      Palette.color(:white)
    )
    |> Font.text(4, 29, fit_city(f[:origin_city], 9), Palette.color(:dim))
    |> Font.text_right(124, 29, fit_city(f[:destination_city], 9), Palette.color(:cyan))
    |> Framebuffer.hline(8, 38, 112, Palette.color(:faint))
    |> Font.text(
      4,
      41,
      "DEP " <> hm12(f[:scheduled_depart_utc], f[:origin_tz]),
      Palette.color(:white)
    )
    |> Font.text_right(
      124,
      41,
      "ARR " <> hm12(f[:scheduled_arrive_utc], f[:destination_tz]),
      Palette.color(:soft)
    )
    |> Font.text_center(64, 51, "IN " <> Fmt.fmt_dur(secs), Palette.color(:cyan))
  end

  # Time-to-next threshold: at ≥11h a 12-hour clock reading becomes ambiguous
  # ("2:00" — today or tomorrow?), so switch to a countdown.
  @next_countdown_threshold_ms 11 * 3600 * 1000

  # ── STAY — resting face for the connecting city + next leg. ─────────────
  defp layover(fb, snap) do
    tz = snap[:city_tz] || snap.timezone
    now = snap.now
    next = snap.next_flight

    right = fit_city(snap.city, 12)
    {left, lc} = title_or(snap, "STAY", Palette.color(:dim), title_chars(right))

    fb =
      fb
      |> Font.text(4, 1, left, lc)
      |> Font.text_right(124, 1, right, Palette.color(:cyan))
      |> Regions.clock_region(64, 9, fmt_clk(now, tz), Palette.color(:white),
        tz_offset: Fmt.offset_minutes(now, tz),
        anchor: now,
        h12: false
      )
      |> Font.text_center(
        64,
        29,
        Fmt.fmt_weekday(now, tz) <> " " <> Fmt.fmt_month_day(now, tz),
        Palette.color(:soft)
      )
      |> stay_weather(snap)

    cond do
      snap[:recent_landing] ->
        recent_landing_pill(fb, snap)

      seg = snap[:next_segment] ->
        next_line(
          fb,
          (seg[:label] || "") <> " > " <> (seg[:city] || ""),
          seg[:arrival_utc],
          seg[:city_tz] || tz,
          now
        )

      next ->
        next_line(
          fb,
          next[:origin_iata] <> ">" <> next[:destination_iata],
          next[:scheduled_depart_utc],
          next[:origin_tz],
          now
        )

      true ->
        fb
    end
  end

  # Weather as one centered group (icon, 3px gap, temp) — no condition text,
  # so nothing can bleed across the temperature. Rendered on the plain AND
  # landed-pill variants (the pill replaces only the NEXT line).
  defp stay_weather(fb, snap) do
    temp = fmt_temp(snap.weather_temperature_f)
    icon_w = 16
    gap = 3
    gx = round((128 - (icon_w + gap + Font.text_w(temp))) / 2)

    fb
    |> Glyphs.draw_weather(
      gx,
      36,
      Glyphs.weather_kind(snap.weather_icon, snap.weather_condition),
      wx()
    )
    |> Font.text(gx + icon_w + gap, 38, temp, Palette.color(:white))
  end

  # Bottom "NEXT" line: amber label, route (scrolls when it overflows the
  # window), clock-or-countdown on the right.
  defp next_line(fb, route, when_ms, tz, now) do
    t = next_time_label(when_ms, now, tz)
    l_end = 4 + Font.text_w("NEXT")
    r_start = 124 - Font.text_w(t)

    fb
    |> Framebuffer.hline(8, 51, 112, Palette.color(:faint))
    |> Font.text(4, 54, "NEXT", Palette.color(:amber))
    |> Regions.scroll_text(l_end + 4, 54, r_start - l_end - 8, route, Palette.color(:white),
      align: :center
    )
    |> Font.text_right(124, 54, t, Palette.color(:cyan))
  end

  @doc """
  Right-side label for the Stay page's NEXT line: the local clock time when
  the event is near, a bare duration ("2D 18H") once it is ≥11h out (a 12-hour clock
  would be ambiguous past that). Public for direct unit testing.
  """
  def next_time_label(when_ms, now_ms, tz) when is_integer(when_ms) do
    if when_ms - now_ms >= @next_countdown_threshold_ms do
      Fmt.fmt_dur(div(when_ms - now_ms, 1000))
    else
      hm12(when_ms, tz)
    end
  end

  # Schema-level the timestamps are non-nullable, but a wall display should
  # degrade to "--:--" (the old behavior), never crash on bad data.
  def next_time_label(_when_ms, _now_ms, tz), do: hm12(nil, tz)

  # ── PRE-FLIGHT — at the gate: gate / ETD, live countdown. ──────────────
  defp pre_flight(fb, snap) do
    f = snap.flight
    now = snap.now
    di = delay_info(f)

    {right, right_color} =
      if di.late?,
        do: {"DELAYED +#{di.mins}M", Palette.color(:amber)},
        else: {"ON TIME", Palette.color(:green)}

    {left, lc} =
      title_or(
        snap,
        "#{f[:airline_iata]}#{f[:flight_number]}",
        Palette.color(:soft),
        title_chars(right)
      )

    fb =
      fb
      |> Font.text(4, 2, left, lc)
      |> Font.text_right(124, 2, right, right_color)

    fb =
      fb
      |> hero_codes(
        12,
        f[:origin_iata],
        f[:destination_iata],
        Palette.color(:white),
        Palette.color(:cyan),
        Palette.color(:white)
      )
      |> Font.text(4, 29, fit_city(f[:origin_city], 9), Palette.color(:dim))
      |> Font.text_right(124, 29, fit_city(f[:destination_city], 9), Palette.color(:cyan))
      |> Framebuffer.hline(8, 38, 112, Palette.color(:faint))
      |> Font.text(4, 41, "GATE " <> (f[:gate] || "--"), Palette.color(:white))
      |> Font.text_right(
        124,
        41,
        "ETD " <> hm12(f[:estimated_depart_utc] || f[:scheduled_depart_utc], f[:origin_tz]),
        Palette.color(:soft)
      )

    if snap[:recent_landing] do
      recent_landing_pill(fb, snap)
    else
      secs = div(f[:scheduled_depart_utc] - now, 1000)
      color = if di.late?, do: Palette.color(:amber), else: Palette.color(:cyan)
      Font.text_center(fb, 64, 51, "DEP IN " <> Fmt.fmt_dur(secs), color)
    end
  end

  # ── TAXIING — out of the gate (departure) or rolling in (arrival). ─────
  defp taxiing(fb, snap) do
    f = snap.flight
    now = snap.now
    down = f[:actual_touchdown_utc]
    is_arr? = !!down
    anchor = if is_arr?, do: down, else: f[:actual_depart_utc] || f[:scheduled_depart_utc]
    elapsed = max(0, div(now - anchor, 1000))
    accent = if is_arr?, do: Palette.color(:green), else: Palette.color(:cyan)

    right = if is_arr?, do: "LANDED", else: "TAXIING"

    {left, lc} =
      title_or(
        snap,
        "#{f[:airline_iata]}#{f[:flight_number]}",
        Palette.color(:soft),
        title_chars(right)
      )

    fb =
      fb
      |> Font.text(4, 2, left, lc)
      |> Font.text_right(124, 2, right, accent)
      |> hero_codes(
        12,
        f[:origin_iata],
        f[:destination_iata],
        if(is_arr?, do: Palette.color(:soft), else: Palette.color(:white)),
        accent,
        Palette.color(:white)
      )
      |> Font.text(4, 29, fit_city(f[:origin_city], 9), Palette.color(:dim))
      |> Font.text_right(124, 29, fit_city(f[:destination_city], 9), Palette.color(:cyan))
      |> Framebuffer.hline(8, 38, 112, Palette.color(:faint))
      |> Font.text(4, 41, "GATE " <> (f[:gate] || "--"), Palette.color(:white))

    fb =
      if is_arr? do
        Font.text_right(
          fb,
          124,
          41,
          "ARR " <> hm12(f[:scheduled_arrive_utc], f[:destination_tz]),
          Palette.color(:soft)
        )
      else
        Font.text_right(
          fb,
          124,
          41,
          "ETD " <> hm12(f[:estimated_depart_utc] || f[:scheduled_depart_utc], f[:origin_tz]),
          Palette.color(:soft)
        )
      end

    Font.text_center(
      fb,
      64,
      51,
      if(is_arr?, do: "LANDED ", else: "OUT OF GATE ") <> Fmt.fmt_dur(elapsed),
      if(is_arr?, do: Palette.color(:green), else: Palette.color(:amber))
    )
  end

  # ── IN-FLIGHT — airborne: over-location, progress + plane marker. ──────
  defp flight_prog(f, now) do
    dep = f[:actual_depart_utc] || f[:scheduled_depart_utc]
    arr = f[:estimated_arrive_utc] || f[:scheduled_arrive_utc]
    pct = if arr > dep, do: max(0, min(1, (now - dep) / (arr - dep))), else: 0
    left = max(0, (arr - now) / 1000)
    flown = max(0, (now - dep) / 1000)
    %{pct: pct, left: left, flown: flown, dep: dep, arr: arr}
  end

  defp in_flight(fb, snap) do
    f = snap.flight
    pos = snap[:position] || %{}
    pr = flight_prog(f, snap.now)

    over =
      (pos[:over] || "")
      |> String.replace(~r/^near /i, "OVER ")
      |> String.upcase()

    over = if pos[:estimated] && over != "", do: "~ " <> over, else: over

    {left, lc} =
      title_or(
        snap,
        "#{f[:airline_iata]}#{f[:flight_number]}",
        Palette.color(:soft),
        title_chars("IN FLIGHT")
      )

    fb
    |> Font.text(4, 2, left, lc)
    |> Font.text_right(124, 2, "IN FLIGHT", Palette.color(:cyan))
    |> hero_codes(
      12,
      f[:origin_iata],
      f[:destination_iata],
      Palette.color(:white),
      Palette.color(:cyan),
      Palette.color(:white)
    )
    |> Regions.scroll_text(4, 30, 120, over, Palette.color(:soft), align: :center)
    |> progress_bar(8, 44, 112, pr.pct, Palette.color(:cyan), plane: true, caps: true)
    |> Font.text(8, 52, "ETA " <> fmt_clk(pr.arr, f[:destination_tz]), Palette.color(:white))
    |> Font.text_right(120, 52, Fmt.fmt_hm(pr.left) <> " LEFT", Palette.color(:soft))
  end

  # ── POST-FLIGHT — just touched down; welcome-home bookend (green). ─────
  defp post_flight(fb, snap) do
    f = snap.flight
    now = snap.now
    down = f[:actual_touchdown_utc]
    since = max(0, div(now - down, 1000))
    on_time? = is_nil(f[:scheduled_arrive_utc]) or down - f[:scheduled_arrive_utc] <= 90_000

    {left, lc} =
      title_or(
        snap,
        "#{f[:airline_iata]}#{f[:flight_number]}",
        Palette.color(:soft),
        title_chars("LANDED")
      )

    fb
    |> Font.text(4, 2, left, lc)
    |> Font.text_right(124, 2, "LANDED", Palette.color(:green))
    |> hero_codes(
      12,
      f[:origin_iata],
      f[:destination_iata],
      Palette.color(:dim),
      Palette.color(:green),
      Palette.color(:green)
    )
    |> Framebuffer.hline(8, 38, 112, Palette.color(:faint))
    |> Font.text(4, 41, "DOWN " <> hm12(down, f[:destination_tz]), Palette.color(:soft))
    |> Font.text_right(
      124,
      41,
      if(on_time?, do: "ON TIME", else: "LATE"),
      if(on_time?, do: Palette.color(:green), else: Palette.color(:amber))
    )
    |> Font.text_center(64, 51, "LANDED " <> Fmt.fmt_dur(since) <> " AGO", Palette.color(:green))
  end

  # ── ALTERNATING — carousel across the snapshot's members. The shown member
  # is selected by wall clock (idx = div(now, dwell) mod n), so each panel poll
  # advances the slide. Renders the member's board + the progress-pill row. ────────
  defp alternating(fb, snap) do
    members = snap[:members] || []

    if members == [] do
      fb
    else
      n = length(members)
      idx = alt_index(snap, n)
      m = Enum.at(members, idx)

      # 1 · the active member's own board. (Each member draws its own title in
      # its top-left slot — see the per-state renderers.)
      # 2 · a static rotation indicator showing which slide of N is active.
      fb
      |> render_member(m)
      |> alt_indicator(n, idx)
    end
  end

  # Which slide to show. The device endpoint advances a per-display cursor one
  # slide per poll and bakes it in as `:alt_index` (see Matrix.AltCursor); the
  # device only ever sees a new slide when it polls, so wall-clock rotation
  # aliases against the poll cadence. The preview gallery has no cursor, so it
  # falls back to a wall-clock index to keep cycling.
  defp alt_index(snap, n) do
    case snap[:alt_index] do
      i when is_integer(i) -> Integer.mod(i, n)
      _ -> rem(div(snap.now, snap[:dwell_ms] || 15_000), n)
    end
  end

  # Static rotation indicator: N stripes bottom-centre, the active one white,
  # the rest a muted blue. The slide only changes when the device re-polls, so a
  # server-baked frame can't animate a moving pill — a static marker of "which
  # of N" is the honest representation.
  defp alt_indicator(fb, n, idx) do
    pw = 18
    ph = 2
    gap = 5
    px0 = round(64 - (n * pw + (n - 1) * gap) / 2)

    Enum.reduce(0..(n - 1), fb, fn i, acc ->
      x = px0 + i * (pw + gap)
      color = if i == idx, do: Palette.color(:white), else: Palette.color(:dim)
      Framebuffer.rect(acc, x, 61, pw, ph, color, 1)
    end)
  end

  # ── shared helpers ─────────────────────────────────────────────────────
  #
  # The shared renderer-helper layer every flight board reuses.

  # 24-hour clock string read from a ms timestamp (clock24 default ⇒ h12 false).
  defp fmt_clk(ms, tz), do: Fmt.fmt_clock(ms, tz, false)

  # Temperature label — "—°" when weather is unavailable (live idle with no
  # cached conditions yet), else the rounded Fahrenheit value.
  defp fmt_temp(nil), do: "—°"
  defp fmt_temp(t), do: "#{round(t)}°"

  # 12-hour clock with the leading zero stripped, no meridiem.
  # JS: fmtClock(ms,tz,true).replace(/^0/, '').
  defp hm12(ms, tz) do
    case Fmt.fmt_clock(ms, tz, true) do
      "0" <> rest -> rest
      s -> s
    end
  end

  # Idle weather-strip location label. An IATA passes through; a free-form
  # "City, State, Country" override is reduced to its leading city token. Both
  # are then fit to the panel width.
  defp loc_label(nil), do: ""
  defp loc_label(s), do: s |> String.split(",") |> hd() |> fit_city(11)

  # Upcase + trim a city label; truncate to `max` chars (re-trimmed).
  defp fit_city(s, max) do
    s = (s || "") |> String.upcase() |> String.trim()
    if String.length(s) <= max, do: s, else: s |> String.slice(0, max) |> String.trim()
  end

  # Alternation title slot: the per-slide "whose is this" title (warm, fit to
  # max_chars) when set on the member snapshot, else the panel's default
  # label/color. Title is set only on alternation members (see Display.State).
  defp title_or(snap, default_text, default_color, max_chars) do
    case snap[:title] do
      t when is_binary(t) and t != "" -> {fit_city(t, max_chars), Palette.color(:warm)}
      _ -> {default_text, default_color}
    end
  end

  # Char budget for a title at x=4 given the right-side text's pixel width
  # (font advance is 6px; 2px guard gap before the right text).
  defp title_chars(right_text) do
    right_left = 124 - Font.text_w(right_text)
    max(0, div(right_left - 4 - 2, 6))
  end

  # Route marker between codes / on the route — fixed to the arrow glyph.
  defp marker(fb, cx, cy, rgb, a \\ 1.0), do: Glyphs.arrow(fb, cx, cy, rgb, a)

  # Hero ORIG→DEST codes in the 2× bitmap face with a route marker between.
  defp hero_codes(fb, y, orig, dest, o_color, m_color, d_color) do
    left = 20

    fb
    |> Font.text_2x(left, y, orig, o_color)
    |> marker(left + 43, y + 7, m_color)
    |> Font.text_2x(left + 52, y, dest, d_color)
  end

  # Delay summary for a flight sub-map.
  defp delay_info(f) do
    mins = f[:delay_minutes] || 0
    %{late?: mins > 0, mins: mins, reason: String.upcase(f[:delay_reason] || "")}
  end

  # Recent-landing pill — filled green badge across the bottom band with
  # knockout text, overlaid on pre_flight / layover.
  defp recent_landing_pill(fb, snap) do
    r = snap.recent_landing
    since = max(0, div(snap.now - r.landed_at_utc, 1000))
    route = r.origin_iata <> ">" <> r.destination_iata
    dur = Fmt.fmt_dur(since)
    y = 54
    h = 9
    x = 3
    w = 122
    pad = 6
    ty = y + 1
    kn = {6, 35, 17}

    l_end = x + pad + Font.knock_w("LANDED")
    d_start = x + w - pad - Font.knock_w(dur)

    fb
    |> Framebuffer.rect(x + 1, y, w - 2, h, Palette.color(:green), 1)
    |> Framebuffer.rect(x, y + 1, w, h - 2, Palette.color(:green), 1)
    |> Font.knock(x + pad, ty, "LANDED", kn)
    |> Font.knock(round((l_end + d_start - Font.knock_w(route)) / 2), ty, route, kn)
    |> Font.knock(d_start, ty, dur, kn)
  end

  # Progress bar: faint trough + bright fill, optional plane head + end caps.
  defp progress_bar(fb, x, y, w, pct, c, opts) do
    pct = pct |> max(0) |> min(1)
    faint = Palette.color(:faint)

    fb =
      Enum.reduce(0..(w - 1), fb, fn i, fb -> Framebuffer.add(fb, x + i, y, faint, 1) end)

    lit = round(pct * w)

    fb =
      if lit > 0 do
        Enum.reduce(0..(lit - 1), fb, fn i, fb -> Framebuffer.add(fb, x + i, y, c, 1) end)
      else
        fb
      end

    fb =
      if opts[:caps] do
        dim = Palette.color(:dim)

        fb
        |> Framebuffer.rect(x - 1, y - 1, 1, 3, dim)
        |> Framebuffer.rect(x + w, y - 1, 1, 3, dim)
      else
        fb
      end

    if opts[:plane], do: marker(fb, x + lit, y, c), else: fb
  end
end
