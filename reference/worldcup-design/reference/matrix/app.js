// app.js — builds the studio page from Renderers, drives the live render
// loop, and handles the inspect lightbox (the live canvas node is
// physically relocated into the overlay so it keeps animating).
// ─────────────────────────────────────────────────────────────────────

(function () {
  'use strict';

  const SCALE = 8;
  const panels = [];      // {p, fn, snap, name, desc, state, canvas, card}
  const stage = document.getElementById('stage');

  const G = window.Glyph, FB = window.FontBlit, RP = window.RP;

  function addCard(grid, name, desc, fn, snap, state, isStatic) {
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
    const entry = { p, fn, snap, name, desc, state, canvas, screen, isStatic: !!isStatic };
    panels.push(entry);
    screen.addEventListener('click', () => openLightbox(entry));
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

  // ── build the board set — one card per kiosk state, in lifecycle order.
  // Each board pulls a frozen snapshot from its fixture; renderers read the
  // live wall clock so countdowns / clocks / progress animate in place. ────
  const GROUPS = [
    { id: 'core', title: 'Display states', sub: 'Every state the kiosk walks · SLC→ATL→MCO trip, ticking live' },
    { id: 'alt', title: 'Alternating', sub: 'Multiple watched flights · cycles every 15s with a progress pill per member' },
    { id: 'pill', title: 'Recent-landing pill', sub: 'A just-landed leg overlaid on the panel that follows it' }
  ];
  GROUPS.forEach((grp) => {
    const boards = window.Boards.filter((b) => b.group === grp.id);
    if (!boards.length) return;
    const grid = makeGrid(grp.title, grp.sub);
    boards.forEach((b) => {
      const snap = window.Fixtures[b.fix](Date.now());   // frozen anchor
      addCard(grid, b.name, b.desc, b.fn, snap, b.id);
    });
  });

  // ── render loop ────────────────────────────────────────────────────────
  // setInterval (not rAF) so the panels keep ticking even when the tab/iframe
  // isn't focused — matters for a wall kiosk. Time-based content is happy at
  // a few fps; we also draw once immediately so first paint isn't blank.
  function renderAll() {
    for (const e of panels) { e.fn(e.p, e.snap); e.p.present(); }
  }
  function renderDynamic() {
    for (const e of panels) { if (e.isStatic) continue; e.fn(e.p, e.snap); e.p.present(); }
  }
  renderAll();
  setInterval(renderDynamic, 250);

  // ── lightbox ───────────────────────────────────────────────────────────
  const lb = document.getElementById('lightbox');
  const lbScreen = document.getElementById('lb-screen');
  const lbName = document.getElementById('lb-name');
  const lbDesc = document.getElementById('lb-desc');
  let lbIndex = -1, lbHome = null;

  function openLightbox(entry) {
    lbIndex = panels.indexOf(entry);
    mount(lbIndex);
    lb.classList.add('open');
  }
  function mount(i) {
    // return any currently-mounted canvas to its card first
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
  function step(d) {
    if (lbIndex < 0) return;
    lbIndex = (lbIndex + d + panels.length) % panels.length;
    mount(lbIndex);
  }

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
