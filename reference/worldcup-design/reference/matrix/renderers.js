// renderers.js — one board per kiosk display state for the 128×64 panel.
//
// Each renderer is fn(p, snap): it owns one full repaint of the framebuffer
// (clears, draws). The app loop calls present() afterwards. Snapshots are
// frozen at load with absolute target timestamps; renderers read the live
// wall clock (Date.now) so countdowns / progress / clocks animate.
//
// The board set mirrors the production state machine
// (lib/travis_tracker_web/controllers/matrix_preview_controller.ex):
//   idle · trip_pending · layover · pre_flight · taxiing · in_flight ·
//   post_flight (+ the recent-landing pill overlaid on pre_flight / layover).
// All boards share one visual language: flight id top-left, status top-right,
// ORIG→DEST code hero, a hairline divider, a detail row, and a bottom metric.
// ─────────────────────────────────────────────────────────────────────

(function (global) {
  'use strict';

  const G = global.Glyph, Fmt = global.Fmt;

  const P = {
    white: '#d4e3ff', soft: '#9fb2d8', dim: '#5e6e92', faint: '#2f3a59',
    cyan: '#54c6ff', ice: '#8ab0ff', green: '#5ce098', amber: '#ffb454',
    red: '#ff6f6f', sun: '#ffce5c', warm: '#ffd9a0'
  };
  const WX = { sun: '#ffce5c', cloud: '#9fb4d6', rain: '#5cc6ff', snow: '#dff0ff', moon: '#cdd7ee', bolt: '#ffd166' };

  // ── small geometry helpers ────────────────────────────────────────────
  function hline(p, x, y, w, c, a) { p.rect(x, y, w, 1, c, a); }
  function vline(p, x, y, h, c, a) { p.rect(x, y, 1, h, c, a); }
  function lerp(a, b, t) { return a + (b - a) * t; }
  function hm12(ms, tz) { return Fmt.fmtClock(ms, tz, true).replace(/^0/, ''); }

  // tweak accessor + small content helpers
  function tw(k, d) { const t = global.TW || {}; return t[k] == null ? d : t[k]; }
  function fitCity(s, max) {
    s = (s || '').toUpperCase().trim();
    return s.length <= max ? s : s.slice(0, max).trim();
  }
  function fmtClk(ms, tz) {
    const h12 = !tw('clock24', true);
    const s = Fmt.fmtClock(ms, tz, h12);
    return h12 ? s.replace(/^0/, '') : s;
  }
  // route marker between codes / on the route — picks glyph from tweak
  function marker(p, cx, cy, color, a) {
    const m = tw('marker', 'arrow');
    if (m === 'plane') G.drawPlane(p, cx, cy, color, a);
    else if (m === 'chevron') G.drawChevron(p, cx, cy, color, a);
    else G.drawArrow(p, cx, cy, color, a);
  }
  // big numerals — 7-segment by default, or a rasterised web font via tweak.
  // `o` carries the 7-seg opts; only o.dh (height) + o.color matter for fonts.
  function bigCenter(p, cx, y, str, o) {
    const nf = global.__numfont_override || tw('numfont', 'geistsqnative');
    if (nf === '7seg' || !global.FontBlit) return G.drawSegCenter(p, cx, y, str, o);
    const h = global.__numfont_h_override || o.dh;
    return global.FontBlit.fitCenter(p, cx, y, str, { font: nf, h: h, color: o.color, a: o.a });
  }
  function bigLeft(p, x, y, str, o) {
    const nf = global.__numfont_override || tw('numfont', 'geistsqnative');
    if (nf === '7seg' || !global.FontBlit) return G.drawSeg(p, x, y, str, o);
    return global.FontBlit.fit(p, x, y, str, { font: nf, h: o.dh, color: o.color, a: o.a });
  }

  // Hero ORIG→DEST codes in the 2× bitmap face with a route marker between,
  // centred horizontally. Returns nothing — shared by every flight board.
  function heroCodes(p, y, orig, dest, oColor, mColor, dColor) {
    const left = 20;
    G.drawText2x(p, left, y, orig, oColor);
    marker(p, left + 43, y + 7, mColor);
    G.drawText2x(p, left + 52, y, dest, dColor);
  }

  // Knockout text: hard-set pixels (replaces, not adds) so letters punch a
  // dark hole through a filled bar — the LED-authentic way to do a badge.
  function drawTextKnock(p, x, y, str, color) {
    str = String(str).toUpperCase();
    for (let i = 0; i < str.length; i++) {
      const g = G.F[str[i]] || G.F[' '];
      for (let row = 0; row < 7; row++) {
        const bits = g[row];
        for (let col = 0; col < 5; col++)
          if (bits & (1 << (4 - col))) p.set(x + col, y + row, color, 1);
      }
      x += 6;
    }
    return x;
  }
  function knockW(str) { return String(str).length * 6 - 1; }

  // Recent-landing pill — a filled green badge across the bottom band with
  // knockout text, overlaid on pre_flight / layover when a same-trip leg
  // just touched down. Occupies the bottom metric slot of the base board.
  function recentLandingPill(p, snap) {
    const r = snap.recent_landing;
    const since = Math.max(0, (Date.now() - r.landed_at_utc) / 1000);
    const route = r.origin_iata + '>' + r.destination_iata;
    const dur = Fmt.fmtDur(since);
    const y = 54, h = 9, x = 3, w = 122, pad = 6, ty = y + 1, KN = '#062311';
    // filled green bar with softened corners
    p.rect(x + 1, y, w - 2, h, P.green, 1);
    p.rect(x, y + 1, w, h - 2, P.green, 1);
    // "LANDED" left-anchored, duration right-anchored, route centred in the
    // gap between them — keeps the route balanced regardless of label width.
    const lEnd = x + pad + knockW('LANDED');
    const dStart = x + w - pad - knockW(dur);
    drawTextKnock(p, x + pad, ty, 'LANDED', KN);
    drawTextKnock(p, Math.round((lEnd + dStart - knockW(route)) / 2), ty, route, KN);
    drawTextKnock(p, dStart, ty, dur, KN);
  }

  // Progress bar: faint trough + bright fill, optional plane head + end caps.
  function progressBar(p, x, y, w, pct, c, opts) {
    opts = opts || {};
    pct = Math.max(0, Math.min(1, pct));
    for (let i = 0; i < w; i++) p.add(x + i, y, P.faint, 1);
    const lit = Math.round(pct * w);
    for (let i = 0; i < lit; i++) p.add(x + i, y, c, 1);
    if (opts.caps) {
      p.rect(x - 1, y - 1, 1, 3, P.dim); p.rect(x + w, y - 1, 1, 3, P.dim);
    }
    if (opts.plane) marker(p, x + lit, y, c);
  }

  // ════════════════════════════════════════════════════════════════════
  //  IDLE — resting face: big clock, date, weather strip.
  // ════════════════════════════════════════════════════════════════════
  function idleA(p, snap) {
    p.clear();
    const tz = snap.timezone, now = Date.now();
    // Clock at the font's native 19-cell cap height → blits 1:1, exact
    // stroke widths (the "1" is 2px, colon dots 3px). Any other height
    // would resample and smear those pixels.
    bigCenter(p, 64, 3, fmtClk(now, tz), { dw: 12, dh: 19, t: 3, gap: 3, color: P.white });

    const date = Fmt.fmtWeekday(now, tz) + ' ' + Fmt.fmtMonthDay(now, tz);
    G.drawTextCenter(p, 64, 26, date, P.cyan);

    hline(p, 18, 36, 92, P.faint);

    const kind = G.weatherKind(snap.weather_icon, snap.weather_condition);
    G.drawWeather(p, 8, 39, kind, WX);
    G.drawText(p, 30, 41, Math.round(snap.weather_temperature_f) + '°', P.white);
    G.drawTextRight(p, 122, 41, snap.weather_iata, P.cyan);
    G.drawTextCenter(p, 64, 56, (snap.weather_condition || '').toUpperCase(), P.soft);
  }

  // ════════════════════════════════════════════════════════════════════
  //  TRIP PENDING — a trip is booked but still hours out; big countdown.
  // ════════════════════════════════════════════════════════════════════
  function tripPendingA(p, snap) {
    p.clear();
    const f = snap.next_flight, now = Date.now();
    const cities = tw('labels', 'codes') === 'cities';

    G.drawText(p, 4, 2, 'NEXT TRIP', P.soft);
    G.drawTextRight(p, 124, 2, f.airline_iata + f.flight_number, P.dim);

    heroCodes(p, 12, f.origin_iata, f.destination_iata, P.white, P.cyan, P.white);

    if (cities) {
      G.drawText(p, 4, 29, fitCity(f.origin_city, 9), P.dim);
      G.drawTextRight(p, 124, 29, fitCity(f.destination_city, 9), P.cyan);
    } else {
      G.drawTextCenter(p, 64, 29,
        Fmt.fmtWeekday(f.scheduled_depart_utc, f.origin_tz) + ' ' +
        Fmt.fmtMonthDay(f.scheduled_depart_utc, f.origin_tz), P.dim);
    }

    hline(p, 8, 38, 112, P.faint);
    G.drawText(p, 4, 41, 'DEP ' + hm12(f.scheduled_depart_utc, f.origin_tz), P.white);
    G.drawTextRight(p, 124, 41, 'ARR ' + hm12(f.scheduled_arrive_utc, f.destination_tz), P.soft);

    const secs = (f.scheduled_depart_utc - now) / 1000;
    G.drawTextCenter(p, 64, 51, 'IN ' + Fmt.fmtDur(secs), P.cyan);
  }

  // ════════════════════════════════════════════════════════════════════
  //  LAYOVER — idle-style resting face for the connecting city: big local
  //  clock, date and weather, with the city called out up top.
  // ════════════════════════════════════════════════════════════════════
  function layoverA(p, snap) {
    p.clear();
    const tz = snap.timezone, now = Date.now();
    const next = snap.next_flight;

    G.drawText(p, 4, 1, 'LAYOVER', P.dim);
    G.drawTextRight(p, 124, 1, fitCity(snap.city, 12), P.cyan);

    bigCenter(p, 64, 8, fmtClk(now, tz), { dw: 11, dh: 19, t: 3, gap: 3, color: P.white });
    G.drawTextCenter(p, 64, 28, Fmt.fmtWeekday(now, tz) + ' ' + Fmt.fmtMonthDay(now, tz), P.soft);

    // a just-landed leg takes the bottom while it's fresh; otherwise the
    // connecting-city weather and the next leg.
    if (snap.recent_landing) { recentLandingPill(p, snap); return; }

    const kind = G.weatherKind(snap.weather_icon, snap.weather_condition);
    G.drawWeather(p, 6, 36, kind, WX);
    G.drawText(p, 28, 38, Math.round(snap.weather_temperature_f) + '°', P.white);
    G.drawTextRight(p, 122, 38, (snap.weather_condition || '').toUpperCase(), P.soft);

    if (next) {
      hline(p, 8, 50, 112, P.faint);
      const route = next.origin_iata + '>' + next.destination_iata;
      const t = hm12(next.scheduled_depart_utc, next.origin_tz);
      const lEnd = 4 + G.textW('NEXT');
      const rStart = 124 - G.textW(t);
      G.drawText(p, 4, 54, 'NEXT', P.soft);
      G.drawText(p, Math.round((lEnd + rStart - G.textW(route)) / 2), 54, route, P.white);
      G.drawTextRight(p, 124, 54, t, P.cyan);
    }
  }

  // ════════════════════════════════════════════════════════════════════
  //  PRE-FLIGHT — at the gate: codes hero, gate / ETD, live countdown.
  // ════════════════════════════════════════════════════════════════════
  function delayInfo(f) {
    if (tw('status', 'delayed') === 'ontime') return { late: false, mins: 0, reason: '' };
    const d = f.delay_minutes || 0;
    return { late: d > 0, mins: d, reason: (f.delay_reason || '').toUpperCase() };
  }

  function preA(p, snap) {
    p.clear();
    const f = snap.flight, now = Date.now();
    const di = delayInfo(f);
    const cities = tw('labels', 'codes') === 'cities';

    G.drawText(p, 4, 2, f.airline_iata + f.flight_number, P.soft);
    if (di.late) G.drawTextRight(p, 124, 2, 'DELAYED +' + di.mins + 'M', P.amber);
    else G.drawTextRight(p, 124, 2, 'ON TIME', P.green);

    heroCodes(p, 12, f.origin_iata, f.destination_iata, P.white, P.cyan, P.white);

    // secondary line: city names under each code, or delay reason
    if (cities) {
      G.drawText(p, 4, 29, fitCity(f.origin_city, 9), P.dim);
      G.drawTextRight(p, 124, 29, fitCity(f.destination_city, 9), P.cyan);
    } else if (di.late) {
      G.drawTextCenter(p, 64, 29, di.reason, P.dim);
    } else {
      G.drawTextCenter(p, 64, 29, 'ON SCHEDULE', P.dim);
    }

    hline(p, 8, 38, 112, P.faint);
    G.drawText(p, 4, 41, 'GATE ' + (f.gate || '--'), P.white);
    G.drawTextRight(p, 124, 41, 'ETD ' + hm12(f.estimated_depart_utc || f.scheduled_depart_utc, f.origin_tz), P.soft);

    if (snap.recent_landing) { recentLandingPill(p, snap); return; }
    const secs = (f.scheduled_depart_utc - now) / 1000;
    G.drawTextCenter(p, 64, 51, 'DEP IN ' + Fmt.fmtDur(secs), di.late ? P.amber : P.cyan);
  }

  // ════════════════════════════════════════════════════════════════════
  //  TAXIING — out of the gate (departure) or rolling in (arrival).
  // ════════════════════════════════════════════════════════════════════
  function taxiingA(p, snap) {
    p.clear();
    const f = snap.flight, now = Date.now();
    const cities = tw('labels', 'codes') === 'cities';
    // Touchdown wins when present — we're on the ground at the destination,
    // counting time since landing rather than since gate pushback.
    const down = f.actual_touchdown_utc;
    const isArr = !!down;
    const anchor = isArr ? down : (f.actual_depart_utc || f.scheduled_depart_utc);
    const elapsed = Math.max(0, (now - anchor) / 1000);
    const accent = isArr ? P.green : P.cyan;

    G.drawText(p, 4, 2, f.airline_iata + f.flight_number, P.soft);
    G.drawTextRight(p, 124, 2, isArr ? 'LANDED' : 'TAXIING', accent);

    heroCodes(p, 12, f.origin_iata, f.destination_iata,
      isArr ? P.soft : P.white, accent, P.white);

    if (cities) {
      G.drawText(p, 4, 29, fitCity(f.origin_city, 9), P.dim);
      G.drawTextRight(p, 124, 29, fitCity(f.destination_city, 9), P.cyan);
    } else {
      G.drawTextCenter(p, 64, 29, isArr ? 'ON THE GROUND' : 'PUSHED BACK', P.dim);
    }

    hline(p, 8, 38, 112, P.faint);
    G.drawText(p, 4, 41, 'GATE ' + (f.gate || '--'), P.white);
    if (isArr) G.drawTextRight(p, 124, 41, 'ARR ' + hm12(f.scheduled_arrive_utc, f.destination_tz), P.soft);
    else G.drawTextRight(p, 124, 41, 'ETD ' + hm12(f.estimated_depart_utc || f.scheduled_depart_utc, f.origin_tz), P.soft);

    G.drawTextCenter(p, 64, 51, (isArr ? 'LANDED ' : 'OUT OF GATE ') + Fmt.fmtDur(elapsed),
      isArr ? P.green : P.amber);
  }

  // ════════════════════════════════════════════════════════════════════
  //  IN-FLIGHT — airborne: codes hero, over-location, progress + marker.
  // ════════════════════════════════════════════════════════════════════
  function flightProg(f) {
    const now = Date.now();
    const dep = f.actual_depart_utc || f.scheduled_depart_utc;
    const arr = f.estimated_arrive_utc || f.scheduled_arrive_utc;
    const pct = arr > dep ? Math.max(0, Math.min(1, (now - dep) / (arr - dep))) : 0;
    const left = Math.max(0, (arr - now) / 1000);
    const flown = Math.max(0, (now - dep) / 1000);
    return { pct, left, flown, dep, arr };
  }

  function inA(p, snap) {
    p.clear();
    const f = snap.flight, pos = snap.position || {};
    const pr = flightProg(f);

    G.drawText(p, 4, 2, f.airline_iata + f.flight_number, P.soft);
    G.drawTextRight(p, 124, 2, 'IN FLIGHT', P.cyan);

    heroCodes(p, 12, f.origin_iata, f.destination_iata, P.white, P.cyan, P.white);

    // location detail (e.g. "OVER CHEYENNE, WY")
    const over = (pos.over || '').replace(/^near /i, 'OVER ').toUpperCase();
    G.drawTextCenter(p, 64, 30, over, P.soft);

    progressBar(p, 8, 44, 112, pr.pct, P.cyan, { plane: true, caps: true });
    // ETA in the destination's local time (left), time remaining (right).
    const mer = tw('clock24', true) ? '' : Fmt.fmtMeridiem(pr.arr, f.destination_tz).slice(0, 1);
    G.drawText(p, 8, 52, 'ETA ' + fmtClk(pr.arr, f.destination_tz) + mer, P.white);
    G.drawTextRight(p, 120, 52, Fmt.fmtHM(pr.left) + ' LEFT', P.soft);
  }

  // ════════════════════════════════════════════════════════════════════
  //  POST-FLIGHT — just touched down; the welcome-home bookend (green).
  // ════════════════════════════════════════════════════════════════════
  function postFlightA(p, snap) {
    p.clear();
    const f = snap.flight, now = Date.now();
    const down = f.actual_touchdown_utc;
    const since = Math.max(0, (now - down) / 1000);
    const onTime = !f.scheduled_arrive_utc || (down - f.scheduled_arrive_utc) <= 90 * 1000;

    G.drawText(p, 4, 2, f.airline_iata + f.flight_number, P.soft);
    G.drawTextRight(p, 124, 2, 'LANDED', P.green);

    heroCodes(p, 12, f.origin_iata, f.destination_iata, P.dim, P.green, P.green);

    hline(p, 8, 38, 112, P.faint);
    G.drawText(p, 4, 41, 'DOWN ' + hm12(down, f.destination_tz), P.soft);
    G.drawTextRight(p, 124, 41, onTime ? 'ON TIME' : 'LATE', onTime ? P.green : P.amber);

    G.drawTextCenter(p, 64, 51, 'LANDED ' + Fmt.fmtDur(since) + ' AGO', P.green);
  }

  global.RP = P;   // exposed so the accent tweak can recolor live

  // ════════════════════════════════════════════════════════════════════
  //  ALTERNATING — carousel across several watched flights. Renders the
  //  active member's own board, then overlays the member name (in place of
  //  the flight id) and a progress-pill row that fills over the dwell.
  // ════════════════════════════════════════════════════════════════════
  const MEMBER_FN = {
    idle: idleA, trip_pending: tripPendingA, layover: layoverA,
    pre_flight: preA, taxiing: taxiingA, in_flight: inA, post_flight: postFlightA
  };

  function alternatingA(p, snap) {
    const members = snap.members || [];
    if (!members.length) { p.clear(); return; }
    const dwell = snap.dwell_ms || 15000;
    const elapsed = Math.max(0, Date.now() - snap.now);
    const idx = Math.floor(elapsed / dwell) % members.length;
    const prog = (elapsed % dwell) / dwell;
    const m = members[idx];

    // 1 · the active member's panel, unchanged.
    (MEMBER_FN[m.state] || idleA)(p, m);

    // 2 · member name replaces the top-left flight id (a person, not a
    //     flight number, is the identity that matters when juggling many).
    const name = ((m.flight && m.flight.label) || '').toUpperCase();
    if (name) {
      for (let yy = 0; yy < 9; yy++)
        for (let xx = 2; xx < 46; xx++) p.set(xx, yy, '#000', 0);
      G.drawText(p, 4, 2, name, P.warm);
    }

    // 3 · progress pills, bottom-centre: past = full, active = filling,
    //     future = empty track. Mirrors the kiosk's carousel indicator.
    const n = members.length, pw = 18, ph = 2, gap = 5;
    let px = Math.round(64 - (n * pw + (n - 1) * gap) / 2);
    for (let i = 0; i < n; i++) {
      p.rect(px, 61, pw, ph, P.faint, 1);
      const fill = i < idx ? pw : (i === idx ? Math.round(prog * pw) : 0);
      if (fill > 0) p.rect(px, 61, fill, ph, P.white, 1);
      px += pw + gap;
    }
  }

  // The ordered board set — one entry per kiosk state, in lifecycle order,
  // with the fixture key each board pulls its snapshot from.
  global.Boards = [
    { id: 'idle', name: 'Idle', desc: 'Clock + weather · the resting face', fix: 'idle', fn: idleA, group: 'core' },
    { id: 'trip_pending', name: 'Trip pending', desc: 'Booked but hours out · countdown to departure', fix: 'trip_pending', fn: tripPendingA, group: 'core' },
    { id: 'layover', name: 'Layover', desc: 'On the ground between legs · city clock + weather', fix: 'layover', fn: layoverA, group: 'core' },
    { id: 'pre_flight', name: 'Pre-flight', desc: 'At the gate · gate / ETD, live countdown', fix: 'pre_flight', fn: preA, group: 'core' },
    { id: 'taxiing', name: 'Taxiing', desc: 'Pushed back · time out of gate', fix: 'taxiing', fn: taxiingA, group: 'core' },
    { id: 'in_flight', name: 'In-flight', desc: 'Airborne · over-location, progress + plane', fix: 'in_flight', fn: inA, group: 'core' },
    { id: 'post_flight', name: 'Post-flight', desc: 'Just landed · welcome home', fix: 'post_flight', fn: postFlightA, group: 'core' },
    { id: 'alternating', name: 'Alternating', desc: 'Cycles between watched flights every 15s · progress pills', fix: 'alternating', fn: alternatingA, group: 'alt' },
    { id: 'pre_flight_pill', name: 'Pre-flight + landed pill', desc: 'Next leg, with a just-landed pill for the prior leg', fix: 'post_flight_pill_on_pre_flight', fn: preA, group: 'pill' },
    { id: 'layover_pill', name: 'Layover + landed pill', desc: 'Layover, with a just-landed pill for the arriving leg', fix: 'post_flight_pill_on_layover', fn: layoverA, group: 'pill' }
  ];
})(window);
