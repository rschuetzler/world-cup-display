// wc-app.js — builds the studio gallery from WCBoards, drives the live render
// loop, and handles the inspect lightbox (the live canvas is relocated into
// the overlay so it keeps animating). Mirrors the flight build's app.js.
// ─────────────────────────────────────────────────────────────────────

(function () {
  'use strict';

  const SCALE = 8;
  const panels = [];
  const stage = document.getElementById('stage');

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

  const GROUPS = [
    { id: 'displays', title: 'Displays', sub: 'The two boards · live scores at a glance, and one match in full' }
  ];
  GROUPS.forEach((grp) => {
    const boards = window.WCBoards.filter((b) => b.group === grp.id);
    if (!boards.length) return;
    const grid = makeGrid(grp.title, grp.sub);
    boards.forEach((b) => {
      const snap = window.WC.Fixtures[b.fix](Date.now());
      addCard(grid, b.name, b.desc, b.fn, snap, b.id);
    });
  });

  // ── render loop — rAF, throttled. Runs ~30fps while a goal celebration is
  //    playing (smooth scroll), ~12fps otherwise (clocks/blink are slow). ────
  function renderAll() {
    for (const e of panels) { e.fn(e.p, e.snap); e.p.present(); }
  }
  renderAll();
  let last = 0;
  function loop(ts) {
    const goal = window.WCGoal && window.WCGoal.active();
    const interval = goal ? 33 : 83;
    if (ts - last >= interval) { last = ts; renderAll(); }
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(loop);

  // ── lightbox ───────────────────────────────────────────────────────────
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
