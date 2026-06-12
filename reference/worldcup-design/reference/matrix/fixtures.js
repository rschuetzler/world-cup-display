// fixtures.js — JS port of the Phoenix preview fixtures, computed against
// the live wall clock so countdowns / progress / clocks animate. Field
// names mirror /preview/<state>/data so the layouts read like production.
// ─────────────────────────────────────────────────────────────────────

(function (global) {
  'use strict';

  const MIN = 60 * 1000, HR = 60 * MIN;

  function flight(a) {
    return {
      airline_iata: 'DL', airline_icao: 'DAL', flight_number: a.number,
      origin_iata: a.origin_iata, origin_city: a.origin_city,
      destination_iata: a.destination_iata, destination_city: a.destination_city,
      scheduled_depart_utc: a.scheduled_depart_utc,
      scheduled_arrive_utc: a.scheduled_arrive_utc,
      estimated_depart_utc: a.estimated_depart_utc,
      actual_depart_utc: a.actual_depart_utc,
      actual_takeoff_utc: a.actual_takeoff_utc,
      actual_touchdown_utc: a.actual_touchdown_utc,
      actual_arrive_utc: a.actual_arrive_utc,
      origin_tz: a.origin_tz, destination_tz: a.destination_tz,
      aircraft_type: a.aircraft_type || '739',
      status: a.status, gate: a.gate,
      delay_minutes: a.delay_minutes, delay_reason: a.delay_reason,
      label: a.label
    };
  }

  function idle(now) {
    return {
      state: 'idle', now, timezone: 'America/Denver',
      weather_iata: 'SLC', weather_city: 'Salt Lake City',
      weather_temperature_f: 68, weather_condition: 'Partly cloudy',
      weather_icon: '02d', weather_high_f: 74, weather_low_f: 52
    };
  }

  function preFlight(now) {
    const depart = now + 45 * MIN;
    const arrive = depart + 3 * HR + 25 * MIN;
    return {
      state: 'pre_flight', now, timezone: 'America/Denver',
      flight: flight({
        number: 907, origin_iata: 'SLC', origin_city: 'Salt Lake City',
        destination_iata: 'ATL', destination_city: 'Atlanta',
        scheduled_depart_utc: depart, scheduled_arrive_utc: arrive,
        estimated_depart_utc: depart + 8 * MIN,
        origin_tz: 'America/Denver', destination_tz: 'America/New_York',
        status: 'scheduled', gate: 'C12',
        delay_minutes: 8, delay_reason: 'Late aircraft'
      })
    };
  }

  function inFlight(now) {
    const departed = now - (1 * HR + 18 * MIN);
    const arrive = now + (2 * HR + 7 * MIN);
    return {
      state: 'in_flight', now, timezone: 'America/Denver',
      flight: flight({
        number: 907, origin_iata: 'SLC', origin_city: 'Salt Lake City',
        destination_iata: 'ATL', destination_city: 'Atlanta',
        scheduled_depart_utc: departed + 5 * MIN, scheduled_arrive_utc: arrive,
        actual_depart_utc: departed, estimated_arrive_utc: arrive,
        origin_tz: 'America/Denver', destination_tz: 'America/New_York',
        status: 'in_air'
      }),
      position: {
        observed_at_utc: now, latitude: 41.14, longitude: -104.82,
        altitude_ft: 37000, ground_speed_kt: 472, heading_deg: 102,
        over: 'near Cheyenne, WY'
      }
    };
  }

  // Trip pending — a flight is on the schedule but still hours out (no gate
  // yet). Big countdown to the next departure.
  function tripPending(now) {
    const depart = now + 4 * HR;
    const arrive = depart + 3 * HR + 25 * MIN;
    return {
      state: 'trip_pending', now, timezone: 'America/Denver',
      countdown_seconds: 4 * 3600,
      next_flight: flight({
        number: 907, origin_iata: 'SLC', origin_city: 'Salt Lake City',
        destination_iata: 'ATL', destination_city: 'Atlanta',
        scheduled_depart_utc: depart, scheduled_arrive_utc: arrive,
        origin_tz: 'America/Denver', destination_tz: 'America/New_York',
        status: 'scheduled'
      })
    };
  }

  // Layover — landed one leg, waiting on the next. On the ground at the
  // connecting city; counts down to the next departure.
  function layover(now) {
    const arrived = now - 2 * HR;
    const nextDepart = now + 5 * HR;
    const nextArrive = nextDepart + 2 * HR + 10 * MIN;
    return {
      state: 'layover', now, timezone: 'America/New_York',
      city: 'Atlanta', is_home: false,
      weather_iata: 'ATL', weather_temperature_f: 74,
      weather_condition: 'Clear', weather_icon: '01d',
      previous_flight: flight({
        number: 907, origin_iata: 'SLC', origin_city: 'Salt Lake City',
        destination_iata: 'ATL', destination_city: 'Atlanta',
        scheduled_depart_utc: arrived - 3 * HR - 25 * MIN, scheduled_arrive_utc: arrived,
        actual_depart_utc: arrived - 3 * HR - 30 * MIN, actual_arrive_utc: arrived,
        origin_tz: 'America/Denver', destination_tz: 'America/New_York',
        status: 'landed'
      }),
      next_flight: flight({
        number: 1438, origin_iata: 'ATL', origin_city: 'Atlanta',
        destination_iata: 'MCO', destination_city: 'Orlando',
        scheduled_depart_utc: nextDepart, scheduled_arrive_utc: nextArrive,
        origin_tz: 'America/New_York', destination_tz: 'America/New_York',
        status: 'scheduled'
      })
    };
  }

  // Taxiing — pushed back 12 min ago, still on the ground at the origin.
  // (The renderer also handles the arrival side when actual_touchdown_utc set.)
  function taxiing(now) {
    const out = now - 12 * MIN;
    const arrive = now + 3 * HR + 13 * MIN;
    return {
      state: 'taxiing', now, timezone: 'America/Denver',
      flight: flight({
        number: 907, origin_iata: 'SLC', origin_city: 'Salt Lake City',
        destination_iata: 'ATL', destination_city: 'Atlanta',
        scheduled_depart_utc: out + 5 * MIN, scheduled_arrive_utc: arrive,
        estimated_depart_utc: out + 5 * MIN, actual_depart_utc: out, gate: 'C12',
        origin_tz: 'America/Denver', destination_tz: 'America/New_York',
        status: 'departed'
      })
    };
  }

  // Post-flight — touched down 6 min ago. The welcome-home bookend.
  function postFlight(now) {
    const touchdown = now - 6 * MIN;
    const departed = touchdown - 3 * HR - 10 * MIN;
    const schedArr = touchdown - 1 * MIN;     // landed ~on time
    return {
      state: 'post_flight', now, timezone: 'America/New_York', recent_landing: null,
      flight: flight({
        number: 907, origin_iata: 'SLC', origin_city: 'Salt Lake City',
        destination_iata: 'ATL', destination_city: 'Atlanta',
        scheduled_depart_utc: departed + 5 * MIN, scheduled_arrive_utc: schedArr,
        actual_depart_utc: departed, actual_takeoff_utc: departed + 12 * MIN,
        actual_touchdown_utc: touchdown, actual_arrive_utc: null,
        origin_tz: 'America/Denver', destination_tz: 'America/New_York',
        status: 'landed', label: 'Travis'
      })
    };
  }

  // Pill overlays — a base panel decorated with a "just landed" pill for a
  // same-trip leg that touched down moments ago.
  function pillOnPreFlight(now) {
    const base = preFlight(now);
    // The just-landed leg arrives INTO the next flight's origin (SLC), so the
    // inbound is ATL→SLC — not the same SLC→ATL leg that's about to board.
    base.recent_landing = {
      airline_iata: 'DL', flight_number: 907,
      origin_iata: 'ATL', destination_iata: 'SLC', landed_at_utc: now - 6 * MIN
    };
    return base;
  }
  function pillOnLayover(now) {
    const base = layover(now);
    base.recent_landing = {
      airline_iata: 'DL', flight_number: 907,
      origin_iata: 'SLC', destination_iata: 'ATL', landed_at_utc: now - 10 * MIN
    };
    return base;
  }

  // estimated_arrive_utc lives on the flight in prod serialisation; mirror it.
  function patchArrive(snap) {
    snap.flight.estimated_arrive_utc = snap.flight.scheduled_arrive_utc;
    return snap;
  }

  // Alternating — the carousel meta-state: cycles between several watched
  // flights every dwell_ms, each rendered with its own state's panel + a
  // progress pill. Here: Travis airborne, Brian still at the gate.
  function alternating(now) {
    const a = patchArrive(inFlight(now)); a.flight.label = 'Travis';
    const b = preFlight(now); b.flight.label = 'Brian';
    return {
      state: 'alternating', now, timezone: 'America/Denver',
      dwell_ms: 15000,
      members: [a, b]
    };
  }

  const FIX = {
    idle,
    trip_pending: tripPending,
    layover,
    pre_flight: preFlight,
    taxiing,
    in_flight: (n) => patchArrive(inFlight(n)),
    post_flight: postFlight,
    alternating,
    post_flight_pill_on_pre_flight: pillOnPreFlight,
    post_flight_pill_on_layover: pillOnLayover
  };

  // ── shared formatters ─────────────────────────────────────────────────
  function fmtClock(ms, tz, h12) {
    try {
      return new Intl.DateTimeFormat('en-US', {
        hour: '2-digit', minute: '2-digit', hour12: !!h12, timeZone: tz
      }).format(new Date(ms)).replace(/\s?[AP]M/i, '');
    } catch { return '--:--'; }
  }
  function fmtMeridiem(ms, tz) {
    try {
      const s = new Intl.DateTimeFormat('en-US', { hour: '2-digit', hour12: true, timeZone: tz }).format(new Date(ms));
      const m = s.match(/([AP]M)/i); return m ? m[1].toUpperCase() : '';
    } catch { return ''; }
  }
  function fmtWeekday(ms, tz) {
    try {
      return new Intl.DateTimeFormat('en-US', { weekday: 'short', timeZone: tz }).format(new Date(ms)).toUpperCase();
    } catch { return ''; }
  }
  function fmtMonthDay(ms, tz) {
    try {
      const parts = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', timeZone: tz }).formatToParts(new Date(ms));
      const mo = parts.find(p => p.type === 'month').value.toUpperCase();
      const da = parts.find(p => p.type === 'day').value;
      return mo + ' ' + da;
    } catch { return ''; }
  }
  function fmtNumDate(ms, tz) {
    try {
      const parts = new Intl.DateTimeFormat('en-US', { month: 'numeric', day: 'numeric', timeZone: tz }).formatToParts(new Date(ms));
      const mo = parts.find(p => p.type === 'month').value;
      const da = parts.find(p => p.type === 'day').value;
      return mo + '/' + da;
    } catch { return ''; }
  }
  // "2:07" h:mm, or "47" with no hours.
  function fmtHM(secs) {
    secs = Math.max(0, Math.floor(secs));
    const h = Math.floor(secs / 3600), m = Math.floor((secs % 3600) / 60);
    if (h > 0) return h + ':' + String(m).padStart(2, '0');
    return String(m);
  }
  // "4H 12M" / "47M" / "30S"
  function fmtDur(secs) {
    secs = Math.max(0, Math.floor(secs));
    const h = Math.floor(secs / 3600), m = Math.floor((secs % 3600) / 60);
    if (h > 0) return h + 'H ' + m + 'M';
    if (m > 0) return m + 'M';
    return secs + 'S';
  }

  global.Fixtures = FIX;
  global.Fmt = {
    fmtClock, fmtMeridiem, fmtWeekday, fmtMonthDay, fmtNumDate, fmtHM, fmtDur
  };
})(window);
