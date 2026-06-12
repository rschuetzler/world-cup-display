# Handoff: World Cup repurpose of the 128×64 RGB matrix display

## Overview

This package repurposes the TravisTracker 128×64 RGB LED panel from a flight
tracker into a **World Cup match display**. It defines **two** display boards
plus a **goal-celebration animation**:

1. **Now & Next** — live scores of in-play matches up top, the next few kickoff
   times below. The "from across the room, what's the score and when's the next
   one" board.
2. **Live match** — one match in full: big national flags either side of a big
   score, the running minute, and a match-progress bar.
3. **GOOOOOOOOOOL celebration** — a ~16.5-second full-panel takeover that plays
   on the Live board the moment a goal is scored (score increments): a strobe
   burst, a giant scrolling `GOOOOOOOOOOOOOOOOOOOOOOOOOOL — MEXICO SCORES!`
   marquee with a scrolling flag ribbon, then a freeze-frame score reveal.

The design deliberately reuses the existing renderer architecture (one function
per display state, piping a framebuffer through Font/Glyphs/Palette helpers), so
it should slot into the current pipeline rather than replace it.

---

## About the design files

The files under **`reference/`** are **design references built in HTML/JS** —
a faithful *simulation* of the LED panel that runs in a browser. They show the
exact intended look, layout, colors, copy, and motion. **They are not the
production implementation.** The panel is driven by the Elixir/Phoenix server
(it renders RGB565 frames; the device blits them — see
`docs/matrix-display-protocol.md`). The task is to **recreate these boards in
the existing `TravisTracker.Matrix` pipeline**, not to ship the JS.

The JS sim was itself ported from the same `renderers.js` that
`lib/travis_tracker/matrix/renderers.ex` is ported from, so the mapping is
near 1:1 — the JS `p` (panel) calls correspond directly to `Framebuffer` /
`Font` / `Glyphs` / `Palette` calls in Elixir.

### Reference file map

| File | What it is | Elixir analogue |
|---|---|---|
| `reference/World Cup Display 128x64.html` | The gallery shell + Tweaks panel (browser-only) | preview pages / `matrix_demo.ex` |
| `reference/worldcup/wc-renderers.js` | **The two boards + goal animation.** Read this first. | `matrix/renderers.ex` |
| `reference/worldcup/wc-data.js` | Teams (codes, names, flag colors), fixtures, time formatters | `display_fixtures.ex` + a new teams module + `matrix/fmt.ex` |
| `reference/worldcup/wc-flags.js` | Resolution-independent flag pixel-art (samplers) | **new** `matrix/flags.ex` |
| `reference/worldcup/wc-app.js` | Gallery builder + 30fps loop (browser-only) | n/a (preview harness) |
| `reference/matrix/*.js` | The shared LED engine (led-core, fonts, fontblit, geist-native) | `matrix/framebuffer.ex`, `font.ex`, `geist.ex`, `glyphs.ex` |

## Fidelity

**High-fidelity.** Colors, coordinates, typography, copy, and motion timings are
final and exact. Reproduce them pixel-for-pixel. Every coordinate below is in
panel space (128×64, origin top-left, y down). Where a value differs from the
existing flight build, it is called out.

---

## Target-architecture mapping (read this before coding)

The flight build's data flow is:

```
Display.State (decides state + builds snapshot from flight data)
   → Matrix.Renderers.render(snap)  (state → board fn → Framebuffer)
   → Rgb565 encode (+ optional Trailer for scroll/clock)
   → GET /d/:token/matrix.rgb565   (device blits; polls every X-Poll-Seconds)
```

Three things change for the World Cup version:

1. **New data source.** Flight snapshots become **match snapshots**. You need a
   football data feed (live scores + fixtures) behind a new snapshot builder
   (e.g. `TravisTracker.WorldCup.State`) that emits maps shaped like the
   fixtures in `wc-data.js`. This is the largest net-new piece and is
   independent of the rendering work.

