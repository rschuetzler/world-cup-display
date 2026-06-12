// wc-data.js — World Cup repurpose of the 128×64 panel.
//
// Teams (3-letter codes + flag-tint colors), match fixtures computed against
// the live wall clock (so minutes / countdowns / kickoff times animate), and a
// few shared formatters. Field names are kept generic so the renderers read
// like a tiny scoreboard protocol rather than the flight one.
// ─────────────────────────────────────────────────────────────────────

(function (global) {
  'use strict';

  const MIN = 60 * 1000, HR = 60 * MIN;

  // ── team table ─────────────────────────────────────────────────────────
  // c1 = the LED-friendly flag accent used when "flag tint" is on. Tuned for a
  // fine-pitch panel: bright, single-chroma, never muddy. (Generic country
  // marks only — no federation emblems.)
  const TEAMS = {
    USA: { name: 'USA',         c1: '#5b8cff' },
    MEX: { name: 'MEXICO',      c1: '#34c878' },
    CAN: { name: 'CANADA',      c1: '#ff5c5c' },
    BRA: { name: 'BRAZIL',      c1: '#ffd23f' },
    ARG: { name: 'ARGENTINA',   c1: '#6cc4f5' },
    FRA: { name: 'FRANCE',      c1: '#5b8cff' },
    ENG: { name: 'ENGLAND',     c1: '#d7e2fb' },
    ESP: { name: 'SPAIN',       c1: '#ff5c5c' },
    GER: { name: 'GERMANY',     c1: '#ffce5c' },
    POR: { name: 'PORTUGAL',    c1: '#ff6f6f' },
    NED: { name: 'NETHERLANDS', c1: '#ff9d3c' },
    BEL: { name: 'BELGIUM',     c1: '#ffce5c' },
    CRO: { name: 'CROATIA',     c1: '#ff5c5c' },
    ITA: { name: 'ITALY',       c1: '#4f8cff' },
    URU: { name: 'URUGUAY',     c1: '#6cc4f5' },
    COL: { name: 'COLOMBIA',    c1: '#ffd23f' },
    JPN: { name: 'JAPAN',       c1: '#5b8cff' },
    KOR: { name: 'KOREA',       c1: '#ff5c5c' },
    SEN: { name: 'SENEGAL',     c1: '#34c878' },
    MAR: { name: 'MOROCCO',     c1: '#ff5c5c' },
    AUS: { name: 'AUSTRALIA',   c1: '#ffd23f' },
    SUI: { name: 'SWITZERLAND', c1: '#ff5c5c' }
  };

  function teamName(code) { const t = TEAMS[code]; return (t && t.name) || code; }
  function teamC1(code) { const t = TEAMS[code]; return (t && t.c1) || '#e4ecff'; }

  // minutes played since kickoff (live), clamped sane.
  function minutesPlayed(kickoff_utc) {
    return Math.max(0, Math.floor((Date.now() - kickoff_utc) / 60000));
  }

  // ── fixtures ───────────────────────────────────────────────────────────
  // The marquee single-match boards revolve around USA v MEX so the live board
  // can be driven by the score / minute tweaks; the multi-match boards carry
  // their own slate so the gallery shows a believable matchday.

  // Live marquee — minute + score come from the tweaks at render time; kickoff
  // is anchored so the running clock has a believable base if tweaks are unset.
  function live(now) {
    return {
      now,
      match: { stage: 'GROUP D', home: 'USA', away: 'MEX',
        venue: 'LOS ANGELES', tz: 'America/Los_Angeles',
        kickoff_utc: now - 78 * MIN }
    };
  }

  // The at-a-glance board: current scores up top, the next kickoffs below.
  function nowNext(now) {
    return {
      now, tz: 'America/New_York',
      live: [
        { home: 'USA', away: 'MEX', hs: 2, as: 1, kickoff_utc: now - 78 * MIN },
        { home: 'ARG', away: 'CRO', hs: 1, as: 1, kickoff_utc: now - 45 * MIN, ht: true }
      ],
      next: [
        { home: 'BRA', away: 'ESP', kickoff_utc: now + 2 * HR + 14 * MIN, tz: 'America/New_York' },
        { home: 'ENG', away: 'FRA', kickoff_utc: now + 5 * HR, tz: 'America/New_York' },
        { home: 'NED', away: 'GER', kickoff_utc: now + 21 * HR, tz: 'America/New_York' }
      ]
    };
  }

  const FIX = { live, nowNext };

  // ── formatters ─────────────────────────────────────────────────────────
  function pad2(n) { return String(n).padStart(2, '0'); }

  function fmtClock(ms, tz, h12) {
    try {
      return new Intl.DateTimeFormat('en-US', {
        hour: '2-digit', minute: '2-digit', hour12: !!h12, timeZone: tz
      }).format(new Date(ms)).replace(/\s?[AP]M/i, '');
    } catch (e) { return '--:--'; }
  }
  function fmtMeridiem(ms, tz) {
    try {
      const s = new Intl.DateTimeFormat('en-US', { hour: '2-digit', hour12: true, timeZone: tz }).format(new Date(ms));
      const m = s.match(/([AP]M)/i); return m ? m[1].toUpperCase() : '';
    } catch (e) { return ''; }
  }
  function fmtWeekday(ms, tz) {
    try {
      return new Intl.DateTimeFormat('en-US', { weekday: 'short', timeZone: tz }).format(new Date(ms)).toUpperCase();
    } catch (e) { return ''; }
  }
  function fmtMonthDay(ms, tz) {
    try {
      const parts = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', timeZone: tz }).formatToParts(new Date(ms));
      const mo = parts.find(p => p.type === 'month').value.toUpperCase();
      const da = parts.find(p => p.type === 'day').value;
      return mo + ' ' + da;
    } catch (e) { return ''; }
  }
  function dayKey(ms, tz) {
    try { return new Intl.DateTimeFormat('en-CA', { timeZone: tz }).format(new Date(ms)); }
    catch (e) { return ''; }
  }
  // Kickoff label: bare HH:MM if it's today, else weekday + time.
  function fmtKO(ms, tz, h12) {
    const t = fmtClock(ms, tz, h12);
    if (dayKey(ms, tz) === dayKey(Date.now(), tz)) return t;
    return fmtWeekday(ms, tz) + ' ' + t;
  }
  // "2H 14M" / "47M" / "30S"
  function fmtDur(secs) {
    secs = Math.max(0, Math.floor(secs));
    const h = Math.floor(secs / 3600), m = Math.floor((secs % 3600) / 60);
    if (h > 0) return h + 'H ' + m + 'M';
    if (m > 0) return m + 'M';
    return secs + 'S';
  }

  global.WC = {
    TEAMS, teamName, teamC1, minutesPlayed,
    Fixtures: FIX,
    Fmt: { pad2, fmtClock, fmtMeridiem, fmtWeekday, fmtMonthDay, fmtKO, fmtDur }
  };
})(window);
