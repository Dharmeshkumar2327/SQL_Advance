-- =============================================================================
-- 03_engine.sql
-- The reservation engine, in PL/pgSQL:
--   app_now()            injectable clock (lets the simulator & tests time-travel)
--   compute_fare()       base + reservation + superfast + Tatkal + catering + GST
--   find_free_seat()     segment-aware seat search with preference & packing heuristics
--   book_ticket()        atomic all-or-nothing booking: CNF -> RAC -> WL -> REGRET
--   cancel_ticket()      refund rules + automatic waitlist promotion
--   promote_waitlist()   RAC -> CNF, then WL -> CNF / RAC in queue order
--   prepare_chart()      final promotion, releases unused quota, auto-cancels full-WL PNRs
--   cancel_journey()     train cancelled: full refund to everyone
--   get_availability()   IRCTC-style "AVAILABLE-0042" / "RAC 7" / "GNWL 31/WL 12" / "REGRET"
--   search_trains()      trains between two stations on a date, with live availability
--
-- Custom SQLSTATEs (so callers can branch on the failure type):
--   RL001 REGRET         no seat, no RAC, waitlist full / not allowed
--   RL002 NOT_CONFIRMED  confirm-only booking could not be fully confirmed
--   RL003 WINDOW_CLOSED  outside ARP / Tatkal window, or chart prepared
--   RL004 INVALID        bad input (stations, quota eligibility, passengers ...)
-- =============================================================================
\set ON_ERROR_STOP on
SET search_path = rail, public;

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app_now() RETURNS timestamptz
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(current_setting('rail.now', true), '')::timestamptz, now())
$$;
COMMENT ON FUNCTION app_now() IS 'Business clock. SET rail.now = ''2026-11-25 10:00+05:30'' to time-travel.';

CREATE OR REPLACE FUNCTION rule_num(p_key text) RETURNS numeric
LANGUAGE sql STABLE AS $$ SELECT rule_value::numeric FROM rail.rules WHERE rule_key = p_key $$;

CREATE OR REPLACE FUNCTION rule_time(p_key text) RETURNS time
LANGUAGE sql STABLE AS $$ SELECT rule_value::time FROM rail.rules WHERE rule_key = p_key $$;

-- Scheduled departure instant of a stop (arrival instant for the last stop), IST.
CREATE OR REPLACE FUNCTION stop_time(p_journey_id bigint, p_stop_seq integer) RETURNS timestamptz
LANGUAGE sql STABLE AS $$
  SELECT ((j.journey_date + ts.day_offset) + COALESCE(ts.departure_time, ts.arrival_time))
           AT TIME ZONE 'Asia/Kolkata'
  FROM rail.journeys j
  JOIN rail.train_stops ts ON ts.train_no = j.train_no AND ts.stop_seq = p_stop_seq
  WHERE j.journey_id = p_journey_id
$$;

CREATE OR REPLACE FUNCTION chart_time(p_journey_id bigint) RETURNS timestamptz
LANGUAGE sql STABLE AS $$
  SELECT rail.stop_time(p_journey_id, 1) - make_interval(hours => rail.rule_num('chart_hours_before')::int)
$$;

-- 10-digit PNR. First digit hints the originating zone group; the other 9 come from
-- a sequence pushed through a multiplicative permutation mod 1e9 (7919 is coprime
-- with 10^9, so the mapping is a bijection => unique, yet not guessable/sequential).
CREATE OR REPLACE FUNCTION generate_pnr(p_zone text) RETURNS char(10)
LANGUAGE sql VOLATILE AS $$
  SELECT (CASE WHEN p_zone IN ('NR','NCR')                    THEN '2'
               WHEN p_zone IN ('WR','WCR','CR')                THEN '8'
               WHEN p_zone IN ('ER','ECR','SER','ECoR','SECR') THEN '6'
               ELSE '4' END)
      || lpad(((nextval('rail.pnr_seq') * 7919) % 1000000000)::text, 9, '0')
$$;

CREATE OR REPLACE FUNCTION seat_label(p_seat_id integer) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT c.coach_no || '/' || s.berth_no || '/' || s.berth_type
  FROM rail.seats s JOIN rail.coaches c USING (coach_id)
  WHERE s.seat_id = p_seat_id
$$;

-- Lower berth is auto-preferred for senior citizens and women 45+ (as on IRCTC).
CREATE OR REPLACE FUNCTION wants_lower(p_age integer, p_gender char) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT (p_gender = 'M' AND p_age >= 60) OR (p_gender <> 'M' AND p_age >= 45) $$;

