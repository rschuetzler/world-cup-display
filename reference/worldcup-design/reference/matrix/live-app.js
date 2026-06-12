// live-app.js — the matrix preview wired to LIVE data. Same board set and
// layout as app.js, but each card polls the kiosk's real per-state fixture
// endpoint (/preview/<state>/data) instead of a frozen client fixture.
//
// The server serialises timestamps as ISO-8601 strings; the renderers do
// millisecond arithmetic, so every *_utc / now value is parsed to epoch ms
// on the way in. If the fetch fails (e.g. opened without a server behind it)
// the card keeps the embedded fixture, so this page still previews offline.
// ─────────────────────────────────────────────────────────────────────

(function () {
  'use strict';

  const SCALE = 8;
  const POLL_MS = 60000;            // re-fetch each board's snapshot
  const TICK_MS = 250;              // redraw (countdowns / clocks animate)
  const DATA_URL = (state) => '/preview/' + state + '/data';

  const panels = [];
  const stage = document.getElementById('stage');

  // ── ISO → ms normalisation ─────────────────────────────────────────────
  // Recursively walk the snapshot; any value under a key ending in "_utc"
  // (or the top-level "now") that arrives as a string is parsed to epoch ms.
  // Nested objects/arrays (members[], flight, position, recent_landing) are
  // walked too. "_local" naive datetimes are left untouched (unused here).
  function toMs(v) {
    if (typeof v !== 'string') return v;
    const t = Date.parse(v);
    return isNaN(t) ? v : t;
  }
  function normalize(o) {
    if (Array.isArray(o)) return o.map(normalize);
    if (o && typeof o === 'object') {
      const r = {};
      for (const k in o) {
        const v = o[k];
        if ((k === 'now' || k.endsWith('_utc')) && typeof v === 'string') r[k] = toMs(v);
        else if (v && typeof v === 'object') r[k] = normalize(v);
        else r[k] = v;
      }
      return r;
    }
    return o;
  }

  async function fetchLive(entry) {
    if (!entry.dataUrl) return;
    try {
      const res = await fetch(entry.dataUrl, { cache: 'no-store' });
      if (!res.ok) return;                  // 404/500 → keep last good snap
      const json = await res.json();
      if (json && json.state) entry.snap = normalize(json);
      entry.live = true;
    } catch (e) {
      /* network blip or no server → keep the fixture fallback */
    }
  }

  // ── card scaffolding (mirrors app.js) ───────────────────────────────────
  function addCard(grid, name, desc, fn, snap, state) {
    const card = document.createElement('div');
    card.className = 'card';
    const screen = document.createElement('div');
    screen.className = 'screen';
    const canvas = document.createElement('canvas');
    canvas.className = 'matrix';
    screen.appendChild(canvas);
    const cap = document.createElement('div');
    cap.className = 'cap';
    cap.innerHTML = '<span class="cap-name">' + name + '</span>' +
      '<span class="cap-desc">' + desc + '</span>';
    card.appendChild(screen);
    card.appendChild(cap);
    grid.appendChild(card);
    const p = new window.LEDPanel(canvas, { scale: SCALE });
    const entry = { p, fn, snap, name, desc, state, canvas, screen };
    panels.push(entry);
    screen.addEventListener('click', () => openLightbox(entry));
    return entry;
  }

  function makeGrid(title, sub) {
    const secEl = document.createElement('section');
    secEl.className = 'sec';
    secEl.innerHTML =
      '<div class="sec-head"><h2>' + title + '</h2><span class="sec-sub">' + sub + '</span></div>';
    const grid = document.createElement('div');
    grid.className = 'grid';
    secEl.appendChild(grid);
    stage.appendChild(secEl);
    return grid;
  }

  // ── build the board set, one card per kiosk state ───────────────────────
  const GROUPS = [
    { id: 'core', title: 'Display states', sub: 'Every state the kiosk walks · live from /preview/<state>/data' },
    { id: 'alt', title: 'Alternating', sub: 'Multiple watched flights · cycles every 15s with a progress pill per member' },
    { id: 'pill', title: 'Recent-landing pill', sub: 'A just-landed leg overlaid on the panel that follows it' }
  ];
  GROUPS.forEach((grp) => {
    const boards = window.Boards.filter((b) => b.group === grp.id);
    if (!boards.length) return;
    const grid = makeGrid(grp.title, grp.sub);
    boards.forEach((b) => {
      const snap = window.Fixtures[b.fix](Date.now());   // offline fallback
      const entry = addCard(grid, b.name, b.desc, b.fn, snap, b.id);
      entry.dataUrl = DATA_URL(b.fix);
      fetchLive(entry);
    });
  });

  // ── render loop + polling ───────────────────────────────────────────────
  function renderAll() { for (const e of panels) { e.fn(e.p, e.snap); e.p.present(); } }
  renderAll();
  setInterval(renderAll, TICK_MS);
  setInterval(() => panels.forEach(fetchLive), POLL_MS);

  // ── lightbox (inspect a panel at scale) ─────────────────────────────────
  const lb = document.getElementById('lightbox');
  const lbScreen = document.getElementById('lb-screen');
  const lbName = document.getElementById('lb-name');
  const lbDesc = document.getElementById('lb-desc');
  let lbIndex = -1, lbHome = null;

  function openLightbox(entry) { lbIndex = panels.indexOf(entry); mount(lbIndex); lb.classList.add('open'); }
  function mount(i) {
    if (lbHome && lbHome.canvas.parentNode === lbScreen) lbHome.screen.appendChild(lbHome.canvas);
    const e = panels[i];
    lbHome = e;
    lbScreen.appendChild(e.canvas);
    lbName.textContent = e.name;
    lbDesc.textContent = e.desc;
  }
  function closeLightbox() {
    if (lbHome && lbHome.canvas.parentNode === lbScreen) lbHome.screen.appendChild(lbHome.canvas);
    lbHome = null; lbIndex = -1;
    lb.classList.remove('open');
  }
  function step(d) { if (lbIndex < 0) return; lbIndex = (lbIndex + d + panels.length) % panels.length; mount(lbIndex); }

  document.getElementById('lb-close').addEventListener('click', closeLightbox);
  document.getElementById('lb-prev').addEventListener('click', () => step(-1));
  document.getElementById('lb-next').addEventListener('click', () => step(1));
  lb.addEventListener('click', (e) => { if (e.target === lb) closeLightbox(); });
  document.addEventListener('keydown', (e) => {
    if (!lb.classList.contains('open')) return;
    if (e.key === 'Escape') closeLightbox();
    else if (e.key === 'ArrowLeft') step(-1);
    else if (e.key === 'ArrowRight') step(1);
  });
})();