2. **New render states.** Add `:now_next`, `:live`, and `:goal` renderers to
   `matrix/renderers.ex` (or a sibling `matrix/wc_renderers.ex`) and dispatch
   clauses. Each is a pure `fb, snap -> fb` function, exactly like `idle/2`,
   `in_flight/2`, etc.

3. **The goal animation needs a motion strategy** (next section) because the
   device **polls**; it does not run a 30fps loop like the browser sim.

### The goal animation and the polling constraint  ⚠️

The browser sim animates the celebration at 30fps. **The real device cannot do
that by base-frame polling** — it fetches a frame, then waits `X-Poll-Seconds`
(adaptive, ~15s in-flight). The protocol only animates two things on-device via
the binary trailer: **scroll strips** and **the clock**. So implement the goal
event one of two ways:

- **Recommended for v1 — "goal burst" fast-poll mode (server-only, no firmware
  change).** Add a transient `:goal` display state that stays active for ~16.5s
  after a goal. While it's active, the controller returns a very low
  `X-Poll-Seconds` (≈0.2–0.3) so the device polls ~3–5fps, and the `:goal`
  renderer draws each frame **deterministically from `snap.now - goal_started_at`**
  (the JS `goalCelebration(t)` is already a pure function of elapsed ms — port
  it directly). Then restore normal poll cadence. The marquee can *additionally*
  be emitted as a **scroll strip** (see below) so it scrolls smoothly even
  between polls. Trade-off: a brief network/CPU burst for ~16s; sparkle/strobe
  frame-rate is capped by the poll rate (still reads well; the JS sim confirms
  it at ~5fps).

- **Polished follow-up — trailer v1.2.** Add new descriptor `kind`s (e.g.
  `strobe`, `sparkle-field`, `flag-ribbon-scroll`, `big-score`) so the device
  animates the celebration locally at full fps with no network burst. More work
  (firmware + protocol), best as a fast-follow.

**The marquee as a scroll strip.** `Regions.scroll_text` + `Trailer` already
pan a horizontal text strip on-device. The `GOOOO…L — COUNTRY SCORES!` marquee
maps onto this directly *except* it uses the **2× font**; the current
`Trailer.strip/2` renders with `Font.text` (1×). Extend it to support a 2×
strip (render with `Font.text_2x` onto an `h=14` surface) and the marquee
becomes a single scroll region the device loops smoothly. The strobe and reveal
phases still need the burst mode (or trailer v1.2).

---

## Display 1 — NOW & NEXT  (`:now_next`)

**Purpose:** at-a-glance live scores + upcoming kickoffs.

**Snapshot shape** (see `wc-data.js` → `nowNext`):
```elixir
%{
  state: :now_next, now: <ms>, timezone: "America/New_York",
  live: [ %{home: "USA", away: "MEX", hs: 2, as: 1, kickoff_utc: <ms>, ht: false}, ... ],  # up to 2
  next: [ %{home: "BRA", away: "ESP", kickoff_utc: <ms>, tz: "America/New_York"}, ... ]    # 3
}
```

**Layout** (reference: `wc-renderers.js` → `nowNextA`):

- **Header, y=1.** Pulsing red dot at (6,4) on the blink cycle (`floor(now/600)`
  even). `"LIVE"` in **live red** at x=11. Current weekday (`FRI`) right-aligned
  at x=124 in **dim**.
- **Live rows** — up to two, at **y=10** and **y=20** (row pitch 10). Each row,
  left→right: flag **10×7** at x=3 → home code at x=16 → score `"h-as"` (e.g.
  `2-1`) in **white** → away code → away flag **10×7**. The **leading** team's
  code is **white**, the trailing/level one **soft**. Right-aligned at x=124:
  the live **minute as a bare number** (e.g. `78`, **no apostrophe** — this is
  load-bearing; the apostrophe misaligns the digits against the clocks below) or
  `HT`, in **gold**.
