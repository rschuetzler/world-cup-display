# World Cup 2026 data source research

**Date:** 2026-06-12 (day 2 of the tournament)
**Need:** game schedules, live scores, live match clock — feeding a server that
renders frames for a 128×64 matrix polled every 15–60 s.
**Verdict:** use **ESPN's unauthenticated site API** as the primary source,
with **FIFA's unofficial api.fifa.com** as cross-check/fallback. Both were
probed live today against real tournament data (see `tools/wc_data_probe.py`).

## Requirements recap

- Full 104-match schedule with kickoff times (UTC) and group/stage info.
- Live: score + match clock, fresh enough for a 15–60 s display poll.
- Nice-to-have: goal scorers (for the scroll ticker), group standings,
  knockout bracket progression.
- Server polls the upstream API; the device only ever talks to our server, so
  upstream rate limits are about **one server**, not per-device.

## Recommendation: ESPN primary, FIFA fallback

### ESPN site API (primary) — no key, no signup

Base: `https://site.api.espn.com/apis/site/v2/sports/soccer/fifa.world`
(league code `fifa.world`; unofficial but stable for years and widely used).

| Endpoint | Gives us | Verified today |
|---|---|---|
| `/scoreboard` | Today's matches: score, status state (`pre`/`in`/`post`), `displayClock`, status detail | ✅ |
| `/scoreboard?dates=20260611-20260719&limit=200` | **All 104 matches** in one ~770 KB call | ✅ |
| `/scoreboard?dates=YYYYMMDD` | One day (~10 KB) — the right shape for live polling | ✅ |
| `/summary?event={id}` | Key events with full text: *"Goal! Mexico 1, South Africa 0. Julián Quiñones … Assisted by Érik Lira."*, cards, subs, delays | ✅ |
| `…/apis/v2/sports/soccer/fifa.world/standings` | All 12 groups, P/W/D/L/GD/points | ✅ |

Why it wins:

- **Freshness:** the scoreboard is served with `cache-control: max-age=2` —
  effectively real-time. Yesterday's opener showed `clock: 90'+8'`, per-minute
  goal/card details, and correct FT state.
- **The clock is first-class:** `status.displayClock` (e.g. `67'`, `90'+8'`)
  plus `status.type.state` / `status.type.detail` (`FT`, `Halftime`, …). This
  is exactly the "live time" the display needs.
- **No auth, no documented rate limit.** One server polling a ~10 KB day
  scoreboard every 15–30 s during match windows is well within what this API
  routinely serves.
- Scorer names come from `/summary` (the scoreboard's `details` array has
  minutes/types but empty athlete lists) — one extra call per live match,
  only needed when the ticker slide is on.

Risks: it's unofficial, so no SLA and no contract on the shape. Mitigate with
the FIFA fallback and by treating parse failures as "keep last good frame".

### FIFA unofficial API (fallback / cross-check) — no key

- Calendar (all 104 matches, includes live minute + score once running):
  `https://api.fifa.com/api/v3/calendar/matches?idCompetition=17&idSeason=285023&language=en&count=500`
  — `idSeason=285023` is **FIFA World Cup 2026™** (confirmed via
  `/api/v3/seasons?idCompetition=17`).
- Live matches across all competitions:
  `https://api.fifa.com/api/v3/live/football/now?language=en`, filter
  `IdCompetition == "17"`.
- Rich fields: `MatchTime` (`"98'"`), `MatchStatus`, `Period`, penalties
  (`HomeTeamPenaltyScore`), `BallPossession`, `GroupName`, stadium.
- `MatchStatus` observed: `0` = finished, `1` = not started. Live is
  reportedly `3` (community docs from 2022) — **verify during a live window**.
- ⚠️ Sits behind **Akamai Bot Manager** (`_abck` / `bm_sz` cookies). Plain
  curl/urllib worked today, but this is the kind of edge that can start
  blocking non-browser clients mid-tournament. That's why it's the fallback,
  not the primary.

### Rejected

- **football-data.org** (free tier): includes WC 2026 and 10 req/min, but
  **live scores are delayed on the free tier** — disqualifying for a live
  scoreboard. Paid tier fixes it; unnecessary given the above.
- **API-Football** (api-sports.io): good data (league=1, season=2026) but the
  free tier is 100 req/day — that's one poll every ~15 min. Paid-only for our
  cadence.
- Sportmonks / TheStatsAPI / statorium etc.: paid, no advantage over ESPN for
  scores+clock.

## Polling strategy (proposed)

The device polls our server every 15–60 s; the server polls upstream
independently and renders from cached state:

- **Schedule:** ESPN full-range scoreboard (or FIFA calendar) **1×/hour**, and
  on boot. Kickoff times are UTC; render in America/Denver.
- **Live window** (any match `pre` within ~10 min of kickoff, or `in`):
  ESPN day-scoreboard every **15–30 s** → score, clock, state.
- **Scorer ticker:** ESPN `/summary?event=` every **60 s** per live match,
  only while a ticker slide is enabled.
- **Standings/bracket:** ESPN standings after any `post` transition, or
  1×/hour during match days.
- **Idle (no match within an hour):** drop to **5–10 min** schedule refresh
  and tell the device `X-Poll-Seconds: 60`.
- Keep last-good state on any upstream error; never render a blank frame
  because ESPN hiccuped.

Worst case (4 simultaneous matches, group stage finale): ~4 summary calls +
1 scoreboard call per minute ≈ 5 req/min upstream. Trivial.

## Status / clock mapping (for the renderer)

| Display state | ESPN signal | FIFA signal |
|---|---|---|
| Upcoming | `state: "pre"`, `date` (UTC kickoff) | `MatchStatus: 1` |
| Live | `state: "in"`, `displayClock` `"67'"` | `MatchStatus: 3?` (verify), `MatchTime` |
| Halftime | `state: "in"`, `detail: "Halftime"` (verify exact string) | `Period` (verify values) |
| Stoppage | `displayClock` `"90'+8'"` | `MatchTime` `"98'"` (absolute, no `+` form) |
| Final | `state: "post"`, `detail: "FT"` | `MatchStatus: 0` |
| Pens/ET (knockouts) | `detail` (`"FT-Pens"`? verify in R32) | `…PenaltyScore` fields |

Note the two sources disagree on stoppage-time formatting (ESPN `90'+8'`,
FIFA `98'`) — normalize in the data layer, not the renderer.

## Open items (need a live match window)

First chance: **Canada vs Bosnia-Herzegovina, kicks off 2026-06-12T19:00Z**
(1 pm America/Denver). Run `tools/wc_data_probe.py live` during the match to
confirm:

1. ESPN `displayClock` tick granularity and `state: "in"` shape (incl. the
   exact halftime `detail` string).
2. FIFA live `MatchStatus` value and `Period` values.
3. End-to-end latency: goal on TV → goal in API (eyeball it).
4. Whether FIFA's Akamai lets a plain HTTP client poll for 2+ hours.

Also still open (from README): knockout-round statuses (ET, penalties) can't
be observed until the Round of 32 starts June 28 — re-probe then.

## Tooling

`tools/wc_data_probe.py` (stdlib-only Python) hits both sources and prints
normalized lines:

```
tools/wc_data_probe.py schedule [YYYYMMDD]  # both sources
tools/wc_data_probe.py live                 # both sources, live filter
tools/wc_data_probe.py match 760416         # ESPN summary (key events/scorers)
tools/wc_data_probe.py standings            # ESPN group tables
tools/wc_data_probe.py raw URL              # raw JSON explorer
```

ESPN event IDs for today: Canada–Bosnia `760416`, USA–Paraguay `760417`.
