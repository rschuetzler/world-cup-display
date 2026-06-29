#!/usr/bin/env python3
"""Poll the ESPN scoreboard and log full event data for any in-progress game.

Captures everything (status + competitors, where any shootout/penalty fields
live) so we can decide how to render a shootout. Runs until every game that was
live during this run has gone final (plus a few trailing snapshots), or a hard
time cap, whichever comes first.
"""
import json
import time
import urllib.request

URL = "https://site.api.espn.com/apis/site/v2/sports/soccer/fifa.world/scoreboard"
OUT = "/home/ryan/code/world-cup-display/tools/shootout-capture.jsonl"
INTERVAL = 10           # seconds between polls
MAX_SECONDS = 45 * 60   # hard stop
TRAILING_POSTS = 6      # post-game snapshots to keep after a tracked game ends


def fetch():
    req = urllib.request.Request(URL, headers={"User-Agent": "wc-display-capture"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def main():
    tracked = set()       # event ids seen live this run
    done = {}             # event id -> trailing post snapshots logged
    start = time.time()
    polls = 0
    with open(OUT, "a") as f:
        while time.time() - start < MAX_SECONDS:
            polls += 1
            try:
                data = fetch()
            except Exception as e:  # noqa: BLE001
                f.write(json.dumps({"ts": time.time(), "error": str(e)}) + "\n")
                f.flush()
                time.sleep(INTERVAL)
                continue

            kept = []
            for e in data.get("events", []):
                st = e.get("status", {})
                state = st.get("type", {}).get("state")
                eid = e.get("id")
                if state == "in":
                    tracked.add(eid)
                    done.pop(eid, None)
                    kept.append(e)
                elif state == "post" and eid in tracked:
                    n = done.get(eid, 0)
                    if n < TRAILING_POSTS:
                        done[eid] = n + 1
                        kept.append(e)

            if kept:
                f.write(json.dumps({"ts": time.time(), "events": kept}) + "\n")
                f.flush()

            # Stop once every tracked game has finished and drained its trailing
            # snapshots.
            if tracked and all(done.get(eid, 0) >= TRAILING_POSTS for eid in tracked):
                f.write(json.dumps({"ts": time.time(), "note": "all tracked games final", "polls": polls}) + "\n")
                f.flush()
                break

            time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