-- -----------------------------------------------------------------------------
-- Fare
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION compute_fare(p_train_no char(5), p_class varchar, p_quota varchar, p_distance_km integer)
RETURNS numeric
LANGUAGE sql STABLE AS $$
  WITH f AS (
    SELECT tc.*, tt.is_superfast, tt.catering_included,
           ROUND(GREATEST(p_distance_km, 50) * tc.fare_per_km * tt.fare_multiplier, 2) AS base_fare
    FROM rail.travel_classes tc
    CROSS JOIN rail.trains t
    JOIN rail.train_types tt USING (train_type)
    WHERE tc.class_code = p_class AND t.train_no = p_train_no
  )
  SELECT CEIL((
             base_fare
           + reservation_charge
           + CASE WHEN is_superfast THEN superfast_charge ELSE 0 END
           + CASE WHEN p_quota = 'TQ'
                  THEN LEAST(GREATEST(base_fare * tatkal_pct / 100, tatkal_min), tatkal_max) ELSE 0 END
           + CASE WHEN catering_included THEN catering_charge ELSE 0 END
         ) * CASE WHEN is_ac THEN 1 + rail.rule_num('gst_ac_pct') / 100 ELSE 1 END
         / 5) * 5                                          -- IR rounds up to next Rs 5
  FROM f
$$;

-- -----------------------------------------------------------------------------
-- Seat search
--   p_quota NULL => any quota (used at chart time when unused quota is released)
-- Ordering, best first:
--   1. same coach as co-passenger already placed (keep families together)
--   2. passenger's berth preference
--   3. lower berth for seniors / women 45+
--   4. "packing": seats already used on an adjacent segment, so fully free seats
--      stay free for long-distance passengers (reduces seat fragmentation)
--   5. coach order, berth number
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION find_free_seat(
    p_journey_id bigint, p_class varchar, p_quota varchar, p_range int4range,
    p_pref berth_type DEFAULT NULL, p_want_lower boolean DEFAULT false, p_near_coach integer DEFAULT NULL)
RETURNS integer
LANGUAGE sql STABLE AS $$
  -- Read the journey's live allocations once (index on journey_id), then hash anti-join
  -- against the seat map: ~20x faster than probing the GiST index once per seat.
  WITH busy AS (
    SELECT DISTINCT a.seat_id FROM rail.seat_allocations a
    WHERE a.journey_id = p_journey_id AND a.is_active AND a.seg_range && p_range
  ),
  adjacent AS (
    SELECT DISTINCT a.seat_id FROM rail.seat_allocations a
    WHERE a.journey_id = p_journey_id AND a.is_active AND a.seg_range -|- p_range
  )
  SELECT s.seat_id
  FROM rail.journeys j
  JOIN rail.coaches c ON c.train_no = j.train_no AND c.class_code = p_class
  JOIN rail.seats   s ON s.coach_id = c.coach_id
  LEFT JOIN busy     bz ON bz.seat_id = s.seat_id
  LEFT JOIN adjacent ad ON ad.seat_id = s.seat_id
  WHERE j.journey_id = p_journey_id
    AND bz.seat_id IS NULL
    AND NOT s.is_rac_berth
    AND (p_quota IS NULL OR s.quota_code = p_quota)
  ORDER BY (c.coach_id = p_near_coach) IS TRUE DESC,
           (s.berth_type = p_pref) IS TRUE DESC,
           (p_want_lower AND s.berth_type IN ('LB','SL')) DESC,
           (ad.seat_id IS NOT NULL) DESC,
           c.position, s.berth_no
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION find_free_rac_slot(
    p_journey_id bigint, p_class varchar, p_range int4range,
    OUT seat_id integer, OUT slot smallint)
LANGUAGE sql STABLE AS $$
  WITH busy AS (
    SELECT a.seat_id, a.slot FROM rail.seat_allocations a
    WHERE a.journey_id = p_journey_id AND a.is_active AND a.kind = 'RAC' AND a.seg_range && p_range
  )
  SELECT s.seat_id, sl.slot
  FROM rail.journeys j
  JOIN rail.coaches c ON c.train_no = j.train_no AND c.class_code = p_class
  JOIN rail.seats   s ON s.coach_id = c.coach_id AND s.is_rac_berth
  CROSS JOIN (VALUES (1::smallint), (2::smallint)) AS sl(slot)
  WHERE j.journey_id = p_journey_id
    AND NOT EXISTS (SELECT 1 FROM busy b WHERE b.seat_id = s.seat_id AND b.slot = sl.slot)
  ORDER BY c.position, s.berth_no, sl.slot
  LIMIT 1
$$;

-- -----------------------------------------------------------------------------
-- BOOK
-- p_passengers: [{"name":"Asha Rao","age":34,"gender":"F","berth_pref":"LB"}, ...]
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION book_ticket(
    p_user_id       integer,
    p_train_no      char(5),
    p_boarding_date date,
    p_from          varchar,
    p_to            varchar,
    p_class         varchar,
    p_quota         varchar,
    p_passengers    jsonb,
    p_confirm_only  boolean DEFAULT false,
    p_channel       text    DEFAULT 'WEB')
RETURNS TABLE (pnr char(10), passenger_no smallint, passenger_name text,
               status passenger_status, status_label text, fare numeric)