- **NEXT divider.** `"NEXT"` in **dim** at (4,31); a **faint** hline at y=34
  from just right of the label to x=124.
- **Next rows** — three, at **y=39, 48, 57** (row pitch 9). All three share ONE
  column grid derived from the **widest** kickoff label (so codes/flags/`V`/times
  line up vertically):
  - Home cluster left-anchored: flag 10×7 at x=3, home code at x=16 (**soft**).
  - `maxTimeW` = widest of all three time labels (see time format below).
  - `awayRight = min(80, 124 - maxTimeW - 4)`. If the resulting gap between the
    two codes is **even**, add 1px to `awayRight` so the 5px `V` centers on a
    whole pixel.
  - Away cluster right-anchored to that column: away flag 10×7, away code
    (**soft**), both fixed across rows.
  - **`V`** in **dim**, horizontally centered between the two codes.
  - **Kickoff time**, right-aligned at x=124. If the match is **today**: bare
    `HH:MM` (**soft**). If not today: weekday (**dim**) + `HH:MM` (**soft**)
    drawn with a **tight 2px gap** (not a full space) so it stays narrow enough
    to keep the centered `V` — e.g. `SAT 08:16` with "SAT" dimmer.

There is **no scrolling** on this board — it is a single static frame, cheap to
render and cache.

---

## Display 2 — LIVE MATCH  (`:live`)

**Purpose:** one match in full.

**Snapshot shape** (see `wc-data.js` → `live`):
```elixir
%{
  state: :live, now: <ms>,
  match: %{stage: "GROUP D", home: "USA", away: "MEX",
           venue: "LOS ANGELES", tz: "America/Los_Angeles", kickoff_utc: <ms>},
  minute: 78, hs: 2, as: 1     # live values (tweakable in the sim)
}
```

**Layout** (reference: `wc-renderers.js` → `liveA`):

- **Status row, y=2.** Stage (`GROUP D`) left in **soft**. Right side, packed
  toward x=124: minute `78'` in **gold**, then `LIVE` in **live red**, then a
  pulsing red dot.
- **Hero (flags on):** national flag **26×17** at (6,11) (home) and
  (122−26, 11) (away). The 3-letter code is centered **under** each flag at
  y=30 — home in **white**, away in **ice**. The **big score** `2-1` is centered
  at (64,13), height **20**, in **white**, using the **native Geist Pixel Square**
  numerals (`Matrix.Geist`), *not* 7-segment. The `-` glyph is part of that font.
- **Flags off (fallback):** 2× code hero — home code 2× at x=6, away code 2×
  right-aligned at 122, big score centered between (height 18). (Mirror
  `hero_codes`-style but with a centered score.)
- **Divider** faint hline at y=40.
- **Progress bar** at x=8, y=46, width 112: faint trough, **pitch-green** fill to
  `minute/90`, a brighter "ball" head dot at the fill edge, and a **dim 45′ tick**
  above the midpoint. (Same primitive as the flight `progress_bar`, green instead
  of cyan, no end-caps required.)
- **Bottom row, y=54.** Running game clock `mm:ss` left at x=8 in **white**
  (the `ss` ticks every second off `now`); `1ST HALF` / `2ND HALF` right-aligned
  at x=120 in **soft**.

---

## Goal celebration  (`:goal`, ~16.5s, plays over the Live board)

Pure function of elapsed time `t = now − goal_started_at` (ms). Reference:
`wc-renderers.js` → `goalCelebration(p, t, st, m)`. `st` carries the scoring
side: `%{team: :home|:away, code: "MEX", home: "USA", away: "MEX", hs, as}`. The
accent color is the scoring team's flag color (`Teams.color(code)`).

**Phase A — strobe burst (0 → 1.6s).** Full-panel wash in the team color,
toggling alpha **0.42 / 0.10** every ~0.13s. Sparkle field on top.
`GOAL!` in 2× font centered at y=18 and the **code** at y=34, the two swapping
white/team-color each strobe half-cycle.

