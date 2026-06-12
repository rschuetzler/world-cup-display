// wc-flags.js — tiny LED flags for the 128×64 panel.
//
// Each flag is a *resolution-independent sampler*: fn(fx, fy, w, h) → hex
// colour (or null = leave the LED dark). Because flags are sampled rather
// than stored as a fixed bitmap, the exact same flag draws cleanly at 9px or
// 28px wide — which is the whole point of this study: finding the size at
// which each one stays readable on a 2mm-pitch grid.
//
// Conventions: flags are ~3:2. "Black" flag fields render as a DIM grey, not
// true black — on a real panel a black stripe is just unlit LEDs, so for a
// legibility study we light it faintly so the band is actually visible.
// No federation crests — generic national colours + simple devices only.
// ─────────────────────────────────────────────────────────────────────

(function (global) {
  'use strict';

  // LED-tuned flag palette (saturated, single-chroma, reads at 1 dot).
  const C = {
    red:  '#ee3b3b', white: '#eef2ff', blue: '#2f6fe0', navy: '#244a9a',
    sky:  '#74b4ee', grass: '#1fae5a',
    yel:  '#ffd23f', gold: '#f5c542', black: '#262b38', orange: '#ff8a3c',
    maroon: '#b6443f', cyan: '#6cc4f5', grey: '#3a4150'
  };
  const G = C.grass;

  // ── shape helpers (pixel space, aspect-correct circles) ──────────────────
  // band index for n equal stripes along an axis value t in [0,size)
  function bandV(fx, w, n) { return Math.min(n - 1, Math.floor(fx * n / w)); }
  function bandH(fy, h, n) { return Math.min(n - 1, Math.floor(fy * n / h)); }
  // is (fx,fy) inside a disc centred at norm (cxN,cyN) radius rN·w (round on screen)
  function inDisc(fx, fy, w, h, cxN, cyN, rN) {
    const cx = cxN * w, cy = cyN * h, R = rN * w;
    const dx = (fx + 0.5) - cx, dy = ((fy + 0.5) - cy) * (w / h);
    return dx * dx + dy * dy <= R * R;
  }
  // diamond (rhombus) inscribed, half-extents axN·w / ayN·h
  function inDiamond(fx, fy, w, h, axN, ayN) {
    const dx = Math.abs((fx + 0.5) / w - 0.5) / axN;
    const dy = Math.abs((fy + 0.5) / h - 0.5) / ayN;
    return dx + dy <= 1;
  }
  // upright cross: vertical bar width vwN, horizontal bar height hhN, centred
  function inCross(fx, fy, w, h, vwN, hhN) {
    const u = (fx + 0.5) / w - 0.5, v = (fy + 0.5) / h - 0.5;
    return Math.abs(u) <= vwN / 2 || Math.abs(v) <= hhN / 2;
  }
  // simple 5-point-ish star → small plus/dot cluster centred at (cxN,cyN)
  function inStar(fx, fy, w, h, cxN, cyN, rN) {
    const cx = cxN * w, cy = cyN * h;
    const dx = Math.abs((fx + 0.5) - cx), dy = Math.abs((fy + 0.5) - cy) * (w / h);
    const R = rN * w;
    return (dx + dy) <= R * 1.15;          // diamond-ish twinkle, crisp at scale
  }

  // ── flag samplers ────────────────────────────────────────────────────────
  const F = {
    // Stars-and-stripes: blue canton + star texture, 7 stripes.
    USA(fx, fy, w, h) {
      const cantonW = w * 0.42, cantonH = h * 0.54;
      if (fx < cantonW && fy < cantonH) {
        // sparse star field: every other dot
        return (((fx % 2) + (fy % 2)) === 0) ? C.white : C.navy;
      }
      return bandH(fy, h, 7) % 2 ? C.white : C.red;
    },
    MEX(fx, fy, w, h) {
      const c = [G, C.white, C.red][bandV(fx, w, 3)];
      if (c === C.white && inDisc(fx, fy, w, h, 0.5, 0.5, 0.10)) return C.maroon; // emblem hint
      return c;
    },
    CAN(fx, fy, w, h) {
      const u = (fx + 0.5) / w;
      if (u < 0.27 || u > 0.73) return C.red;        // side bars
      // maple-leaf hint: red blob centre
      if (inStar(fx, fy, w, h, 0.5, 0.5, 0.16)) return C.red;
      return C.white;
    },
    BRA(fx, fy, w, h) {
      if (inDisc(fx, fy, w, h, 0.5, 0.5, 0.17)) return C.blue;   // celestial globe
      if (inDiamond(fx, fy, w, h, 0.42, 0.40)) return C.yel;     // rhombus
      return G;
    },
    ARG(fx, fy, w, h) {
      if (inDisc(fx, fy, w, h, 0.5, 0.5, 0.11)) return C.gold;   // sun
      return [C.sky, C.white, C.sky][bandH(fy, h, 3)];
    },
    FRA(fx, fy, w, h) { return [C.blue, C.white, C.red][bandV(fx, w, 3)]; },
    ENG(fx, fy, w, h) { return inCross(fx, fy, w, h, 0.18, 0.22) ? C.red : C.white; },
    ESP(fx, fy, w, h) {
      const v = (fy + 0.5) / h;
      if (v < 0.25 || v > 0.75) return C.red;
      if (inDisc(fx, fy, w, h, 0.34, 0.5, 0.08)) return C.red;   // crest hint
      return C.gold;
    },
    GER(fx, fy, w, h) { return [C.black, C.red, C.gold][bandH(fy, h, 3)]; },
    POR(fx, fy, w, h) {
      const split = w * 0.4;
      if (Math.abs((fx + 0.5) - split) < 1.1 && inDisc(fx, fy, w, h, 0.4, 0.5, 0.16)) return C.yel;
      return fx < split ? G : C.red;
    },
    NED(fx, fy, w, h) { return [C.red, C.white, C.blue][bandH(fy, h, 3)]; },
    BEL(fx, fy, w, h) { return [C.black, C.gold, C.red][bandV(fx, w, 3)]; },
    CRO(fx, fy, w, h) {
      // checker hint: small 2-tone block centred
      if (inDisc(fx, fy, w, h, 0.5, 0.5, 0.14)) return (((fx >> 1) + (fy >> 1)) % 2 ? C.red : C.white);
      return [C.red, C.white, C.blue][bandH(fy, h, 3)];
    },
    ITA(fx, fy, w, h) { return [G, C.white, C.red][bandV(fx, w, 3)]; },
    URU(fx, fy, w, h) {
      const cantonW = w * 0.42, cantonH = h * 0.55;
      if (fx < cantonW && fy < cantonH) {
        return inDisc(fx, fy, w, h, 0.21, 0.27, 0.10) ? C.gold : C.white; // sun of may
      }
      return bandH(fy, h, 9) % 2 ? C.sky : C.white;
    },
    COL(fx, fy, w, h) {
      const v = (fy + 0.5) / h;
      return v < 0.5 ? C.yel : (v < 0.75 ? C.blue : C.red);
    },
    JPN(fx, fy, w, h) { return inDisc(fx, fy, w, h, 0.5, 0.5, 0.2) ? C.red : C.white; },
    KOR(fx, fy, w, h) {
      if (inDisc(fx, fy, w, h, 0.5, 0.5, 0.18)) {
        return (fy + 0.5) < h * 0.5 ? C.red : C.blue;             // taegeuk (simplified)
      }
      return C.white;
    },
    SEN(fx, fy, w, h) {
      if (inStar(fx, fy, w, h, 0.5, 0.5, 0.12)) return G;         // green star on gold
      return [G, C.yel, C.red][bandV(fx, w, 3)];
    },
    MAR(fx, fy, w, h) { return inStar(fx, fy, w, h, 0.5, 0.5, 0.18) ? G : C.red; },
    AUS(fx, fy, w, h) {
      // union hint top-left + a couple of southern-cross dots
      if (fx < w * 0.42 && fy < h * 0.5 && inCross(fx - 0, fy - 0, w * 0.42 * 2, h, 0.16, 0.18)) return C.white;
      if (inStar(fx, fy, w, h, 0.72, 0.62, 0.07)) return C.white;
      if (inStar(fx, fy, w, h, 0.84, 0.40, 0.06)) return C.white;
      if (inStar(fx, fy, w, h, 0.30, 0.80, 0.06)) return C.white;
      return C.navy;
    },
    SUI(fx, fy, w, h) { return inCross(fx, fy, w, h, 0.16, 0.16) ? C.white : C.red; }
  };

  // Draw flag `code` into the panel at (ox,oy), w×h. Unknown → grey box.
  function draw(p, ox, oy, w, h, code) {
    const f = F[code];
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const c = f ? f(x, y, w, h) : (((x + y) % 2) ? C.grey : C.black);
        if (c) p.set(ox + x, oy + y, c);
      }
    }
  }

  function has(code) { return !!F[code]; }
  function codes() { return Object.keys(F); }

  global.WCFlags = { draw, has, codes, C };
})(window);
