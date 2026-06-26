#include "render.h"
#include <math.h>
#include "flags.h"
#include "fmt.h"
#include "font.h"
#include "geist.h"
#include "palette.h"
#include "teams.h"

namespace {
// Literal colors used by the goal celebration (not palette tokens in the JS).
const Rgb GOAL_WHITE = {0xFF, 0xFF, 0xFF};
const Rgb SPARKLE_WHITE = {0xDF, 0xE8, 0xFF};

inline int rnd(float v) { return (int)lroundf(v); }
inline int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

bool blink(int64_t now) { return (now / 600) % 2 == 0; }

// Advance of a string as the JS drawText returns it (6px/char including the
// trailing gap — one more than Font::textW).
int textAdv(const String& s) { return (int)s.length() * 6; }

// Filled disc — port of Glyphs.disc (the dot primitive), r*r + r*0.4 radius.
void disc(Fb& fb, int cx, int cy, int r, Rgb c, float a = 1.0f) {
  float r2 = r * r + r * 0.4f;
  for (int dy = -r; dy <= r; dy++)
    for (int dx = -r; dx <= r; dx++)
      if (dx * dx + dy * dy <= r2) fb.add(cx + dx, cy + dy, c, a);
}

void hline(Fb& fb, int x, int y, int w, Rgb c) { fb.rect(x, y, w, 1, c, 1.0f); }

void miniFlag(Fb& fb, int x, int y, int w, int h, const String& code, bool flags) {
  if (flags) Flags::draw(fb, x, y, w, h, code.c_str());
}

// Width of a kickoff label drawn with the tight 2px weekday gap.
int koW(const Fmt::Ko& k, int gap) {
  if (k.wd.length() > 0) return Font::textW(k.wd.c_str()) + gap + Font::textW(k.cl.c_str());
  return Font::textW(k.cl.c_str());
}

Rgb codeCol(bool leading) { return leading ? Pal::wc_white : Pal::soft; }

// ── NOW & NEXT ────────────────────────────────────────────────────────────
void nowNextHeader(Fb& fb, const Snapshot& s) {
  int64_t now = s.now;
  bool anyLive = false;
  for (const auto& r : s.live)
    if (!r.final) { anyLive = true; break; }
  if (anyLive) {
    if (blink(now)) disc(fb, 6, 4, 1, Pal::live);
    Font::text(fb, 11, 1, "LIVE", Pal::live);
    Font::textRight(fb, 124, 1, Fmt::weekday(now), Pal::dim);
    return;
  }
  if (s.next.empty()) {
    Font::text(fb, 4, 1, "WORLD CUP", Pal::soft);
  } else {
    int64_t nextKo = s.next[0].kickoffMs;
    for (const auto& n : s.next)
      if (n.kickoffMs < nextKo) nextKo = n.kickoffMs;
    int countdownX = 4 + Font::textW("KICKOFF") + 4;
    Font::text(fb, 4, 1, "KICKOFF", Pal::soft);
    Font::text(fb, countdownX, 1, Fmt::countdownLabel(nextKo - now).c_str(), Pal::gold);
  }
  Font::textRight(fb, 124, 1, Fmt::weekday(now), Pal::dim);
}

void idleHero(Fb& fb, const NextRow& m, int64_t now, bool flags) {
  const int fw = 26, fh = 17, fy = 10;
  if (flags) {
    Flags::draw(fb, 6, fy, fw, fh, m.home.c_str());
    Flags::draw(fb, 122 - fw, fy, fw, fh, m.away.c_str());
  }
  String l1 = m.home + " V " + m.away;
  int x0 = rnd(64 - Font::textW(l1.c_str()) / 2.0f);
  Font::text(fb, x0, 12, m.home.c_str(), Pal::wc_white);
  Font::text(fb, x0 + textAdv(m.home + " "), 12, "V", Pal::dim);
  Font::text(fb, x0 + textAdv(m.home + " V "), 12, m.away.c_str(), Pal::wc_white);

  const int gap = 2;
  Fmt::Ko k = Fmt::ko(m.kickoffMs, now);
  if (k.wd.length() == 0) {
    Font::textCenter(fb, 64, 21, k.cl.c_str(), Pal::gold);
  } else {
    int tx = rnd(64 - koW(k, gap) / 2.0f);
    Font::text(fb, tx, 21, k.wd.c_str(), Pal::dim);
    Font::text(fb, tx + Font::textW(k.wd.c_str()) + gap, 21, k.cl.c_str(), Pal::gold);
  }
}

void nowNextLiveRow(Fb& fb, const LiveRow& m, int y, int64_t now, bool flags) {
  // Status straight from the API clock — not wall-clock — so it tracks
  // halftime, stoppage, and each game's independent full time.
  String status;
  Rgb statusCol = Pal::gold;
  if (m.final) {
    status = "FINAL";
    statusCol = Pal::win;
  } else if (m.ht) {
    status = "HT";
  } else {
    status = m.stoppage > 0 ? String(m.minute) + "+" + String(m.stoppage) + "'"
                            : String(m.minute) + "'";
  }
  int lead = m.hs > m.as ? 0 : (m.as > m.hs ? 1 : -1);  // 0 home, 1 away, -1 none
  String score = String(m.hs) + "-" + String(m.as);

  int x = 3;
  miniFlag(fb, x, y, 10, 7, m.home, flags);
  if (flags) x += 13;
  Font::text(fb, x, y, m.home.c_str(), codeCol(lead == 0));
  x += textAdv(m.home) + 3;
  Font::text(fb, x, y, score.c_str(), Pal::wc_white);
  x += textAdv(score) + 3;
  Font::text(fb, x, y, m.away.c_str(), codeCol(lead == 1));
  x += textAdv(m.away) + 2;
  miniFlag(fb, x, y, 10, 7, m.away, flags);
  Font::textRight(fb, 124, y, status.c_str(), statusCol);
}

void nowNext(Fb& fb, const Snapshot& s) {
  int64_t now = s.now;
  bool f = s.flags;

  nowNextHeader(fb, s);

  bool idle = s.live.empty() && !s.next.empty();

  // The next-kickoff rows to draw below the divider (at most 3).
  std::vector<NextRow> rows;
  if (idle) {
    idleHero(fb, s.next[0], now, f);
    for (size_t i = 1; i < s.next.size() && rows.size() < 3; i++) rows.push_back(s.next[i]);
  } else {
    for (size_t i = 0; i < s.live.size(); i++)
      nowNextLiveRow(fb, s.live[i], 10 + (int)i * 10, now, f);
    for (size_t i = 0; i < s.next.size() && rows.size() < 3; i++) rows.push_back(s.next[i]);
  }

  int labelEnd = 4 + Font::textW("NEXT") + 4;
  Font::text(fb, 4, 31, "NEXT", Pal::dim);
  hline(fb, labelEnd, 34, 124 - labelEnd, Pal::faint);

  const int gap = 2;
  int codeW = Font::textW("AAA");
  int homeX = f ? 16 : 3;
  int homeEnd = homeX + codeW;

  int maxTimeW = 0;
  for (const auto& m : rows) {
    int w = koW(Fmt::ko(m.kickoffMs, now), gap);
    if (w > maxTimeW) maxTimeW = w;
  }

  int awayRight = 124 - maxTimeW - 4;
  if (awayRight > 80) awayRight = 80;
  auto awayCodeRightFor = [&](int ar) { return ar - (f ? 12 : 0); };
  // V centres on a whole pixel only when the code gap is odd -> nudge away +1px.
  if (((awayCodeRightFor(awayRight) - codeW - homeEnd) % 2) == 0) awayRight += 1;

  int awayFlagX = awayRight - (f ? 10 : 0);
  int awayCodeRight = awayCodeRightFor(awayRight);
  int awayStart = awayCodeRight - codeW;
  int vX = (homeEnd + awayStart - Font::textW("V")) / 2;

  for (size_t i = 0; i < rows.size(); i++) {
    const NextRow& m = rows[i];
    int ny = 39 + (int)i * 9;
    Fmt::Ko k = Fmt::ko(m.kickoffMs, now);

    miniFlag(fb, 3, ny, 10, 7, m.home, f);
    Font::text(fb, homeX, ny, m.home.c_str(), Pal::soft);
    miniFlag(fb, awayFlagX, ny, 10, 7, m.away, f);
    Font::textRight(fb, awayCodeRight, ny, m.away.c_str(), Pal::soft);
    Font::text(fb, vX, ny, "V", Pal::dim);
    Font::textRight(fb, 124, ny, k.cl.c_str(), Pal::soft);
    if (k.wd.length() > 0)
      Font::textRight(fb, 124 - Font::textW(k.cl.c_str()) - gap, ny, k.wd.c_str(), Pal::dim);
  }
}

// ── LIVE ──────────────────────────────────────────────────────────────────
void liveStatus(Fb& fb, int minute, int stoppage, bool ht, int64_t now) {
  int rx = 124;
  String lbl = ht ? String("HT")
                  : (stoppage > 0 ? String(minute) + "+" + String(stoppage) + "'"
                                  : String(minute) + "'");
  Font::textRight(fb, rx, 2, lbl.c_str(), Pal::gold);
  if (ht) return;  // paused — no ticking LIVE indicator
  rx = rx - Font::textW(lbl.c_str()) - 5;
  Font::textRight(fb, rx, 2, "LIVE", Pal::live);
  if (blink(now)) disc(fb, rx - Font::textW("LIVE") - 4, 5, 1, Pal::live);
}

// ORIG s-s DEST hero — codes flank a big centred score (flags-off fallback).
void heroScore(Fb& fb, int y, const String& home, const String& away, const String& score,
               Rgb homeCol, Rgb awayCol, Rgb scoreCol) {
  Font::text2x(fb, 6, y, home.c_str(), homeCol);
  Font::text2x(fb, 122 - Font::text2xW(away.c_str()), y, away.c_str(), awayCol);
  Geist::bigCenter(fb, 64, y - 2, score.c_str(), 18, scoreCol);
}

// Match-progress bar (0..90); faint trough + pitch fill; ball head unless final.
void matchBar(Fb& fb, int x, int y, int w, int minute, Rgb color, bool ball) {
  float pct = minute / 90.0f;
  if (pct < 0) pct = 0;
  if (pct > 1) pct = 1;
  for (int i = 0; i < w; i++) fb.add(x + i, y, Pal::faint, 1);
  int lit = rnd(pct * w);
  for (int i = 0; i < lit; i++) fb.add(x + i, y, color, 1);
  fb.add(x + rnd(w / 2.0f), y - 1, Pal::dim, 1);  // half (45') tick
  if (ball) disc(fb, x + lit, y, 1, Pal::ball);
}

void live(Fb& fb, const Snapshot& s) {
  bool finalHold = s.finalHold;
  int minute = clampi(s.minute, 0, 95);
  int hs = clampi(s.hs, 0, 9);
  int as = clampi(s.as, 0, 9);
  String score = String(hs) + "-" + String(as);

  Font::text(fb, 4, 2, s.stage.c_str(), Pal::soft);
  if (finalHold)
    Font::textRight(fb, 124, 2, "FINAL", Pal::win);
  else
    liveStatus(fb, minute, s.stoppage, s.ht, s.now);

  if (s.flags) {
    const int fw = 26, fh = 17, fy = 11;
    Flags::draw(fb, 6, fy, fw, fh, s.home.c_str());
    Flags::draw(fb, 122 - fw, fy, fw, fh, s.away.c_str());
    Font::textCenter(fb, 6 + fw / 2, fy + fh + 2, s.home.c_str(), Pal::wc_white);
    Font::textCenter(fb, 122 - fw / 2, fy + fh + 2, s.away.c_str(), Pal::ice);
    Geist::bigCenter(fb, 64, 13, score.c_str(), 20, Pal::wc_white);
  } else {
    heroScore(fb, 14, s.home, s.away, score, Pal::wc_white, Pal::ice, Pal::wc_white);
  }

  hline(fb, 8, 40, 112, Pal::faint);

  if (finalHold) {
    matchBar(fb, 8, 46, 112, 90, Pal::pitch, false);
    Font::textRight(fb, 120, 54, "FULL TIME", Pal::soft);
  } else {
    const char* half = s.ht ? "HALF TIME" : (minute <= 45 ? "1ST HALF" : "2ND HALF");
    matchBar(fb, 8, 46, 112, minute, Pal::pitch, !s.ht);
    Font::textRight(fb, 120, 54, half, Pal::soft);  // minute shown top-right
  }
}

// ── GOAL CELEBRATION ────────────────────────────────────────────────────────
void draw2xCenter(Fb& fb, int cx, int y, const String& str, Rgb color) {
  Font::text2x(fb, rnd(cx - Font::text2xW(str.c_str()) / 2.0f), y, str.c_str(), color);
}

void fullWash(Fb& fb, Rgb col, float a) { fb.rect(0, 0, 128, 64, col, a); }

// Stadium camera-flash sparkles, deterministic per t (a direct port of the JS).
void sparkles(Fb& fb, int64_t t, Rgb col) {
  for (int i = 0; i <= 25; i++) {
    float phase = t / 1000.0f * (1.3f + (i % 5) * 0.27f) + i * 1.7f;
    if (phase - (long)phase > 0.16f) continue;
    int hx = (i * 53) % 123 + 2;
    int hy = (i * 29) % 60 + 2;
    Rgb c = (i % 3 == 0) ? col : SPARKLE_WHITE;
    fb.add(hx, hy, c, 1);
    if (i % 4 == 0) {
      fb.add(hx - 1, hy, c, 0.5f);
      fb.add(hx + 1, hy, c, 0.5f);
      fb.add(hx, hy - 1, c, 0.5f);
      fb.add(hx, hy + 1, c, 0.5f);
    }
  }
}

// Moving diagonal chevron wash in the team colour.
void chevrons(Fb& fb, float sec, Rgb col) {
  int sft = (int)(sec * 18);
  for (int y = 0; y <= 63; y++)
    for (int x = 0; x <= 127; x++)
      if ((x + y + sft) % 14 < 2) fb.add(x, y, col, 0.16f);
}

// Animated dashed rule (ticker frame).
void dashRow(Fb& fb, int y, Rgb col, float sec) {
  int off = (int)(sec * 22);
  for (int x = 0; x <= 127; x++)
    if ((x + off) % 6 < 3) fb.add(x, y, col, 0.55f);
}

// A continuous ribbon of the scoring team's flag, scrolling.
void flagRibbon(Fb& fb, float sec, const String& code, int y, bool flags) {
  if (!flags || !Flags::has(code.c_str())) return;
  int cell = 12 + 4;
  int base = -((long)(sec * 26) % cell);
  for (int x = base; x < 128; x += cell) Flags::draw(fb, x, y, 12, 8, code.c_str());
}

void goalCelebration(Fb& fb, int64_t t, const Snapshot& s) {
  float sec = t / 1000.0f;
  Rgb col = Teams::color(s.code.c_str());
  int hs = clampi(s.hs, 0, 9);
  int as = clampi(s.as, 0, 9);
  bool f = s.flags;

  if (sec < 1.6f) {
    // Phase A — strobe burst
    bool on = ((int)(sec / 0.13f)) % 2 == 0;
    fullWash(fb, col, on ? 0.42f : 0.10f);
    sparkles(fb, t, col);
    draw2xCenter(fb, 64, 18, "GOAL!", on ? GOAL_WHITE : col);
    draw2xCenter(fb, 64, 34, s.code, on ? col : GOAL_WHITE);
  } else if (sec < 13.0f) {
    // Phase B — the GOOOOOOOOOOL marquee
    String os;
    for (int i = 0; i < 26; i++) os += 'O';
    String msg = String("G") + os + "L!   " + Teams::name(s.code.c_str()) + " SCORES!   ";
    int mW = Font::text2xW(msg.c_str()) + 14;
    int base = -((long)((sec - 1.6f) * 52) % mW);

    chevrons(fb, sec, col);
    dashRow(fb, 17, col, sec);
    dashRow(fb, 37, col, sec);
    for (int x = base; x < 128 + mW; x += mW) Font::text2x(fb, x, 22, msg.c_str(), GOAL_WHITE);
    flagRibbon(fb, sec, s.code, 52, f);
    sparkles(fb, t, col);
  } else {
    // Phase C — freeze-frame score reveal
    float rt = sec - 13.0f;
    bool flash = ((int)(rt / 0.28f)) % 2 == 0;
    const int fw = 26, fy = 20;
    chevrons(fb, sec, col);
    sparkles(fb, t, col);
    draw2xCenter(fb, 64, 1, s.code + " GOAL!", flash ? col : GOAL_WHITE);
    miniFlag(fb, 6, fy, fw, 17, s.home, f);
    miniFlag(fb, 122 - fw, fy, fw, 17, s.away, f);
    String score = String(hs) + "-" + String(as);
    Geist::bigCenter(fb, 64, 22, score.c_str(), 20, GOAL_WHITE);
    Font::textCenter(fb, 64, 50, "WHAT A GOAL", Pal::gold);
  }
}

void goal(Fb& fb, const Snapshot& s) {
  int64_t t = s.now - s.goalStartedAt;
  if (t >= 16500)
    live(fb, s);
  else
    goalCelebration(fb, t, s);
}
}  // namespace

namespace Render {
void board(Fb& fb, const Snapshot& s) {
  switch (s.state) {
    case Board::NowNext:
      nowNext(fb, s);
      break;
    case Board::Live:
      live(fb, s);
      break;
    case Board::Goal:
      goal(fb, s);
      break;
  }
}
}  // namespace Render