**Phase B — the marquee (1.6 → 13s).**
- **Background:** diagonal **chevrons** in the team color (a 2px-wide stripe
  every 14px on `(x+y+scroll)`, alpha 0.16), scrolling.
- **Ticker frame:** animated dashed rules at y=17 and y=37 (team color).
- **Marquee:** the string `"G" + "O"×26 + "L!   " + FULL_COUNTRY_NAME + " SCORES!   "`
  (e.g. `GOOOOOOOOOOOOOOOOOOOOOOOOOOL!   MEXICO SCORES!`) in **2× font**, white,
  baseline y=22, scrolling **left at 52 px/s**, seamlessly looping. *(This is the
  part that should become a Trailer scroll strip — see the mapping section.)*
- **Flag ribbon:** a continuous row of the scoring team's flag (12×8 tiles, 4px
  gap) scrolling left along the bottom at y=52.
- **Sparkles** over everything.

**Phase C — score reveal (13 → 16.5s).** Chevrons + sparkles continue. Flashing
`<CODE> GOAL!` banner in 2× at y=1 (team-color/white toggle, ~0.28s). The 26×17
flags return at (6,20) and (122−26,20); the **new** big score centered at (64,22)
height 20 (Geist, white); `WHAT A GOAL` in **gold** at y=50.

At t ≥ 16500ms the state clears and the board returns to `:live`.

**Trigger.** In the sim, the celebration auto-fires when the score **increases**
(edge-detected each frame) for the side that scored, and the reveal shows the new
score. In production this maps to: the match snapshot's score ticks up → enter
`:goal` state, record `goal_started_at`, set the team, drop poll cadence to the
burst rate for 16.5s, then return to `:live`. (A manual "replay" is only a
sim/debug affordance.)

---

## Flags

`wc-flags.js` renders each national flag as a **resolution-independent sampler**:
`f(fx, fy, w, h) -> {r,g,b} | nil`, so the *same* flag draws cleanly at 10px or
26px. This matches the codebase's "render, don't store bitmaps" philosophy — port
it to a new **`TravisTracker.Matrix.Flags`** module: `draw(fb, x, y, w, h, code)`
loops the cells and `Framebuffer.set`s each sampled color.

22 teams are defined (USA, MEX, CAN, BRA, ARG, FRA, ENG, ESP, GER, POR, NED, BEL,
CRO, ITA, URU, COL, JPN, KOR, SEN, MAR, AUS, SUI). Most are stripe/cross/disc
constructions; a few carry a simplified central device (Brazil's diamond+globe,
Japan's disc, Senegal/Morocco stars). **Generic national colors and shapes only —
no federation crests/emblems.** Notes worth preserving:

- **Black flag fields render as dim grey** (`#262b38`), not true black — on a real
  panel a black stripe is just unlit LEDs and would vanish (Germany, Belgium).
  Decide whether production keeps this or shows true-off.
- Flags respect the `flagIcons` toggle (on by default). When off, the boards fall
  back to codes only.

---

## Teams & data model

Port `wc-data.js`'s `TEAMS` map to **`TravisTracker.Matrix.Teams`** (or extend
`Palette`): `code -> %{name: "MEXICO", color: {r,g,b}}`. Full **names** are used
in the goal marquee; **3-letter codes** everywhere else; the **color** is the
flag accent used to tint codes (when `flagTint` is on) and to theme the goal
animation. Team accent colors (hex, LED-tuned, single-chroma):

```
USA #5b8cff  MEX #34c878  CAN #ff5c5c  BRA #ffd23f  ARG #6cc4f5  FRA #5b8cff
ENG #d7e2fb  ESP #ff5c5c  GER #ffce5c  POR #ff6f6f  NED #ff9d3c  BEL #ffce5c
CRO #ff5c5c  ITA #4f8cff  URU #6cc4f5  COL #ffd23f  JPN #5b8cff  KOR #ff5c5c
SEN #34c878  MAR #ff5c5c  AUS #ffd23f  SUI #ff5c5c
```

