#!/usr/bin/env python3
"""Probe the World Cup 2026 data sources (ESPN + FIFA) and print normalized output.

Stdlib-only. This is a verification/exploration tool, not the production data
layer — it exists to pin down the response shapes and live-match behavior the
eventual server (Elixir) client will rely on.

Usage:
  tools/wc_data_probe.py schedule [YYYYMMDD]   # full tournament or one day, both sources
  tools/wc_data_probe.py live                  # current live matches, both sources
  tools/wc_data_probe.py match ESPN_EVENT_ID   # ESPN summary: score, clock, key events
  tools/wc_data_probe.py standings             # ESPN group standings
  tools/wc_data_probe.py raw URL               # fetch any URL, pretty-print JSON
"""

import json
import sys
import urllib.request

ESPN_BASE = "https://site.api.espn.com/apis/site/v2/sports/soccer/fifa.world"
ESPN_STANDINGS = "https://site.api.espn.com/apis/v2/sports/soccer/fifa.world/standings"
FIFA_CALENDAR = (
    "https://api.fifa.com/api/v3/calendar/matches"
    "?idCompetition=17&idSeason=285023&language=en&count=500"
)
FIFA_LIVE = "https://api.fifa.com/api/v3/live/football/now?language=en"
FIFA_WC_COMPETITION = "17"

UA = "Mozilla/5.0 (X11; Linux x86_64) wc-tracker-probe/0.1"


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


# ---- ESPN ----

def espn_event_line(e):
    comp = e["competitions"][0]
    st = e["status"]
    sides = []
    for c in comp["competitors"]:
        sides.append(f"{c['team']['displayName']} {c.get('score', '?')}")
    home_away = " - ".join(sides)
    return (
        f"{e['date']}  [{st['type']['state']:>4}] {st['type'].get('detail', ''):<28} "
        f"clock={st.get('displayClock', '?'):>7}  {home_away}  (id={e['id']})"
    )


def espn_schedule(day=None):
    dates = day or "20260611-20260719"
    data = fetch(f"{ESPN_BASE}/scoreboard?dates={dates}&limit=200")
    events = data.get("events", [])
    print(f"== ESPN: {len(events)} events for dates={dates}")
    for e in events:
        print(" ", espn_event_line(e))


def espn_live():
    data = fetch(f"{ESPN_BASE}/scoreboard")
    live = [e for e in data.get("events", []) if e["status"]["type"]["state"] == "in"]
    print(f"== ESPN: {len(live)} live (of {len(data.get('events', []))} today)")
    for e in data.get("events", []):
        print(" ", espn_event_line(e))


def espn_match(event_id):
    data = fetch(f"{ESPN_BASE}/summary?event={event_id}")
    header = data["header"]
    comp = header["competitions"][0]
    st = comp["status"]
    print(f"== ESPN summary for event {event_id}")
    for c in comp["competitors"]:
        print(f"  {c['team']['displayName']}: {c.get('score', '?')}")
    print(f"  state={st['type']['state']} detail={st['type'].get('detail')}")
    print("  key events:")
    for kv in data.get("keyEvents") or []:
        clock = kv.get("clock", {}).get("displayValue", "")
        print(f"   {clock:>7} {kv.get('type', {}).get('text', ''):<16} {kv.get('text', '')}")


def espn_standings():
    data = fetch(ESPN_STANDINGS)
    for g in data.get("children", []):
        print(f"== {g.get('name')}")
        for entry in g.get("standings", {}).get("entries", []):
            stats = {s["name"]: s.get("displayValue") for s in entry.get("stats", [])}
            print(
                f"  {entry['team']['displayName']:<24} "
                f"P{stats.get('gamesPlayed', '0')} W{stats.get('wins', '0')} "
                f"D{stats.get('ties', '0')} L{stats.get('losses', '0')} "
                f"GD{stats.get('pointDifferential', '0'):>3} pts={stats.get('points', '0')}"
            )


# ---- FIFA ----

def fifa_name(team):
    if not team:
        return "TBD"
    names = team.get("TeamName") or [{}]
    return names[0].get("Description", "TBD")


def fifa_match_line(m):
    return (
        f"{m.get('Date')}  status={m.get('MatchStatus')} period={m.get('Period')} "
        f"time={m.get('MatchTime') or '-':>5}  "
        f"{fifa_name(m.get('Home'))} {m.get('HomeTeamScore')} - "
        f"{m.get('AwayTeamScore')} {fifa_name(m.get('Away'))}  "
        f"(group={m.get('GroupName') and m['GroupName'][0].get('Description')}, idMatch={m.get('IdMatch')})"
    )


def fifa_schedule():
    data = fetch(FIFA_CALENDAR)
    results = data.get("Results", [])
    print(f"== FIFA calendar: {len(results)} matches")
    for m in results:
        print(" ", fifa_match_line(m))


def fifa_live():
    data = fetch(FIFA_LIVE)
    wc = [m for m in data.get("Results", []) if m.get("IdCompetition") == FIFA_WC_COMPETITION]
    print(f"== FIFA live/now: {len(wc)} World Cup matches live "
          f"({len(data.get('Results', []))} live globally)")
    for m in wc:
        print(" ", fifa_match_line(m))


def main():
    args = sys.argv[1:]
    cmd = args[0] if args else "live"
    if cmd == "schedule":
        espn_schedule(args[1] if len(args) > 1 else None)
        print()
        fifa_schedule()
    elif cmd == "live":
        espn_live()
        print()
        fifa_live()
    elif cmd == "match":
        espn_match(args[1])
    elif cmd == "standings":
        espn_standings()
    elif cmd == "raw":
        print(json.dumps(fetch(args[1]), indent=2))
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