LANGUAGE plpgsql AS $$
DECLARE
  v_now      timestamptz := rail.app_now();
  v_class    rail.travel_classes;
  v_quota    rail.quotas;
  v_from     rail.train_stops;
  v_to       rail.train_stops;
  v_journey  rail.journeys;
  v_inv      rail.journey_inventory;
  v_open     timestamptz;
  v_range    int4range;
  v_npax     integer;
  v_fare     numeric;
  v_pnr      char(10);
  v_zone     text;
  v_p        jsonb;
  v_i        integer := 0;
  v_seat     integer;
  v_slot     smallint;
  v_near     integer;
  v_age      integer;
  v_gender   char(1);
  v_name     text;
  v_pref     rail.berth_type;
  v_status   rail.passenger_status;
  v_label    text;
  v_wl_no    integer;
  v_rac_no   integer;
  v_pid      bigint;
  v_active_wl integer;
BEGIN
  -- ---------- validate request ----------
  SELECT * INTO v_class FROM rail.travel_classes WHERE class_code = p_class;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVALID: unknown class %', p_class USING ERRCODE = 'RL004'; END IF;
  SELECT * INTO v_quota FROM rail.quotas WHERE quota_code = p_quota;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVALID: unknown quota %', p_quota USING ERRCODE = 'RL004'; END IF;

  IF jsonb_typeof(p_passengers) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'INVALID: passengers must be a JSON array' USING ERRCODE = 'RL004';
  END IF;
  v_npax := jsonb_array_length(p_passengers);
  IF v_npax < 1 OR v_npax > v_quota.max_pax THEN
    RAISE EXCEPTION 'INVALID: % quota allows 1-% passengers, got %', p_quota, v_quota.max_pax, v_npax USING ERRCODE = 'RL004';
  END IF;

  SELECT * INTO v_from FROM rail.train_stops ts WHERE ts.train_no = p_train_no AND ts.station_code = p_from;
  SELECT * INTO v_to   FROM rail.train_stops ts WHERE ts.train_no = p_train_no AND ts.station_code = p_to;
  IF v_from.stop_seq IS NULL OR v_to.stop_seq IS NULL OR v_from.stop_seq >= v_to.stop_seq THEN
    RAISE EXCEPTION 'INVALID: train % does not run % -> %', p_train_no, p_from, p_to USING ERRCODE = 'RL004';
  END IF;

  -- boarding date is the date at the boarding station; convert to origin date
  SELECT * INTO v_journey FROM rail.journeys j
  WHERE j.train_no = p_train_no AND j.journey_date = p_boarding_date - v_from.day_offset;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVALID: train % does not leave % on %', p_train_no, p_from, p_boarding_date USING ERRCODE = 'RL004';
  END IF;
  IF v_journey.status <> 'SCHEDULED' THEN
    RAISE EXCEPTION 'WINDOW_CLOSED: journey is %', v_journey.status USING ERRCODE = 'RL003';
  END IF;

  -- ---------- booking window ----------
  IF p_quota = 'TQ' THEN
    -- Tatkal opens one day before the journey date FROM THE TRAIN'S ORIGIN
    v_open := ((v_journey.journey_date - 1)
               + rail.rule_time(CASE WHEN v_class.is_ac THEN 'tatkal_ac_open' ELSE 'tatkal_nonac_open' END))
              AT TIME ZONE 'Asia/Kolkata';
  ELSE
    v_open := ((p_boarding_date - rail.rule_num('arp_days')::int) + rail.rule_time('arp_open_time'))
              AT TIME ZONE 'Asia/Kolkata';
  END IF;
  IF v_now < v_open OR v_now >= rail.chart_time(v_journey.journey_id) THEN
    RAISE EXCEPTION 'WINDOW_CLOSED: % booking for % opens % and closes at chart %',
      p_quota, p_boarding_date, v_open, rail.chart_time(v_journey.journey_id) USING ERRCODE = 'RL003';
  END IF;

  -- ---------- quota eligibility ----------
  IF p_quota = 'LD' AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_passengers) e
                                WHERE e->>'gender' = 'M' AND (e->>'age')::int >= 12) THEN
    RAISE EXCEPTION 'INVALID: Ladies quota is for women (and boys under 12)' USING ERRCODE = 'RL004';
  END IF;
  IF p_quota = 'SS' AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_passengers) e
                                WHERE NOT rail.wants_lower((e->>'age')::int, e->>'gender')) THEN
    RAISE EXCEPTION 'INVALID: Senior quota needs men 60+ / women 45+' USING ERRCODE = 'RL004';
  END IF;

  -- ---------- lock the inventory pool (serialises writers on this pool only) ----------
  SELECT * INTO v_inv FROM rail.journey_inventory ji
  WHERE ji.journey_id = v_journey.journey_id AND ji.class_code = p_class AND ji.quota_code = p_quota
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVALID: class %/quota % not offered on train %', p_class, p_quota, p_train_no USING ERRCODE = 'RL004';
  END IF;

  v_range := int4range(v_from.stop_seq, v_to.stop_seq);         -- half-open [from, to)
  v_fare  := rail.compute_fare(p_train_no, p_class, p_quota, v_to.distance_km - v_from.distance_km);
  SELECT zone INTO v_zone FROM rail.stations WHERE station_code = p_from;
  v_pnr   := rail.generate_pnr(v_zone);

  INSERT INTO rail.bookings (pnr, user_id, journey_id, class_code, quota_code, from_seq, to_seq,
                             from_station, to_station, distance_km, pax_count, total_fare, channel, booked_at)
  VALUES (v_pnr, p_user_id, v_journey.journey_id, p_class, p_quota, v_from.stop_seq, v_to.stop_seq,
          p_from, p_to, v_to.distance_km - v_from.distance_km, v_npax, v_fare * v_npax, p_channel, v_now);

  SELECT count(*) INTO v_active_wl
  FROM rail.passengers p JOIN rail.bookings b ON b.pnr = p.pnr
  WHERE b.journey_id = v_journey.journey_id AND b.class_code = p_class AND b.quota_code = p_quota
    AND p.current_status = 'WL';

  -- ---------- allocate passenger by passenger ----------
  FOR v_p IN SELECT value FROM jsonb_array_elements(p_passengers) LOOP
    v_i      := v_i + 1;
    v_name   := v_p->>'name';
    v_age    := (v_p->>'age')::int;
    v_gender := v_p->>'gender';
    v_pref   := NULLIF(v_p->>'berth_pref', '')::rail.berth_type;
    v_wl_no  := NULL; v_rac_no := NULL; v_slot := NULL;
    IF v_name IS NULL OR v_age IS NULL OR v_gender IS NULL THEN
      RAISE EXCEPTION 'INVALID: passenger % needs name, age, gender', v_i USING ERRCODE = 'RL004';
    END IF;

    v_seat := rail.find_free_seat(v_journey.journey_id, p_class, p_quota, v_range,
                                  v_pref, rail.wants_lower(v_age, v_gender), v_near);
    IF v_seat IS NOT NULL THEN
      v_status := 'CNF';
      v_label  := 'CNF/' || rail.seat_label(v_seat);
      v_slot   := 1;
      SELECT coach_id INTO v_near FROM rail.seats WHERE seat_id = v_seat;
    ELSE
      IF v_quota.allows_rac THEN
        SELECT r.seat_id, r.slot INTO v_seat, v_slot
        FROM rail.find_free_rac_slot(v_journey.journey_id, p_class, v_range) r;
      END IF;
      IF v_seat IS NOT NULL THEN
        v_inv.rac_counter := v_inv.rac_counter + 1;
        v_rac_no := v_inv.rac_counter;
        v_status := 'RAC';
        v_label  := 'RAC/' || v_rac_no;
      ELSIF v_quota.allows_wl AND v_active_wl < v_class.max_waitlist THEN
        v_inv.wl_counter := v_inv.wl_counter + 1;
        v_wl_no     := v_inv.wl_counter;
        v_active_wl := v_active_wl + 1;
        v_status    := 'WL';
        v_label     := CASE p_quota WHEN 'TQ' THEN 'TQWL/' ELSE 'GNWL/' END || v_wl_no;
      ELSE
        RAISE EXCEPTION 'REGRET: no berth, RAC or waitlist left in %/%', p_class, p_quota USING ERRCODE = 'RL001';
      END IF;
    END IF;

    IF p_confirm_only AND v_status <> 'CNF' THEN
      RAISE EXCEPTION 'NOT_CONFIRMED: passenger % would be %', v_i, v_label USING ERRCODE = 'RL002';
    END IF;

    INSERT INTO rail.passengers (pnr, passenger_no, full_name, age, gender, berth_pref,
                                 booking_status, current_status, wl_number, rac_number, fare)
    VALUES (v_pnr, v_i, v_name, v_age, v_gender, v_pref, v_label, v_status, v_wl_no, v_rac_no, v_fare)
    RETURNING passenger_id INTO v_pid;

    IF v_status IN ('CNF','RAC') THEN
      INSERT INTO rail.seat_allocations (journey_id, seat_id, passenger_id, kind, slot, seg_range, allocated_at)
      VALUES (v_journey.journey_id, v_seat, v_pid, v_status::text::rail.allocation_kind, v_slot, v_range, v_now);
    END IF;

    pnr := v_pnr; passenger_no := v_i; passenger_name := v_name;
    status := v_status; status_label := v_label; fare := v_fare;
    RETURN NEXT;
  END LOOP;

  UPDATE rail.journey_inventory ji
     SET wl_counter = v_inv.wl_counter, rac_counter = v_inv.rac_counter
   WHERE ji.journey_id = v_inv.journey_id AND ji.class_code = v_inv.class_code AND ji.quota_code = v_inv.quota_code;
