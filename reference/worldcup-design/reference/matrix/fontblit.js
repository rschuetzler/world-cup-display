// fontblit.js — rasterize real (web) pixel fonts into the LED framebuffer.
//
// Glyphs are rasterized INDIVIDUALLY at a consistent scale (so each digit /
// colon is independently addressable), trimmed, area-averaged to the target
// LED size, then composed into strings with even spacing. A per-glyph
// OVERRIDES map lets specific pixels be added/removed for a given
// font|size|char — that's how hand-tuned digit fixes are applied.
// Everything is cached so the live loop only rasterizes on first use.
// ─────────────────────────────────────────────────────────────────────

(function (global) {
  'use strict';

  // Numeral font is locked to the native Geist Pixel Square bitmap (added
  // dynamically from geist-native.js below). 7-segment stays as a hard fallback
  // for when FontBlit/the bitmap aren't available — it's not a selectable option.
  const FONTS = [];
  const byId = {};
  FONTS.forEach((f) => (byId[f.id] = f));

  // ── Native bitmap fonts ────────────────────────────────────────────────
  // A "native" font ships exact per-glyph pixel bitmaps on the typeface's own
  // cell grid (see geist-native.js). At its design cap-height it blits 1:1 —
  // no vector rasterization or area-averaging — so it reads dead-crisp on the
  // LED panel. Other heights are area-resampled from the true bitmap.
  const NATIVE = {};
  function registerNative(id, label, json) {
    if (!json || !json.glyphs) return;
    // Geist Pixel only encodes U+0020–U+007E, so it has no degree sign — the
    // clock/temperature numerals need one. Synthesize a small open ring at the
    // cap line if the source font lacks it.
    if (!json.glyphs['\u00b0']) {
      json.glyphs['\u00b0'] = {
        codepoint: 176, width: 5, height: 5, advance: 8, xoff: 1,
        yoff: json.meta.cap_height_cells || 19,
        bitmap: [[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]]
      };
    }
    NATIVE[id] = json;
    const f = { id: id, label: label, family: null, native: true };
    byId[id] = f;
    FONTS.push(f);
  }

  // Hand-tuned per-glyph pixel fixes. Key: `${fontId}|${height}|${char}`.
  // Coords are glyph-local (0,0 = top-left of the glyph's own bitmap).
  const OVERRIDES = {
    // Jersey 15 @ 20px (the Idle clock) — symmetric counters + cleaner edges.
    'jersey15|20|2': { remove: [[8, 4]] },                  // extra pixel, inner-right of top bowl
    'jersey15|20|6': { remove: [[4, 12], [4, 14], [5, 15]] }, // centre the lower counter
    'jersey15|20|8': { remove: [[4, 14], [5, 15]] },        // centre the lower counter
    'jersey15|20|9': { remove: [[5, 4], [4, 5]] }           // centre the upper counter
  };

  const oc = document.createElement('canvas');
  const octx = oc.getContext('2d', { willReadFrequently: true });
  const refCache = new Map();
  const glyphCache = new Map();
  const strCache = new Map();

  function familyOf(id) { const f = byId[id]; return f ? f.family : null; }
  function isNative(id) { return !!(byId[id] && byId[id].native); }

  // Native glyph → {w, h, top, data, lsb, adv}. The source bitmap is resampled
  // by `scale = h / capHeight` (scale 1 = exact 1:1 blit at the design size).
  // top = LED rows below the cap-top; lsb = left bearing; adv = advance width.
  function nativeGlyph(id, h, ch) {
    const k = id + '|' + h + '|' + ch;
    let g = glyphCache.get(k);
    if (g) return g;
    const json = NATIVE[id], cap = json.meta.cap_height_cells || 19;
    const scale = h / cap, inv = 1 / scale;
    const gl = json.glyphs[ch];
    if (!gl || !gl.bitmap || !gl.bitmap.length || !gl.width) {
      const advEmpty = gl ? Math.round((gl.advance || 0) * scale)
        : Math.round((json.glyphs['0'] ? json.glyphs['0'].advance : cap) * scale);
      g = { w: 0, h: 0, top: 0, data: null, lsb: 0, adv: advEmpty };
      glyphCache.set(k, g); return g;
    }
    const srcW = gl.width, srcH = gl.height;
    const gW = Math.max(1, Math.round(srcW * scale));
    const gH = Math.max(1, Math.round(srcH * scale));
    const data = new Uint8Array(gW * gH);
    for (let oy = 0; oy < gH; oy++) {
      const sy0 = oy * inv, sy1 = (oy + 1) * inv;
      for (let ox = 0; ox < gW; ox++) {
        const sx0 = ox * inv, sx1 = (ox + 1) * inv;
        let lit = 0, tot = 0;
        for (let sy = Math.floor(sy0); sy < Math.ceil(sy1); sy++) {
          const row = gl.bitmap[sy];
          for (let sx = Math.floor(sx0); sx < Math.ceil(sx1); sx++) {
            tot++; if (row && row[sx]) lit++;
          }
        }
        if (tot > 0 && lit / tot > 0.42) data[oy * gW + ox] = 1;
      }
    }
    g = {
      w: gW, h: gH, data: data,
      top: Math.round((cap - gl.yoff) * scale),
      lsb: Math.round((gl.xoff || 0) * scale),
      adv: Math.round(gl.advance * scale)
    };
    glyphCache.set(k, g);
    return g;
  }

  // Compose a native string using the font's real advance widths (so digits
  // stay evenly spaced), then trim to the inked bounding box.
  function nativeBits(id, h, str) {
    const key = id + '|' + h + '|' + str;
    let v = strCache.get(key);
    if (v) return v;
    str = String(str);
    const json = NATIVE[id], cap = json.meta.cap_height_cells || 19;
    const spaceAdv = Math.round(((json.glyphs[' '] && json.glyphs[' '].advance) || 10) * (h / cap));
    const placed = [];
    let pen = 0, outH = h;
    for (const ch of str) {
      if (ch === ' ') { pen += spaceAdv; continue; }
      const g = nativeGlyph(id, h, ch);
      if (g.data) { placed.push({ g, x: pen + g.lsb }); if (g.top + g.h > outH) outH = g.top + g.h; }
      pen += g.adv;
    }
    let minX = Infinity, maxX = 0;
    for (const { g, x } of placed) { minX = Math.min(minX, Math.round(x)); maxX = Math.max(maxX, Math.round(x) + g.w); }
    if (!isFinite(minX)) { v = { w: 1, h: outH, data: new Uint8Array(outH) }; strCache.set(key, v); return v; }
    const W = Math.max(1, maxX - minX);
    const data = new Uint8Array(W * outH);
    for (const { g, x } of placed) {
      const bx = Math.round(x) - minX;
      for (let oy = 0; oy < g.h; oy++) {
        const ty = g.top + oy; if (ty < 0 || ty >= outH) continue;
        for (let ox = 0; ox < g.w; ox++) {
          if (g.data[oy * g.w + ox]) { const tx = bx + ox; if (tx >= 0 && tx < W) data[ty * W + tx] = 1; }
        }
      }
    }
    v = { w: W, h: outH, data };
    strCache.set(key, v);
    return v;
  }

  // Render `ch` at `px` into the work canvas; return {img, w, h, pad}.
  function renderBig(id, ch, px) {
    const fam = familyOf(id), weight = byId[id].weight || 400;
    const font = `${weight} ${px}px "${fam}"`;
    octx.font = font;
    const pad = Math.ceil(px * 0.3);
    const w = Math.ceil(octx.measureText(ch).width) + pad * 2;
    const h = Math.ceil(px * 1.7) + pad * 2;
    oc.width = w; oc.height = h;
    octx.font = font;
    octx.textBaseline = 'alphabetic';
    octx.fillStyle = '#fff';
    octx.clearRect(0, 0, w, h);
    octx.fillText(ch, pad, Math.round(h * 0.72));
    return { img: octx.getImageData(0, 0, w, h).data, w, h };
  }

  // Reference metrics for (id,h): use "8" to establish the digit band so all
  // glyphs share a baseline + scale.
  function refScale(id, h) {
    const k = id + '|' + h;
    let r = refCache.get(k);
    if (r) return r;
    const bigPx = Math.max(48, h * 6);
    const { img, w, h: ht } = renderBig(id, '8', bigPx);
    let minY = ht, maxY = -1;
    for (let y = 0; y < ht; y++) {
      for (let x = 0; x < w; x++) {
        if (img[(y * w + x) * 4 + 3] > 96) { if (y < minY) minY = y; if (y > maxY) maxY = y; }
      }
    }
    const digitH = Math.max(1, maxY - minY + 1);
    r = { bigPx, digitTop: minY, scale: h / digitH };
    refCache.set(k, r);
    return r;
  }

  // Single glyph → {w, h, top, data}. top = LED rows below the digit cap-top.
  function glyphBits(id, h, ch) {
    if (isNative(id)) return nativeGlyph(id, h, ch);
    const k = id + '|' + h + '|' + ch;
    let g = glyphCache.get(k);
    if (g) return g;
    const fam = familyOf(id);
    if (!fam) { g = { w: 0, h: 0, top: 0, data: null }; glyphCache.set(k, g); return g; }

    const ref = refScale(id, h);
    const { img, w, h: ht } = renderBig(id, ch, ref.bigPx);
    let minX = w, minY = ht, maxX = -1, maxY = -1;
    for (let y = 0; y < ht; y++) {
      for (let x = 0; x < w; x++) {
        if (img[(y * w + x) * 4 + 3] > 96) {
          if (x < minX) minX = x; if (x > maxX) maxX = x;
          if (y < minY) minY = y; if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < 0) { g = { w: 0, h: 0, top: 0, data: null }; glyphCache.set(k, g); return g; }

    const scale = ref.scale, inv = 1 / scale;
    const gW = Math.max(1, Math.round((maxX - minX + 1) * scale));
    const gH = Math.max(1, Math.round((maxY - minY + 1) * scale));
    const top = Math.round((minY - ref.digitTop) * scale);
    const data = new Uint8Array(gW * gH);
    for (let oy = 0; oy < gH; oy++) {
      const sy0 = minY + oy * inv, sy1 = minY + (oy + 1) * inv;
      for (let ox = 0; ox < gW; ox++) {
        const sx0 = minX + ox * inv, sx1 = minX + (ox + 1) * inv;
        let lit = 0, tot = 0;
        for (let sy = Math.floor(sy0); sy < Math.ceil(sy1); sy++) {
          for (let sx = Math.floor(sx0); sx < Math.ceil(sx1); sx++) {
            tot++;
            if (sx >= 0 && sy >= 0 && sx < w && sy < ht && img[(sy * w + sx) * 4 + 3] > 96) lit++;
          }
        }
        if (tot > 0 && lit / tot > 0.42) data[oy * gW + ox] = 1;
      }
    }
    const ov = OVERRIDES[k];
    if (ov) {
      (ov.remove || []).forEach(([x, y]) => { if (x >= 0 && y >= 0 && x < gW && y < gH) data[y * gW + x] = 0; });
      (ov.add || []).forEach(([x, y]) => { if (x >= 0 && y >= 0 && x < gW && y < gH) data[y * gW + x] = 1; });
    }
    g = { w: gW, h: gH, top, data };
    glyphCache.set(k, g);
    return g;
  }

  // Compose a string from glyphs with even spacing.
  function bits(id, h, str) {
    if (isNative(id)) return nativeBits(id, h, str);
    const key = id + '|' + h + '|' + str;
    let v = strCache.get(key);
    if (v) return v;
    const fam = familyOf(id);
    if (!fam) { v = { w: 0, h: 0, data: null }; strCache.set(key, v); return v; }
    str = String(str);
    const gap = Math.max(1, Math.round(h * 0.13));
    const placed = [];
    let x = 0, outH = h;
    for (const ch of str) {
      if (ch === ' ') { x += Math.round(h * 0.5); continue; }
      const g = glyphBits(id, h, ch);
      if (!g.data) { x += Math.round(h * 0.4); continue; }
      placed.push({ g, x });
      x += g.w + gap;
      if (g.top + g.h > outH) outH = g.top + g.h;
    }
    const W = Math.max(1, x > 0 ? x - gap : 1);
    const data = new Uint8Array(W * outH);
    for (const { g, x: gx } of placed) {
      for (let oy = 0; oy < g.h; oy++) {
        const ty = g.top + oy; if (ty < 0 || ty >= outH) continue;
        for (let ox = 0; ox < g.w; ox++) {
          if (g.data[oy * g.w + ox]) { const tx = gx + ox; if (tx >= 0 && tx < W) data[ty * W + tx] = 1; }
        }
      }
    }
    v = { w: W, h: outH, data };
    strCache.set(key, v);
    return v;
  }

  function fit(p, x, y, str, opts) {
    const b = bits(opts.font, opts.h, String(str));
    if (!b.data) return x;
    for (let oy = 0; oy < b.h; oy++)
      for (let ox = 0; ox < b.w; ox++)
        if (b.data[oy * b.w + ox]) p.add(x + ox, y + oy, opts.color, opts.a);
    return x + b.w;
  }
  function fitW(str, opts) { return bits(opts.font, opts.h, String(str)).w; }
  function fitCenter(p, cx, y, str, opts) {
    return fit(p, Math.round(cx - fitW(str, opts) / 2), y, str, opts);
  }
  function fitRight(p, xr, y, str, opts) {
    return fit(p, Math.round(xr - fitW(str, opts)), y, str, opts);
  }

  function clearCache() { refCache.clear(); glyphCache.clear(); strCache.clear(); }

  // Debug: ASCII dump of a glyph bitmap (for deciding pixel overrides).
  function dump(id, h, ch) {
    const g = glyphBits(id, h, ch);
    if (!g.data) return '(empty)';
    let s = ch + '  w=' + g.w + ' h=' + g.h + ' top=' + g.top + '\n';
    for (let y = 0; y < g.h; y++) {
      let row = '';
      for (let x = 0; x < g.w; x++) row += g.data[y * g.w + x] ? '#' : '.';
      s += row + '\n';
    }
    return s;
  }

  global.FontBlit = {
    FONTS, fit, fitW, fitCenter, fitRight, clearCache,
    OVERRIDES, glyphBits, dump,
    setOverride: function (id, h, ch, ov) { OVERRIDES[id + '|' + h + '|' + ch] = ov; glyphCache.delete(id + '|' + h + '|' + ch); strCache.clear(); }
  };

  // Pull in any native bitmap fonts loaded before us (geist-native.js).
  if (global.GEIST_NATIVE_FONTS) {
    for (const id in global.GEIST_NATIVE_FONTS) {
      const e = global.GEIST_NATIVE_FONTS[id];
      registerNative(id, e.label || id, e.data || e);
    }
  }
})(window);