Time formatting (`wc-data.js` → `Fmt`) maps onto the existing
`TravisTracker.Matrix.Fmt` (clock, weekday, month/day, duration). Kickoff labels:
bare `HH:MM` for today, weekday-prefixed otherwise.

---

## Design tokens

**Board palette** (extend `matrix/palette.ex` — several of these are new vs the
flight `@p` map):

| Token | Hex | Use |
|---|---|---|
| white | `#e4ecff` | primary text, scores |
| soft | `#9fb2d8` | secondary text |
| dim | `#5e6e92` | tertiary / `V` / weekday |
| faint | `#2f3a59` | dividers, bar trough |
| live (red) | `#ff5454` | LIVE label, pulse dot |
| gold | `#ffcf5c` | minute, kickoff time, "WHAT A GOAL" |
| pitch (green) | `#46d07f` | progress bar fill |
| ice | `#8ab0ff` | away accent |
| win | `#5ce098` | (result accent) |
| ball | `#eaf2ff` | progress ball head |

**Typography:** 5×7 bitmap (`Font.text`, 6px advance) for body; 2× bitmap
(`Font.text_2x`, 12px advance, ~14px tall) for hero codes, the `GOAL!`/marquee
text; **Geist Pixel Square native** (`Matrix.Geist`) for the big score numerals.

**Motion timings:** strobe toggle 0.13s; chevron/dash/ribbon scroll continuous;
marquee 52 px/s; reveal banner flash 0.28s; phase bounds 1.6s / 13s / 16.5s;
blink cycle 600ms; progress/clock off `snap.now`.

---

## Codebase touch-list

| File | Change |
|---|---|
| `lib/travis_tracker/matrix/renderers.ex` | Add `now_next/2`, `live/2`, `goal/2` + `dispatch/3` clauses (or a sibling `wc_renderers.ex`). |
| `lib/travis_tracker/matrix/palette.ex` | Add `gold`, `pitch`, `live`(red), `ball` (and reconcile `white`/`green` if you keep the WC hexes). |
| `lib/travis_tracker/matrix/flags.ex` | **New.** Port `wc-flags.js` samplers → `draw/6`. |
| `lib/travis_tracker/matrix/teams.ex` | **New.** `code -> %{name, color}` (port `TEAMS`). |
| `lib/travis_tracker/matrix/trailer.ex` + `regions.ex` | Extend scroll strip to 2× font for the marquee (optional but recommended). |
| `lib/travis_tracker/{display,worldcup}/state.ex` | **New/replaced** snapshot builder from a football feed; emit `:now_next` / `:live` / `:goal`; record `goal_started_at`. |
| `lib/travis_tracker_web/display_fixtures.ex` | Add `:now_next`, `:live`, `:goal` fixtures (port the `wc-data.js` fixtures) so the preview routes work. |
| `lib/travis_tracker_web/controllers/matrix_binary.ex` (poll logic) | Drop `X-Poll-Seconds` to the burst rate while `:goal` is active; restore after. |

## Assets

No external image assets — flags and type are drawn programmatically. The Geist
Pixel Square numerals already exist in the repo (`matrix/geist.ex`; the sim's
`matrix/geist-native.js` is the same data). No federation logos or licensed
marks are used or required.

## Open product questions (worth confirming before build)

- **Data feed**: which football data provider for live scores + 2026 fixtures?
- **Selection logic**: which match does `:live` follow, and how are the
  `:now_next` "live"/"next" lists chosen (a followed team? all in-play?)?
- **Goal source of truth**: is a score increment from the feed enough to fire
  `:goal`, and how are corrections/VAR reversals handled (don't celebrate a
  disallowed goal)?
- **Black-stripe flags**: dim-grey (as designed) or true-off on hardware?
- **Goal motion**: ship the v1 burst-poll approach, or invest in trailer v1.2
  for on-device animation?
```
