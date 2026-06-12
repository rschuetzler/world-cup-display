// fonts.js — bitmap type + pixel icons for the LED panel.
//
//  • F        : 5×7 uppercase bitmap font (bit 4 = leftmost pixel)
//  • drawText : 5×7 text, plus drawText2x for chunky hero codes
//  • seg7     : parametric 7-segment numerals for clocks / countdowns
//  • icons    : pixel-art weather glyphs + a small plane
// All helpers take an LEDPanel as the first argument and write via
// panel.add()/panel.rect(). Text auto-uppercases (the 5×7 set is caps).
// ─────────────────────────────────────────────────────────────────────

(function (global) {
  'use strict';

  const F = {
    ' ': [0, 0, 0, 0, 0, 0, 0],
    '0': [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
    '1': [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
    '2': [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F],
    '3': [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E],
    '4': [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
    '5': [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
    '6': [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E],
    '7': [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
    '8': [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
    '9': [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
    'A': [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
    'B': [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
    'C': [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E],
    'D': [0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C],
    'E': [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
    'F': [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
    'G': [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F],
    'H': [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
    'I': [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
    'J': [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C],
    'K': [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11],
    'L': [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
    'M': [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11],
    'N': [0x11, 0x19, 0x19, 0x15, 0x13, 0x13, 0x11],
    'O': [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
    'P': [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
    'Q': [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D],
    'R': [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
    'S': [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E],
    'T': [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
    'U': [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
    'V': [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04],
    'W': [0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A],
    'X': [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11],
    'Y': [0x11, 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04],
    'Z': [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F],
    '-': [0, 0, 0, 0x0E, 0, 0, 0],
    ':': [0, 0, 0x04, 0, 0, 0x04, 0],
    '/': [0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x10],
    '>': [0x10, 0x08, 0x04, 0x02, 0x04, 0x08, 0x10],
    '<': [0x01, 0x02, 0x04, 0x08, 0x04, 0x02, 0x01],
    '.': [0, 0, 0, 0, 0, 0, 0x04],
    ',': [0, 0, 0, 0, 0, 0x04, 0x08],
    '+': [0, 0, 0x04, 0x0E, 0x04, 0, 0],
    '%': [0x19, 0x19, 0x02, 0x04, 0x08, 0x13, 0x13],
    '°': [0x06, 0x09, 0x09, 0x06, 0, 0, 0],
    '·': [0, 0, 0, 0x04, 0, 0, 0],
    '"': [0x0A, 0x0A, 0, 0, 0, 0, 0]
  };

  // ── 5×7 text ────────────────────────────────────────────────────────
  function drawChar(p, x, y, ch, color, a) {
    const g = F[ch] || F[' '];
    for (let row = 0; row < 7; row++) {
      const bits = g[row];
      if (!bits) continue;
      for (let col = 0; col < 5; col++)
        if (bits & (1 << (4 - col))) p.add(x + col, y + row, color, a);
    }
    return x + 6;
  }

  function drawText(p, x, y, str, color, a) {
    str = String(str).toUpperCase();
    for (let i = 0; i < str.length; i++) x = drawChar(p, x, y, str[i], color, a);
    return x;
  }

  function textW(str) { return String(str).length * 6 - 1; }

  function drawTextRight(p, xRight, y, str, color, a) {
    return drawText(p, xRight - textW(str), y, str, color, a);
  }
  function drawTextCenter(p, cx, y, str, color, a) {
    return drawText(p, Math.round(cx - textW(str) / 2), y, str, color, a);
  }

  // 2× scaled 5×7 — each pixel becomes a 2×2 block. 10 wide, 14 tall.
  function drawChar2x(p, x, y, ch, color, a) {
    const g = F[ch] || F[' '];
    for (let row = 0; row < 7; row++) {
      const bits = g[row];
      if (!bits) continue;
      for (let col = 0; col < 5; col++)
        if (bits & (1 << (4 - col))) p.rect(x + col * 2, y + row * 2, 2, 2, color, a);
    }
    return x + 12;
  }
  function drawText2x(p, x, y, str, color, a) {
    str = String(str).toUpperCase();
    for (let i = 0; i < str.length; i++) x = drawChar2x(p, x, y, str[i], color, a);
    return x;
  }
  function text2xW(str) { return String(str).length * 12 - 2; }

  // ── 7-segment numerals ───────────────────────────────────────────────
  // segments: a top, b top-right, c bottom-right, d bottom, e bottom-left,
  // f top-left, g middle.
  const SEG = {
    '0': 'abcdef', '1': 'bc', '2': 'abged', '3': 'abgcd', '4': 'fgbc',
    '5': 'afgcd', '6': 'afgecd', '7': 'abc', '8': 'abcdefg', '9': 'abcdfg',
    '-': 'g', ' ': ''
  };

  function seg7Digit(p, ox, oy, dw, dh, t, ch, color, a) {
    const on = SEG[ch];
    if (on == null) return;
    const midY = oy + Math.round((dh - t) / 2);
    const topH = midY - (oy + t);
    const botH = (oy + dh - t) - (midY + t);
    const has = (s) => on.indexOf(s) !== -1;
    if (has('a')) p.rect(ox + t, oy, dw - 2 * t, t, color, a);
    if (has('g')) p.rect(ox + t, midY, dw - 2 * t, t, color, a);
    if (has('d')) p.rect(ox + t, oy + dh - t, dw - 2 * t, t, color, a);
    if (has('f')) p.rect(ox, oy + t, t, topH, color, a);
    if (has('b')) p.rect(ox + dw - t, oy + t, t, topH, color, a);
    if (has('e')) p.rect(ox, midY + t, t, botH, color, a);
    if (has('c')) p.rect(ox + dw - t, midY + t, t, botH, color, a);
  }

  // Draw a string of 7-seg numerals. opts: {dw,dh,t,gap,color,a}
  // Supports digits, '-', ' ', ':' (narrow dotted colon), '°' (small ring).
  function drawSeg(p, x, y, str, opts) {
    const dw = opts.dw, dh = opts.dh, t = opts.t, gap = opts.gap == null ? 2 : opts.gap;
    const color = opts.color, a = opts.a;
    str = String(str);
    for (let i = 0; i < str.length; i++) {
      const ch = str[i];
      if (ch === ':') {
        const cw = t;
        const y1 = y + Math.round(dh * 0.28), y2 = y + Math.round(dh * 0.62);
        p.rect(x, y1, cw, t, color, a);
        p.rect(x, y2, cw, t, color, a);
        x += cw + gap;
      } else if (ch === '°') {
        const r = Math.max(2, t);
        p.rect(x, y, r + 1, 1, color, a);
        p.rect(x, y + r, r + 1, 1, color, a);
        p.rect(x, y + 1, 1, r - 1, color, a);
        p.rect(x + r, y + 1, 1, r - 1, color, a);
        x += r + 1 + gap;
      } else if (ch === '1') {
        // kerned narrow "1": a single full-height bar, so it doesn't sit in a
        // wide half-empty cell next to full-width digits like 5/6.
        p.rect(x, y, t, dh, color, a);
        x += t + gap;
      } else {
        seg7Digit(p, x, y, dw, dh, t, ch, color, a);
        x += dw + gap;
      }
    }
    return x;
  }

  function segW(str, opts) {
    const dw = opts.dw, t = opts.t, gap = opts.gap == null ? 2 : opts.gap;
    let w = 0;
    str = String(str);
    for (let i = 0; i < str.length; i++) {
      const ch = str[i];
      if (ch === ':') w += t + gap;
      else if (ch === '°') w += t + 1 + gap;
      else if (ch === '1') w += t + gap;
      else w += dw + gap;
    }
    return Math.max(0, w - gap);
  }
  function drawSegCenter(p, cx, y, str, opts) {
    return drawSeg(p, Math.round(cx - segW(str, opts) / 2), y, str, opts);
  }
  function drawSegRight(p, xr, y, str, opts) {
    return drawSeg(p, Math.round(xr - segW(str, opts)), y, str, opts);
  }

  // ── pixel-art icons ───────────────────────────────────────────────────
  // Filled disc of radius r centred at (cx,cy).
  function disc(p, cx, cy, r, color, a) {
    const r2 = r * r + r * 0.4;
    for (let dy = -r; dy <= r; dy++)
      for (let dx = -r; dx <= r; dx++)
        if (dx * dx + dy * dy <= r2) p.add(cx + dx, cy + dy, color, a);
  }
  function ring(p, cx, cy, r, color, a) {
    const outer = r * r + r * 0.4, inner = (r - 1) * (r - 1);
    for (let dy = -r; dy <= r; dy++)
      for (let dx = -r; dx <= r; dx++) {
        const d = dx * dx + dy * dy;
        if (d <= outer && d > inner) p.add(cx + dx, cy + dy, color, a);
      }
  }

  // A small puffy cloud anchored with its top-left at (x,y) ~ 16×9.
  function cloud(p, x, y, color, a) {
    disc(p, x + 5, y + 5, 3, color, a);
    disc(p, x + 10, y + 4, 4, color, a);
    disc(p, x + 13, y + 6, 3, color, a);
    p.rect(x + 3, y + 6, 12, 3, color, a);
  }

  // Weather glyph in a ~16-wide box, top-left (x,y). `kind` is normalised.
  // pal = {sun, cloud, rain, snow, bolt}
  function drawWeather(p, x, y, kind, pal) {
    pal = pal || {};
    const sun = pal.sun || '#ffce5c', cl = pal.cloud || '#aebfd6',
      rain = pal.rain || '#6db4ff', snow = pal.snow || '#dff0ff',
      bolt = pal.bolt || '#ffd166', moon = pal.moon || '#cdd7ee';
    switch (kind) {
      case 'clear':
        disc(p, x + 8, y + 6, 3, sun);
        // rays
        const rays = [[8, 0], [8, 12], [2, 6], [14, 6], [4, 2], [12, 2], [4, 10], [12, 10]];
        rays.forEach(([rx, ry]) => p.add(x + rx, y + ry, sun));
        break;
      case 'night':
        disc(p, x + 8, y + 6, 4, moon);
        disc(p, x + 10, y + 4, 4, '#06070a'); // bite out crescent
        break;
      case 'partly':
        disc(p, x + 5, y + 4, 2, sun);
        [[5, 0], [1, 4], [9, 4], [2, 1], [8, 1]].forEach(([rx, ry]) => p.add(x + rx, y + ry, sun));
        cloud(p, x + 2, y + 4, cl);
        break;
      case 'cloud':
        cloud(p, x, y + 2, cl);
        break;
      case 'rain':
        cloud(p, x, y, cl);
        [[5, 0], [9, 0], [13, 0]].forEach(([rx, ry]) => {
          p.add(x + rx, y + 10 + ry, rain);
          p.add(x + rx - 1, y + 12 + ry, rain);
        });
        break;
      case 'snow':
        cloud(p, x, y, cl);
        [[5, 11], [9, 12], [13, 11]].forEach(([rx, ry]) => p.add(x + rx, y + ry, snow));
        break;
      case 'storm':
        cloud(p, x, y, cl);
        p.add(x + 8, y + 10, bolt); p.add(x + 7, y + 11, bolt);
        p.add(x + 9, y + 11, bolt); p.add(x + 7, y + 12, bolt);
        p.add(x + 8, y + 13, bolt);
        break;
      default:
        cloud(p, x, y + 2, cl);
    }
  }

  // Normalise OpenWeather icon code / condition string → a glyph kind.
  function weatherKind(icon, condition) {
    if (icon) {
      const c = icon.slice(0, 2), night = icon.slice(2) === 'n';
      if (c === '01') return night ? 'night' : 'clear';
      if (c === '02' || c === '03') return 'partly';
      if (c === '04') return 'cloud';
      if (c === '09' || c === '10') return 'rain';
      if (c === '11') return 'storm';
      if (c === '13') return 'snow';
      if (c === '50') return 'cloud';
    }
    const s = (condition || '').toLowerCase();
    if (s.includes('storm') || s.includes('thunder')) return 'storm';
    if (s.includes('snow')) return 'snow';
    if (s.includes('rain') || s.includes('drizzle')) return 'rain';
    if (s.includes('partly')) return 'partly';
    if (s.includes('cloud')) return 'cloud';
    if (s.includes('clear')) return 'clear';
    return 'partly';
  }

  // Route markers, all centred at (cx,cy), pointing right (toward dest).
  // Kept diagonal-free where possible so they read as intentional at 1px.

  // Clean right arrow — the default separator. ~9×7.
  function drawArrow(p, cx, cy, color, a) {
    cx = Math.round(cx); cy = Math.round(cy);
    p.rect(cx - 4, cy, 9, 1, color, a);   // shaft + tip, cx-4 .. cx+4
    // arrowhead (two 3-step diagonals meeting at the tip)
    p.add(cx + 1, cy - 3, color, a); p.add(cx + 2, cy - 2, color, a); p.add(cx + 3, cy - 1, color, a);
    p.add(cx + 1, cy + 3, color, a); p.add(cx + 2, cy + 2, color, a); p.add(cx + 3, cy + 1, color, a);
  }

  // Single chevron ">". ~7×7.
  function drawChevron(p, cx, cy, color, a) {
    cx = Math.round(cx); cy = Math.round(cy);
    for (let i = 0; i < 4; i++) {
      p.add(cx - 2 + i, cy - 3 + i, color, a);
      p.add(cx - 2 + i, cy + 3 - i, color, a);
    }
  }

  // Map-style top-down jet: fat fuselage, straight wings, small tailplane,
  // pointed nose. Solid shapes (no thin diagonals) so it reads as a plane.
  // ~11×9, nose at right.
  function drawPlane(p, cx, cy, color, a) {
    cx = Math.round(cx); cy = Math.round(cy);
    p.rect(cx - 4, cy - 1, 9, 3, color, a);  // fuselage cx-4..cx+4
    p.add(cx + 5, cy, color, a);             // pointed nose
    p.rect(cx - 1, cy - 4, 2, 9, color, a);  // wings (straight, mid-body)
    p.rect(cx - 4, cy - 2, 1, 5, color, a);  // tailplane (aft)
  }

  global.Glyph = {
    F, drawChar, drawText, textW, drawTextRight, drawTextCenter,
    drawText2x, text2xW,
    drawSeg, segW, drawSegCenter, drawSegRight,
    disc, ring, cloud, drawWeather, weatherKind, drawPlane, drawArrow, drawChevron
  };
})(window);