END;
$$;

-- -----------------------------------------------------------------------------
-- PROMOTE: RAC -> CNF first (queue order), then WL -> CNF, else WL -> RAC.
-- Segment-aware: a freed Delhi->Agra berth can only help someone whose journey
-- fits inside it. Ranges that already failed are memoised so a long queue is not
-- re-scanned for impossible journeys (any range that CONTAINS a failed range fails).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION promote_waitlist(
    p_journey_id bigint, p_class varchar, p_quota varchar,
    p_any_quota boolean DEFAULT false, p_reason text DEFAULT 'PROMOTED')
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_now        timestamptz := rail.app_now();
  v_quota      rail.quotas;
  v_inv        rail.journey_inventory;
  r            record;
  v_range      int4range;
  v_seat       integer;
  v_slot       smallint;
  v_n          integer := 0;
  v_fail_cnf   int4range[] := '{}';
  v_fail_rac   int4range[] := '{}';
BEGIN
  SELECT * INTO v_quota FROM rail.quotas WHERE quota_code = p_quota;
  SELECT * INTO v_inv FROM rail.journey_inventory
   WHERE journey_id = p_journey_id AND class_code = p_class AND quota_code = p_quota
   FOR UPDATE;
  IF NOT FOUND THEN RETURN 0; END IF;
  PERFORM set_config('rail.status_reason', p_reason, true);

  FOR r IN
    SELECT p.passenger_id, p.pnr, p.current_status, p.age, p.gender, p.berth_pref, b.from_seq, b.to_seq,
           (SELECT s.coach_id FROM rail.passengers p2
              JOIN rail.seat_allocations a ON a.passenger_id = p2.passenger_id AND a.is_active AND a.kind = 'CNF'
              JOIN rail.seats s ON s.seat_id = a.seat_id
             WHERE p2.pnr = p.pnr LIMIT 1) AS near_coach
    FROM rail.passengers p JOIN rail.bookings b ON b.pnr = p.pnr
    WHERE b.journey_id = p_journey_id AND b.class_code = p_class AND b.quota_code = p_quota
      AND p.current_status IN ('RAC','WL')
    ORDER BY (p.current_status = 'RAC') DESC, COALESCE(p.rac_number, p.wl_number)
  LOOP
    v_range := int4range(r.from_seq, r.to_seq);
    v_seat := NULL;

    -- try a confirmed berth
    IF NOT EXISTS (SELECT 1 FROM unnest(v_fail_cnf) f WHERE v_range @> f) THEN
      v_seat := rail.find_free_seat(p_journey_id, p_class, CASE WHEN p_any_quota THEN NULL ELSE p_quota END,
                                    v_range, r.berth_pref, rail.wants_lower(r.age, r.gender), r.near_coach);
      IF v_seat IS NULL THEN v_fail_cnf := v_fail_cnf || v_range; END IF;
    END IF;

    IF v_seat IS NOT NULL THEN
      UPDATE rail.seat_allocations SET is_active = false, released_at = v_now
       WHERE passenger_id = r.passenger_id AND is_active;
      INSERT INTO rail.seat_allocations (journey_id, seat_id, passenger_id, kind, slot, seg_range, allocated_at)
      VALUES (p_journey_id, v_seat, r.passenger_id, 'CNF', 1, v_range, v_now);
      UPDATE rail.passengers SET current_status = 'CNF' WHERE passenger_id = r.passenger_id;
      v_n := v_n + 1;

    -- WL can still move up to RAC
    ELSIF r.current_status = 'WL' AND v_quota.allows_rac
          AND NOT EXISTS (SELECT 1 FROM unnest(v_fail_rac) f WHERE v_range @> f) THEN
      SELECT x.seat_id, x.slot INTO v_seat, v_slot FROM rail.find_free_rac_slot(p_journey_id, p_class, v_range) x;
      IF v_seat IS NOT NULL THEN
        v_inv.rac_counter := v_inv.rac_counter + 1;
        INSERT INTO rail.seat_allocations (journey_id, seat_id, passenger_id, kind, slot, seg_range, allocated_at)
        VALUES (p_journey_id, v_seat, r.passenger_id, 'RAC', v_slot, v_range, v_now);
        UPDATE rail.passengers SET current_status = 'RAC', rac_number = v_inv.rac_counter
         WHERE passenger_id = r.passenger_id;
        v_n := v_n + 1;
      ELSE
        v_fail_rac := v_fail_rac || v_range;
      END IF;
    END IF;
  END LOOP;

  UPDATE rail.journey_inventory SET rac_counter = v_inv.rac_counter
   WHERE journey_id = p_journey_id AND class_code = p_class AND quota_code = p_quota;
  RETURN v_n;
