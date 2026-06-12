// wc-renderers.js — the two World Cup displays for the 128×64 panel.
//
// Each renderer is fn(p, snap): owns one full repaint (clear + draw); the app
// loop calls present() afterwards. Snapshots freeze their match anchors at
// load; renderers read the live wall clock (Date.now) so minutes, countdowns,
// kickoff clocks and the blinking LIVE dot all animate in place.
//
// Board set (consolidated to the two we ship):
//   now_next — live scores up top + the next kickoffs below
//   live     — one match: big flags, big score, minute, progress
// ─────────────────────────────────────────────────────────────────────

(function (global) {
  'use strict';

  const G = global.Glyph, WC = global.WC, Fmt = WC.Fmt;

  const P = {
    white: '#e4ecff', soft: '#9fb2d8', dim: '#5e6e92', faint: '#2f3a59',
    live: '#ff5454', gold: '#ffcf5c', pitch: '#46d07f', ice: '#8ab0ff',
    win: '#5ce098', ball: '#eaf2ff'
  };
  global.RP = P;

  // ── tweak access + helpers ─────────────────────────────────────────────
  function tw(k, d) { const t = global.TW || {}; return t[k] == null ? d : t[k]; }
  function tint() { return tw('flagTint', true); }
  // code color: flag accent when tint is on, else the supplied fallback.
  function codeCol(code, fallback) { return tint() ? WC.teamC1(code) : fallback; }
  function clk(ms, tz) { return Fmt.fmtClock(ms, tz, !tw('clock24', true)); }
  function ko(ms, tz) { return Fmt.fmtKO(ms, tz, !tw('clock24', true)); }
  function blink() { return Math.floor(Date.now() / 600) % 2 === 0; }

  // flag helpers — gated by the flagIcons tweak (default on).
  function showFlags() { return tw('flagIcons', true) && !!global.WCFlags; }
  function miniFlag(p, x, y, w, h, code) {
    if (showFlags() && global.WCFlags.has(code)) { global.WCFlags.draw(p, x, y, w, h, code); return true; }
    return false;
  }

  // big numerals via the native Geist bitmap (falls back to 7-seg).
  function bigCenter(p, cx, y, str, h, color) {
    if (global.FontBlit) return global.FontBlit.fitCenter(p, cx, y, str, { font: 'geistsqnative', h: h, color: color });
    return G.drawSegCenter(p, cx, y, str, { dw: Math.round(h * 0.62), dh: h, t: Math.max(2, Math.round(h / 6)), gap: 3, color: color });
  }

  function hline(p, x, y, w, c, a) { p.rect(x, y, w, 1, c, a); }
  function dot(p, cx, cy, r, c, a) { G.disc(p, cx, cy, r, c, a); }

  // ORIG s-s DEST hero — codes flank a big centred score (flags-off fallback).
  function heroScore(p, y, home, away, hs, as, homeCol, awayCol, scoreCol) {
    G.drawText2x(p, 6, y, home, homeCol);
    G.drawText2x(p, 122 - G.text2xW(away), y, away, awayCol);
    bigCenter(p, 64, y - 2, hs + '-' + as, 18, scoreCol);
  }

  // Match-progress bar (0..90), faint trough + pitch fill + a rolling ball.
  function matchBar(p, x, y, w, minute, color) {
    const pct = Math.max(0, Math.min(1, minute / 90));
    for (let i = 0; i < w; i++) p.add(x + i, y, P.faint, 1);
    const lit = Math.round(pct * w);
    for (let i = 0; i < lit; i++) p.add(x + i, y, color, 1);
    const mid = x + Math.round(w / 2);       // half (45') tick
    p.add(mid, y - 1, P.dim, 1);
    dot(p, x + lit, y, 1, P.ball);
  }

  // ════════════════════════════════════════════════════════════════════
  //  NOW & NEXT — live scores up top, the next kickoffs below.
  //  "score of the current game(s) and the next few kickoff times."
  // ════════════════════════════════════════════════════════════════════
  function nowNextA(p, snap) {
    p.clear();
    const F = showFlags();

    // header
    if (blink()) dot(p, 6, 4, 1, P.live);
    G.drawText(p, 11, 1, 'LIVE', P.live);
    G.drawTextRight(p, 124, 1, Fmt.fmtWeekday(Date.now(), snap.tz), P.dim);

    // live rows: flag · code · score · code · flag · minute
    let y = 10;
    snap.live.forEach((m) => {
      const min = WC.minutesPlayed(m.kickoff_utc);
      const status = m.ht ? 'HT' : String(min);   // no trailing "'" so digits right-align with the clocks below
      const lead = m.hs > m.as ? 'h' : (m.as > m.hs ? 'a' : '');
      let x = 3;
      if (F) { miniFlag(p, x, y, 10, 7, m.home); x += 13; }
      x = G.drawText(p, x, y, m.home, codeCol(m.home, lead === 'h' ? P.white : P.soft)); x += 3;
      x = G.drawText(p, x, y, m.hs + '-' + m.as, P.white); x += 3;
      x = G.drawText(p, x, y, m.away, codeCol(m.away, lead === 'a' ? P.white : P.soft)); x += 2;
      if (F) miniFlag(p, x, y, 10, 7, m.away);
      G.drawTextRight(p, 124, y, status, P.gold);
      y += 10;
    });

    // divider + NEXT label
    G.drawText(p, 4, 31, 'NEXT', P.dim);
    hline(p, 4 + G.textW('NEXT') + 4, 34, 124 - (4 + G.textW('NEXT') + 4), P.faint);

    // next kickoffs. Every row shares ONE column grid derived from the most
    // constrained (widest) kickoff time — the bottom row's weekday label — so
    // the codes, flags, "V" and times all line up vertically. Weekday + clock
    // use a tight gap (vs a full space) to stay narrow; the away cluster is
    // nudged 1px when needed so the 5px "V" centres on a whole pixel.
    const GAP = 2;
    const codeW = G.textW('AAA');                  // every code is 3 letters
    const HOME_X = F ? 16 : 3;                      // home code left edge
    const homeEnd = HOME_X + codeW;                 // visible right edge of home code

    // widest time across the rows sets the shared away column
    let maxTimeW = 0;
    snap.next.forEach((m) => {
      const t = ko(m.kickoff_utc, m.tz || snap.tz);
      const i = t.indexOf(' ');
      const w = i >= 0 ? G.textW(t.slice(0, i)) + GAP + G.textW(t.slice(i + 1)) : G.textW(t);
      if (w > maxTimeW) maxTimeW = w;
    });

    let awayRight = Math.min(80, 124 - maxTimeW - 4);
    const awayCodeRightFor = (ar) => ar - (F ? 12 : 0);
    // V centres on a whole pixel only when the code gap is odd → nudge away +1px
    if ((awayCodeRightFor(awayRight) - codeW - homeEnd) % 2 === 0) awayRight += 1;
    const awayFlagX = awayRight - (F ? 10 : 0);
    const awayCodeRight = awayCodeRightFor(awayRight);
    const awayStart = awayCodeRight - codeW;        // visible left edge of away code
    const vX = (homeEnd + awayStart - G.textW('V')) / 2;

    let ny = 39;
    snap.next.forEach((m) => {
      const time = ko(m.kickoff_utc, m.tz || snap.tz);
      const sp = time.indexOf(' ');
      const wd = sp >= 0 ? time.slice(0, sp) : '';
      const cl = sp >= 0 ? time.slice(sp + 1) : time;

      // home cluster
      let hx = 3;
      if (F) { miniFlag(p, hx, ny, 10, 7, m.home); hx += 13; }
      G.drawText(p, hx, ny, m.home, codeCol(m.home, P.soft));

      // away cluster — shared fixed columns
      if (F) miniFlag(p, awayFlagX, ny, 10, 7, m.away);
      G.drawTextRight(p, awayCodeRight, ny, m.away, codeCol(m.away, P.soft));

      // centred "V"
      G.drawText(p, vX, ny, 'V', P.dim);

      // time — weekday (dim) tight against the clock (soft)
      G.drawTextRight(p, 124, ny, cl, P.soft);
      if (wd) G.drawTextRight(p, 124 - G.textW(cl) - GAP, ny, wd, P.dim);
      ny += 9;
    });
  }

  // ════════════════════════════════════════════════════════════════════
  //  GOAL CELEBRATION — a ~15s takeover that plays on the Live board when a
  //  goal goes in. Fires automatically when the score increases (slider or the
  //  Tweaks "scores" buttons); WCGoal.replay() repeats the last one.
  //    A (0–1.6s)  strobe burst + flashing GOAL!
  //    B (1.6–11.5) giant GOOOOOOOOOOL marquee over chevrons + sparkles
  //    C (11.5–15)  freeze-frame score reveal, then hand back to the board
  // ════════════════════════════════════════════════════════════════════
  let goalState = null;          // { start, team, code, home, away, hs, as }
  let prevScore = null;          // last-seen score, for edge detection
  let lastTeam = 'home';

  function draw2xCenter(p, cx, y, str, color, a) {
    return G.drawText2x(p, Math.round(cx - G.text2xW(str) / 2), y, str, color, a);
  }

  // stadium camera-flash sparkles, scattered + twinkling
  function sparkles(p, t, col) {
    for (let i = 0; i < 26; i++) {
      const phase = (t / 1000) * (1.3 + (i % 5) * 0.27) + i * 1.7;
      if ((phase % 1) > 0.16) continue;
      const hx = (i * 53) % 123 + 2;
      const hy = (i * 29) % 60 + 2;
      const c = (i % 3 === 0) ? col : '#dfe8ff';
      p.add(hx, hy, c, 1);
      if (i % 4 === 0) { p.add(hx - 1, hy, c, 0.5); p.add(hx + 1, hy, c, 0.5); p.add(hx, hy - 1, c, 0.5); p.add(hx, hy + 1, c, 0.5); }
    }
  }

  // moving diagonal chevron wash in the team colour (dim background)
  function chevrons(p, sec, col) {
    const s = Math.floor(sec * 18);
    for (let y = 0; y < 64; y++) {
      for (let x = 0; x < 128; x++) {
        if (((x + y + s) % 14) < 2) p.add(x, y, col, 0.16);
      }
    }
  }

  // animated dashed rule (ticker frame)
  function dashRow(p, y, col, sec) {
    const off = Math.floor(sec * 22);
    for (let x = 0; x < 128; x++) if (((x + off) % 6) < 3) p.add(x, y, col, 0.55);
  }

  // a continuous ribbon of the scoring team's flag, scrolling
  function flagRibbon(p, sec, code, y) {
    if (!showFlags() || !global.WCFlags.has(code)) return;
    const fw = 12, fh = 8, cell = fw + 4;
    const base = -(Math.floor(sec * 26) % cell);
    for (let x = base; x < 128; x += cell) global.WCFlags.draw(p, x, y, fw, fh, code);
  }

  function fullWash(p, col, a) {
    for (let y = 0; y < 64; y++) for (let x = 0; x < 128; x++) p.add(x, y, col, a);
  }

  function goalCelebration(p, t, st, m) {
    p.clear();
    const sec = t / 1000;
    const col = WC.teamC1(st.code);
    const A_END = 1.6, B_END = 13;

    // ── Phase A — strobe burst ──
    if (sec < A_END) {
      const on = Math.floor(sec / 0.13) % 2 === 0;
      fullWash(p, col, on ? 0.42 : 0.10);
      sparkles(p, t, col);
      draw2xCenter(p, 64, 18, 'GOAL!', on ? '#ffffff' : col);
      draw2xCenter(p, 64, 34, st.code, on ? col : '#ffffff');
      return;
    }

    // ── Phase B — the GOOOOOOOOOOL marquee ──
    if (sec < B_END) {
      chevrons(p, sec, col);
      dashRow(p, 17, col, sec);
      dashRow(p, 37, col, sec);
      const msg = 'G' + 'O'.repeat(26) + 'L!   ' + WC.teamName(st.code) + ' SCORES!   ';
      const mW = G.text2xW(msg) + 14;
      const base = -(Math.floor((sec - A_END) * 52) % mW);
      for (let x = base; x < 128 + mW; x += mW) G.drawText2x(p, x, 22, msg, '#ffffff');
      flagRibbon(p, sec, st.code, 52);
      sparkles(p, t, col);
      return;
    }

    // ── Phase C — freeze-frame score reveal ──
    chevrons(p, sec, col);
    sparkles(p, t, col);
    const rt = sec - B_END;
    const flash = Math.floor(rt / 0.28) % 2 === 0;
    draw2xCenter(p, 64, 1, st.code + ' GOAL!', flash ? col : '#ffffff');
    const fw = 26, fh = 17, fy = 20;
    miniFlag(p, 6, fy, fw, fh, m.home);
    miniFlag(p, 122 - fw, fy, fw, fh, m.away);
    bigCenter(p, 64, 22, st.hs + '-' + st.as, 20, '#ffffff');
    G.drawTextCenter(p, 64, 50, 'WHAT A GOAL', P.gold);
  }

  // public trigger — read live fixture + current score, start the show
  function fireGoal(team) {
    lastTeam = team;
    const lm = WC.Fixtures.live(Date.now()).match;
    const hs = Math.max(0, Math.min(9, tw('homeScore', 2)));
    const as = Math.max(0, Math.min(9, tw('awayScore', 1)));
    goalState = { start: Date.now(), team, code: team === 'home' ? lm.home : lm.away,
      home: lm.home, away: lm.away, hs, as };
  }
  global.WCGoal = {
    fire: fireGoal,
    replay: function () { fireGoal(lastTeam); },
    active: function () { return !!goalState; }
  };

  // ════════════════════════════════════════════════════════════════════
  //  LIVE — one match: big flags, big score, minute, match progress.
  //  Score and minute are tweakable.
  // ════════════════════════════════════════════════════════════════════
  function liveA(p, snap) {
    p.clear();
    const m = snap.match;
    const minute = Math.max(0, Math.min(95, tw('matchMin', 78)));
    const hs = Math.max(0, Math.min(9, tw('homeScore', 2)));
    const as = Math.max(0, Math.min(9, tw('awayScore', 1)));
    const half = minute <= 45 ? '1ST HALF' : '2ND HALF';

    // auto-fire the celebration the moment the score ticks up
    if (prevScore && (hs > prevScore.hs || as > prevScore.as)) {
      fireGoal(hs > prevScore.hs ? 'home' : 'away');
    }
    prevScore = { hs: hs, as: as };
    if (goalState) {
      const gt = Date.now() - goalState.start;
      if (gt < 16500) { goalCelebration(p, gt, goalState, m); return; }
      goalState = null;
    }

    // status row
    G.drawText(p, 4, 2, m.stage, P.soft);
    let rx = 124;
    G.drawTextRight(p, rx, 2, minute + "'", P.gold);
    rx -= G.textW(minute + "'") + 5;
    G.drawTextRight(p, rx, 2, 'LIVE', P.live);
    if (blink()) dot(p, rx - G.textW('LIVE') - 4, 5, 1, P.live);

    if (showFlags()) {
      // big-flag hero: a 26×17 flag over each code, big score centred between
      const fw = 26, fh = 17, fy = 11;
      miniFlag(p, 6, fy, fw, fh, m.home);
      miniFlag(p, 122 - fw, fy, fw, fh, m.away);
      G.drawTextCenter(p, 6 + fw / 2, fy + fh + 2, m.home, codeCol(m.home, P.white));
      G.drawTextCenter(p, 122 - fw / 2, fy + fh + 2, m.away, codeCol(m.away, P.ice));
      bigCenter(p, 64, 13, hs + '-' + as, 20, P.white);
    } else {
      heroScore(p, 14, m.home, m.away, hs, as,
        codeCol(m.home, P.white), codeCol(m.away, P.ice), P.white);
    }

    hline(p, 8, 40, 112, P.faint);
    matchBar(p, 8, 46, 112, minute, P.pitch);

    // running game clock (mm:ss) left, half right — ticks every second.
    const ss = Fmt.pad2(Math.floor(Date.now() / 1000) % 60);
    G.drawText(p, 8, 54, minute + ':' + ss, P.white);
    G.drawTextRight(p, 120, 54, half, P.soft);
  }

  // ── ordered board set ────────────────────────────────────────────────
  global.WCBoards = [
    { id: 'now_next', name: 'Now & Next', desc: 'Live scores + the next kickoffs · the at-a-glance board', fix: 'nowNext', fn: nowNextA, group: 'displays' },
    { id: 'live', name: 'Live match', desc: 'Big flags · score · minute · match progress (score & minute are tweakable)', fix: 'live', fn: liveA, group: 'displays' }
  ];
})(window);
