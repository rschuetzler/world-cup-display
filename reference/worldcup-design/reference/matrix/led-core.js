// led-core.js — 128×64 RGB LED matrix simulation.
//
// Renders a logical W×H framebuffer to a canvas as a grid of round LED
// dots with subtle per-pixel bloom, tuned to read like a fine-pitch
// (2mm) high-density panel: dots are close-packed with a small dark gap,
// lit dots glow gently into their neighbours.
//
// A renderer writes colours into the framebuffer via the drawing helpers
// (see fonts.js / renderers.js) then calls panel.present() to composite.
// ─────────────────────────────────────────────────────────────────────

(function (global) {
  'use strict';

  // Parse '#rrggbb' (or '#rgb') to [r,g,b]. Cached.
  const _hexCache = {};
  function hex(c) {
    if (Array.isArray(c)) return c;
    let v = _hexCache[c];
    if (v) return v;
    let h = c.replace('#', '');
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    v = [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
    _hexCache[c] = v;
    return v;
  }

  class LEDPanel {
    constructor(canvas, opts) {
      opts = opts || {};
      this.W = opts.W || 128;
      this.H = opts.H || 64;
      this.scale = opts.scale || 8;          // device px per logical pixel
      this.dotR = opts.dotR || this.scale * 0.40;   // lit-dot radius
      this.wellR = opts.wellR || this.scale * 0.30; // off-dot radius
      this.base = opts.base || '#06070a';    // panel substrate (between dots)
      this.well = opts.well || '#13161d';    // unlit LED colour
      this.glow = opts.glow == null ? 1 : opts.glow; // bloom multiplier

      this.canvas = canvas;
      canvas.width = this.W * this.scale;
      canvas.height = this.H * this.scale;
      this.ctx = canvas.getContext('2d');

      // Float framebuffer (r,g,b) so overlapping additive writes blend.
      const n = this.W * this.H;
      this.r = new Float32Array(n);
      this.g = new Float32Array(n);
      this.b = new Float32Array(n);

      this._buildOffLayer();
    }

    // Pre-render the dark, unlit dot grid once. Composited each frame as a
    // cheap "clear" so only lit dots are drawn per-tick.
    _buildOffLayer() {
      const off = document.createElement('canvas');
      off.width = this.canvas.width;
      off.height = this.canvas.height;
      const c = off.getContext('2d');
      c.fillStyle = this.base;
      c.fillRect(0, 0, off.width, off.height);
      c.fillStyle = this.well;
      const s = this.scale, half = s / 2, r = this.wellR;
      for (let y = 0; y < this.H; y++) {
        for (let x = 0; x < this.W; x++) {
          c.beginPath();
          c.arc(x * s + half, y * s + half, r, 0, 6.2832);
          c.fill();
        }
      }
      this._offLayer = off;
    }

    clear() {
      this.r.fill(0); this.g.fill(0); this.b.fill(0);
    }

    // Add colour at (x,y) with intensity 0..1. Additive so glints stack.
    add(x, y, color, a) {
      x |= 0; y |= 0;
      if (x < 0 || y < 0 || x >= this.W || y >= this.H) return;
      a = a == null ? 1 : a;
      const rgb = hex(color);
      const i = y * this.W + x;
      this.r[i] = Math.min(255, this.r[i] + rgb[0] * a);
      this.g[i] = Math.min(255, this.g[i] + rgb[1] * a);
      this.b[i] = Math.min(255, this.b[i] + rgb[2] * a);
    }

    // Hard set (replaces). Used where stacking is undesirable.
    set(x, y, color, a) {
      x |= 0; y |= 0;
      if (x < 0 || y < 0 || x >= this.W || y >= this.H) return;
      a = a == null ? 1 : a;
      const rgb = hex(color);
      const i = y * this.W + x;
      this.r[i] = rgb[0] * a; this.g[i] = rgb[1] * a; this.b[i] = rgb[2] * a;
    }

    rect(x, y, w, h, color, a) {
      for (let yy = 0; yy < h; yy++)
        for (let xx = 0; xx < w; xx++) this.add(x + xx, y + yy, color, a);
    }

    // Composite framebuffer → canvas: dark grid, then lit dots + bloom.
    present() {
      const ctx = this.ctx;
      const TW = global.TW || {};
      const bright = TW.brightness == null ? 1 : TW.brightness;
      const glowMul = TW.glow == null ? this.glow : TW.glow;
      ctx.globalCompositeOperation = 'source-over';
      ctx.globalAlpha = 1;
      ctx.drawImage(this._offLayer, 0, 0);

      const s = this.scale, half = s / 2;
      const W = this.W, H = this.H;
      const dotR = this.dotR, glowR = this.scale * 1.25, glowA = 0.5 * glowMul;

      // Pass 1: additive bloom halos.
      ctx.globalCompositeOperation = 'lighter';
      for (let y = 0; y < H; y++) {
        for (let x = 0; x < W; x++) {
          const i = y * W + x;
          let r = this.r[i], g = this.g[i], b = this.b[i];
          if (r + g + b < 6) continue;
          r = Math.min(255, r * bright); g = Math.min(255, g * bright); b = Math.min(255, b * bright);
          const cx = x * s + half, cy = y * s + half;
          const m = Math.max(r, g, b) / 255;
          const grd = ctx.createRadialGradient(cx, cy, 0, cx, cy, glowR);
          grd.addColorStop(0, `rgba(${r | 0},${g | 0},${b | 0},${glowA * m})`);
          grd.addColorStop(1, `rgba(${r | 0},${g | 0},${b | 0},0)`);
          ctx.fillStyle = grd;
          ctx.beginPath();
          ctx.arc(cx, cy, glowR, 0, 6.2832);
          ctx.fill();
        }
      }

      // Pass 2: crisp dots on top.
      ctx.globalCompositeOperation = 'source-over';
      for (let y = 0; y < H; y++) {
        for (let x = 0; x < W; x++) {
          const i = y * W + x;
          let r = this.r[i], g = this.g[i], b = this.b[i];
          if (r + g + b < 6) continue;
          r = Math.min(255, r * bright); g = Math.min(255, g * bright); b = Math.min(255, b * bright);
          ctx.fillStyle = `rgb(${r | 0},${g | 0},${b | 0})`;
          ctx.beginPath();
          ctx.arc(x * s + half, y * s + half, dotR, 0, 6.2832);
          ctx.fill();
        }
      }
      ctx.globalCompositeOperation = 'source-over';
    }
  }

  global.LEDPanel = LEDPanel;
  global.LEDhex = hex;
})(window);