END;
$$;

-- -----------------------------------------------------------------------------
-- CANCEL (whole PNR, or selected passenger numbers)
-- Refund rules (modelled on IR's 2015 refund rules, simplified):
--   CNF  > 48h before departure ........ flat charge per class
--   CNF  48h - 12h ..................... 25% of fare (min flat charge)
--   CNF  12h - 4h ...................... 50% of fare (min flat charge)
--   CNF  < 4h or after chart ........... no refund
--   Tatkal CNF ......................... no refund
--   RAC/WL up to 30 min before dep ..... fare minus clerkage
--   Auto-cancelled at chart ............ fare minus clerkage
--   Train cancelled .................... full refund
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cancel_ticket(
    p_pnr char(10), p_passenger_nos smallint[] DEFAULT NULL, p_reason text DEFAULT 'USER')
RETURNS TABLE (passenger_no smallint, status_before passenger_status, fare numeric, charge numeric, refund numeric)
LANGUAGE plpgsql AS $$
DECLARE
  v_now     timestamptz := rail.app_now();
  v_b       rail.bookings;
  v_j       rail.journeys;
  v_class   rail.travel_classes;
  v_hours   numeric;
  v_charge  numeric;
  v_freed   boolean := false;
  r         rail.passengers;
BEGIN
  SELECT * INTO v_b FROM rail.bookings WHERE pnr = p_pnr FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVALID: PNR % not found', p_pnr USING ERRCODE = 'RL004'; END IF;
  SELECT * INTO v_j FROM rail.journeys WHERE journey_id = v_b.journey_id;
  IF v_j.status = 'DEPARTED' THEN
    RAISE EXCEPTION 'WINDOW_CLOSED: train has departed' USING ERRCODE = 'RL003';
  END IF;
  SELECT * INTO v_class FROM rail.travel_classes WHERE class_code = v_b.class_code;

  PERFORM 1 FROM rail.journey_inventory
   WHERE journey_id = v_b.journey_id AND class_code = v_b.class_code AND quota_code = v_b.quota_code
   FOR UPDATE;

  v_hours := ROUND(EXTRACT(EPOCH FROM rail.stop_time(v_b.journey_id, v_b.from_seq) - v_now) / 3600, 2);
  PERFORM set_config('rail.status_reason', 'CANCELLED_' || p_reason, true);

  FOR r IN
    SELECT * FROM rail.passengers p
    WHERE p.pnr = p_pnr AND p.current_status <> 'CAN'
      AND (p_passenger_nos IS NULL OR p.passenger_no = ANY (p_passenger_nos))
    ORDER BY p.passenger_no
    FOR UPDATE
  LOOP
    v_charge := CASE
      WHEN p_reason = 'TRAIN_CANCELLED'               THEN 0
      WHEN p_reason = 'CHART_AUTO'                    THEN LEAST(rail.rule_num('clerkage'), r.fare)
      WHEN r.current_status IN ('RAC','WL') THEN
           CASE WHEN v_hours * 60 >= rail.rule_num('wl_cancel_cutoff_min')
                THEN LEAST(rail.rule_num('clerkage'), r.fare) ELSE r.fare END
      WHEN v_b.quota_code = 'TQ'                      THEN r.fare
      WHEN v_j.status = 'CHART_PREPARED' OR v_hours < 4 THEN r.fare
      WHEN v_hours >= 48 THEN LEAST(v_class.cancel_flat_charge, r.fare)
      WHEN v_hours >= 12 THEN LEAST(GREATEST(r.fare * 0.25, v_class.cancel_flat_charge), r.fare)
      ELSE                    LEAST(GREATEST(r.fare * 0.50, v_class.cancel_flat_charge), r.fare)
    END;
    v_charge := ROUND(v_charge, 2);

    IF r.current_status IN ('CNF','RAC') THEN v_freed := true; END IF;

    UPDATE rail.seat_allocations SET is_active = false, released_at = v_now
     WHERE seat_allocations.passenger_id = r.passenger_id AND is_active;
    UPDATE rail.passengers SET current_status = 'CAN' WHERE passengers.passenger_id = r.passenger_id;
    INSERT INTO rail.cancellations (passenger_id, pnr, status_at_cancel, reason, hours_before_dep,
                                    fare, charge, refund, cancelled_at)
    VALUES (r.passenger_id, p_pnr, r.current_status, p_reason, v_hours, r.fare, v_charge, r.fare - v_charge, v_now);

    passenger_no := r.passenger_no; status_before := r.current_status;
    fare := r.fare; charge := v_charge; refund := r.fare - v_charge;
    RETURN NEXT;
  END LOOP;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVALID: nothing left to cancel on PNR %', p_pnr USING ERRCODE = 'RL004';
  END IF;

  -- freed capacity flows to the queue automatically (only before chart)
  IF v_freed AND v_j.status = 'SCHEDULED' THEN
    PERFORM rail.promote_waitlist(v_b.journey_id, v_b.class_code, v_b.quota_code);
  END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- CHART PREPARATION
--  1. promote every pool within its own quota
--  2. release unused quota berths (Tatkal / Ladies / Senior) to GN, then TQ queue
--  3. lock the journey (no more bookings)
--  4. auto-cancel PNRs where every live passenger is still WL (refund minus clerkage);
--     WL passengers on partly-confirmed PNRs stay and may travel with their party
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION prepare_chart(p_journey_id bigint)
RETURNS TABLE (class_code varchar, cnf bigint, rac bigint, wl_travelling bigint, auto_cancelled bigint, promoted_at_chart integer)
LANGUAGE plpgsql AS $$
DECLARE
  v_j    rail.journeys;
  v_inv  record;
  v_cls  varchar;
  v_prom integer;
  v_promoted jsonb := '{}';
  v_pnr  char(10);
BEGIN
  SELECT * INTO v_j FROM rail.journeys WHERE journey_id = p_journey_id FOR UPDATE;
  IF v_j.status <> 'SCHEDULED' THEN
    RAISE EXCEPTION 'INVALID: journey % is already %', p_journey_id, v_j.status USING ERRCODE = 'RL004';
  END IF;

  -- lock all pools of the journey in a fixed order (deadlock-safe)
  PERFORM 1 FROM rail.journey_inventory ji WHERE ji.journey_id = p_journey_id
   ORDER BY ji.class_code, ji.quota_code FOR UPDATE;

  FOR v_inv IN SELECT ji.class_code, ji.quota_code FROM rail.journey_inventory ji
               WHERE ji.journey_id = p_journey_id ORDER BY ji.class_code, ji.quota_code LOOP
    v_prom := rail.promote_waitlist(p_journey_id, v_inv.class_code, v_inv.quota_code, false, 'CHART');
    v_promoted := jsonb_set(v_promoted, ARRAY[v_inv.class_code::text],
                            to_jsonb(COALESCE((v_promoted->>v_inv.class_code)::int, 0) + v_prom));
  END LOOP;

  FOR v_cls IN SELECT DISTINCT ji.class_code FROM rail.journey_inventory ji WHERE ji.journey_id = p_journey_id LOOP
    v_prom := rail.promote_waitlist(p_journey_id, v_cls, 'GN', true, 'CHART_QUOTA_RELEASE')
            + rail.promote_waitlist(p_journey_id, v_cls, 'TQ', true, 'CHART_QUOTA_RELEASE');
    v_promoted := jsonb_set(v_promoted, ARRAY[v_cls::text],
                            to_jsonb(COALESCE((v_promoted->>v_cls)::int, 0) + v_prom));
  END LOOP;

  UPDATE rail.journeys SET status = 'CHART_PREPARED', chart_prepared_at = rail.app_now()
   WHERE journey_id = p_journey_id;

  FOR v_pnr IN
    SELECT b.pnr FROM rail.bookings b JOIN rail.passengers p ON p.pnr = b.pnr
    WHERE b.journey_id = p_journey_id AND p.current_status <> 'CAN'
    GROUP BY b.pnr
    HAVING bool_and(p.current_status = 'WL')
  LOOP
    PERFORM rail.cancel_ticket(v_pnr, NULL, 'CHART_AUTO');
  END LOOP;

  RETURN QUERY
  SELECT b.class_code,
         count(*) FILTER (WHERE p.current_status = 'CNF'),
         count(*) FILTER (WHERE p.current_status = 'RAC'),
         count(*) FILTER (WHERE p.current_status = 'WL'),
         count(*) FILTER (WHERE c.reason = 'CHART_AUTO'),
         COALESCE((v_promoted->>b.class_code)::int, 0)
  FROM rail.bookings b
  JOIN rail.passengers p ON p.pnr = b.pnr
  LEFT JOIN rail.cancellations c ON c.passenger_id = p.passenger_id
  WHERE b.journey_id = p_journey_id
  GROUP BY b.class_code
  ORDER BY b.class_code;
END;
$$;

-- Train cancelled by the railway: everyone gets a full refund.
CREATE OR REPLACE FUNCTION cancel_journey(p_journey_id bigint)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_pnr char(10); v_n integer := 0;
BEGIN
  UPDATE rail.journeys SET status = 'CANCELLED' WHERE journey_id = p_journey_id AND status <> 'DEPARTED';
  IF NOT FOUND THEN RAISE EXCEPTION 'INVALID: journey % cannot be cancelled', p_journey_id USING ERRCODE = 'RL004'; END IF;
  FOR v_pnr IN SELECT DISTINCT b.pnr FROM rail.bookings b JOIN rail.passengers p ON p.pnr = b.pnr
               WHERE b.journey_id = p_journey_id AND p.current_status <> 'CAN' LOOP
    PERFORM rail.cancel_ticket(v_pnr, NULL, 'TRAIN_CANCELLED');
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$$;

-- -----------------------------------------------------------------------------
-- AVAILABILITY & SEARCH
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_availability(
    p_train_no char(5), p_boarding_date date, p_from varchar, p_to varchar,
    p_class varchar, p_quota varchar DEFAULT 'GN')
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_from rail.train_stops; v_to rail.train_stops;
  v_j rail.journeys; v_inv rail.journey_inventory; v_q rail.quotas; v_c rail.travel_classes;
  v_range int4range; v_free bigint; v_rac_free bigint; v_rac_active bigint; v_wl_active bigint;
BEGIN
  SELECT * INTO v_from FROM rail.train_stops WHERE train_no = p_train_no AND station_code = p_from;
  SELECT * INTO v_to   FROM rail.train_stops WHERE train_no = p_train_no AND station_code = p_to;
  IF v_from.stop_seq IS NULL OR v_to.stop_seq IS NULL OR v_from.stop_seq >= v_to.stop_seq THEN RETURN 'INVALID ROUTE'; END IF;
  SELECT * INTO v_j FROM rail.journeys WHERE train_no = p_train_no AND journey_date = p_boarding_date - v_from.day_offset;
  IF NOT FOUND THEN RETURN 'NOT RUNNING'; END IF;
  IF v_j.status <> 'SCHEDULED' THEN RETURN v_j.status::text; END IF;
  SELECT * INTO v_inv FROM rail.journey_inventory
   WHERE journey_id = v_j.journey_id AND class_code = p_class AND quota_code = p_quota;
  IF NOT FOUND THEN RETURN 'NOT OFFERED'; END IF;
  SELECT * INTO v_q FROM rail.quotas WHERE quota_code = p_quota;
  SELECT * INTO v_c FROM rail.travel_classes WHERE class_code = p_class;
  v_range := int4range(v_from.stop_seq, v_to.stop_seq);

  SELECT count(*) INTO v_free
  FROM rail.coaches c JOIN rail.seats s ON s.coach_id = c.coach_id
  WHERE c.train_no = p_train_no AND c.class_code = p_class AND s.quota_code = p_quota AND NOT s.is_rac_berth
    AND NOT EXISTS (SELECT 1 FROM rail.seat_allocations a WHERE a.journey_id = v_j.journey_id
                    AND a.seat_id = s.seat_id AND a.is_active AND a.seg_range && v_range);
  IF v_free > 0 THEN RETURN 'AVAILABLE-' || lpad(v_free::text, 4, '0'); END IF;

  SELECT count(*) FILTER (WHERE p.current_status = 'RAC'), count(*) FILTER (WHERE p.current_status = 'WL')
    INTO v_rac_active, v_wl_active
  FROM rail.passengers p JOIN rail.bookings b ON b.pnr = p.pnr
  WHERE b.journey_id = v_j.journey_id AND b.class_code = p_class AND b.quota_code = p_quota;

  IF v_q.allows_rac THEN
    SELECT count(*) INTO v_rac_free
    FROM rail.coaches c JOIN rail.seats s ON s.coach_id = c.coach_id AND s.is_rac_berth
    CROSS JOIN (VALUES (1),(2)) sl(slot)
    WHERE c.train_no = p_train_no AND c.class_code = p_class
      AND NOT EXISTS (SELECT 1 FROM rail.seat_allocations a WHERE a.journey_id = v_j.journey_id
                      AND a.seat_id = s.seat_id AND a.slot = sl.slot AND a.is_active AND a.seg_range && v_range);
    IF v_rac_free > 0 THEN RETURN 'RAC ' || (v_rac_active + 1); END IF;
  END IF;

  IF v_q.allows_wl AND v_wl_active < v_c.max_waitlist THEN
    RETURN CASE p_quota WHEN 'TQ' THEN 'TQWL ' ELSE 'GNWL ' END || (v_inv.wl_counter + 1) || '/WL ' || (v_wl_active + 1);
  END IF;
  RETURN 'REGRET';
END;
$$;

CREATE OR REPLACE FUNCTION search_trains(p_from varchar, p_to varchar, p_boarding_date date, p_quota varchar DEFAULT 'GN')
RETURNS TABLE (train_no char(5), train_name text, departs timestamptz, arrives timestamptz,
               duration interval, distance_km integer, class_code varchar, fare numeric, availability text)
LANGUAGE sql STABLE AS $$
  SELECT t.train_no, t.train_name,
         rail.stop_time(j.journey_id, a.stop_seq),
         rail.stop_time(j.journey_id, b.stop_seq),
         rail.stop_time(j.journey_id, b.stop_seq) - rail.stop_time(j.journey_id, a.stop_seq),
         b.distance_km - a.distance_km,
         cls.class_code,
         rail.compute_fare(t.train_no, cls.class_code, p_quota, b.distance_km - a.distance_km),
         rail.get_availability(t.train_no, p_boarding_date, p_from, p_to, cls.class_code, p_quota)
  FROM rail.train_stops a
  JOIN rail.train_stops b ON b.train_no = a.train_no AND b.station_code = p_to AND b.stop_seq > a.stop_seq
  JOIN rail.trains t      ON t.train_no = a.train_no AND t.is_active
  JOIN rail.journeys j    ON j.train_no = t.train_no AND j.journey_date = p_boarding_date - a.day_offset
  CROSS JOIN LATERAL (SELECT DISTINCT c.class_code, tc.display_order
                      FROM rail.coaches c JOIN rail.travel_classes tc USING (class_code)
                      WHERE c.train_no = t.train_no) cls
  WHERE a.station_code = p_from AND a.departure_time IS NOT NULL
  ORDER BY 3, cls.display_order
$$;

-- -----------------------------------------------------------------------------
-- Schedule journeys (and their inventory pools) for a date range
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_journeys(p_from date, p_to date)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_n integer;
BEGIN
  INSERT INTO rail.journeys (train_no, journey_date)
  SELECT t.train_no, d::date
  FROM rail.trains t
  CROSS JOIN generate_series(p_from, p_to, interval '1 day') d
  WHERE t.is_active AND EXTRACT(ISODOW FROM d)::smallint = ANY (t.runs_on)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- one pool per (class, quota) that physically has berths; GN pool always exists
  INSERT INTO rail.journey_inventory (journey_id, class_code, quota_code)
  SELECT DISTINCT j.journey_id, c.class_code, s.quota_code
  FROM rail.journeys j
  JOIN rail.coaches c ON c.train_no = j.train_no
  JOIN rail.seats s   ON s.coach_id = c.coach_id
  WHERE j.journey_date BETWEEN p_from AND p_to
  ON CONFLICT DO NOTHING;
  RETURN v_n;
END;
$$;
