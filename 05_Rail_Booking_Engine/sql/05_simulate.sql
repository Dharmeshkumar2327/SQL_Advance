-- =============================================================================
-- 05_simulate.sql
-- Synthetic but behaviour-realistic data: 4,000 users and ~60 days of booking
-- traffic for two weeks of departures (9-22 Nov 2026), replayed in strict time
-- order through the real engine (book_ticket / cancel_ticket / prepare_chart).
--
--  * demand varies by train popularity and weekday (Fri/Sun peaks)
--  * GN rush when the 60-day ARP window opens; Tatkal rush in the first minutes
--  * intermediate-station journeys (segment re-use of berths)
--  * a handful of agent-like accounts hammering Tatkal (for abuse analytics)
--  * cancellations (full + partial) feeding automatic RAC/WL promotion
--  * chart preparation 4h before departure, then departure
--
-- "Today" for the dataset is 2026-11-15 23:00 IST: week-1 journeys are charted
-- and departed; week-2 journeys are live with open waitlists to play with.
-- Fully reproducible (fixed random seed).
-- =============================================================================
\set ON_ERROR_STOP on
SET search_path = rail, public;
SET timezone = 'Asia/Kolkata';

SET client_min_messages = warning;
DROP SCHEMA IF EXISTS sim CASCADE;
CREATE SCHEMA sim;
SET client_min_messages = notice;

SELECT setseed(0.2711) \gset

-- -----------------------------------------------------------------------------
-- Users
-- -----------------------------------------------------------------------------
CREATE TABLE sim.names (m text[], f text[], l text[]);
INSERT INTO sim.names VALUES (
 '{Aarav,Vivaan,Aditya,Arjun,Rohan,Rahul,Amit,Suresh,Ramesh,Vikram,Karthik,Sanjay,Manoj,Deepak,Anil,Rajesh,Pranav,Ishaan,Kabir,Harish,Naveen,Gaurav,Abhishek,Siddharth,Mohit,Varun,Nikhil,Imran,Faisal,Joseph,Thomas,Gurpreet,Harpreet,Venkatesh,Srinivas,Murali,Ravi,Ajay,Dinesh,Yash}',
 '{Ananya,Diya,Saanvi,Aadhya,Priya,Pooja,Neha,Kavya,Sneha,Divya,Lakshmi,Meena,Sunita,Anjali,Shreya,Ritu,Nisha,Swati,Deepa,Rekha,Fatima,Ayesha,Mary,Simran,Harleen,Padma,Geeta,Asha,Shalini,Bhavna,Tanvi,Ishita,Radha,Usha,Sarita,Kiran,Megha,Aparna,Jyoti,Nandini}',
 '{Sharma,Verma,Gupta,Singh,Kumar,Patel,Shah,Reddy,Rao,Nair,Menon,Iyer,Iyengar,Pillai,Das,Banerjee,Chatterjee,Mukherjee,Ghosh,Bose,Joshi,Kulkarni,Deshpande,Patil,Pawar,Jadhav,Yadav,Mishra,Tiwari,Pandey,Dubey,Chauhan,Rathore,Gill,Sandhu,Khan,Ansari,Sheikh,DSouza,Fernandes,Naidu,Choudhary,Agarwal,Jain,Mehta}');

CREATE FUNCTION sim.pick(arr text[]) RETURNS text LANGUAGE sql VOLATILE AS
$$ SELECT arr[1 + floor(random() * cardinality(arr))::int] $$;

CREATE FUNCTION sim.person_name(p_gender text) RETURNS text LANGUAGE sql VOLATILE AS $$
  SELECT sim.pick(CASE WHEN p_gender = 'M' THEN n.m ELSE n.f END) || ' ' || sim.pick(n.l) FROM sim.names n
$$;

INSERT INTO rail.users (full_name, email, phone, gender, created_at)
SELECT fn || ' ' || ln,
       lower(fn) || '.' || lower(ln) || g || '@' || (ARRAY['gmail.com','yahoo.in','outlook.com','rediffmail.com'])[1 + g % 4],
       (6 + g % 4)::text || lpad((floor(random() * 1e9))::bigint::text, 9, '0'),
       gender,
       timestamptz '2019-01-01 00:00+05:30' + random() * interval '2400 days'
FROM (
  SELECT g, gender, split_part(nm, ' ', 1) AS fn, split_part(nm, ' ', 2) AS ln
  FROM (SELECT g, gender, sim.person_name(gender) AS nm
        FROM (SELECT g, CASE WHEN random() < 0.62 THEN 'M' ELSE 'F' END AS gender
              FROM generate_series(1, 4000) g) a) b
) u;

-- 15 agent-like accounts (user_id 1-15) that will hog Tatkal
CREATE TABLE sim.agent_users AS SELECT user_id FROM rail.users ORDER BY user_id LIMIT 15;

-- -----------------------------------------------------------------------------
-- Journeys: two weeks of departures
-- -----------------------------------------------------------------------------
SELECT rail.create_journeys('2026-11-09', '2026-11-22') AS journeys_created \gset
\echo 'journeys scheduled:' :journeys_created

-- -----------------------------------------------------------------------------
-- Demand model -> booking requests
-- -----------------------------------------------------------------------------
CREATE TABLE sim.train_demand (train_no char(5) PRIMARY KEY, factor numeric);
INSERT INTO sim.train_demand VALUES
  ('12951',1.55),('12301',1.50),('12627',1.65),('12621',1.55),('12002',1.05),
  ('22439',1.30),('12809',1.40),('12658',1.45),('12839',1.35),('12009',0.95);

CREATE TABLE sim.requests AS
WITH pool AS (
  SELECT j.journey_id, j.train_no, j.journey_date, c.class_code, tc.is_ac, tc.has_berths,
         count(*)                                         AS berths,
         count(*) FILTER (WHERE s.quota_code = 'TQ')      AS tq_berths,
         count(*) FILTER (WHERE s.quota_code = 'LD')      AS ld_berths,
         count(*) FILTER (WHERE s.quota_code = 'SS')      AS ss_berths
  FROM rail.journeys j
  JOIN rail.coaches c ON c.train_no = j.train_no
  JOIN rail.travel_classes tc ON tc.class_code = c.class_code
  JOIN rail.seats s ON s.coach_id = c.coach_id
  GROUP BY 1,2,3,4,5,6
),
sized AS (
  SELECT p.*,
         (SELECT max(stop_seq) FROM rail.train_stops ts WHERE ts.train_no = p.train_no) AS n_stops,
         round(p.berths * d.factor
               * CASE WHEN EXTRACT(ISODOW FROM p.journey_date) IN (5,7) THEN 1.20 ELSE 1.0 END
               * (0.85 + random() * 0.30) / 2.1)::int     AS n_req
  FROM pool p JOIN sim.train_demand d USING (train_no)
),
req AS (
  SELECT s.*, g AS k, random() AS r_quota, random() AS r_od, random() AS r_from, random() AS r_to,
         random() AS r_pax, random() AS r_time, random() AS r_rush
  FROM sized s CROSS JOIN LATERAL generate_series(1, s.n_req) g
),
typed AS (
  SELECT r.*,
         CASE WHEN r.tq_berths > 0 AND r.r_quota < 1.4 * r.tq_berths / r.berths THEN 'TQ'
              WHEN r.ld_berths > 0 AND r.r_quota > 0.985 THEN 'LD'
              WHEN r.ss_berths > 0 AND r.r_quota BETWEEN 0.95 AND 0.985 THEN 'SS'
              ELSE 'GN' END AS quota_code,
         CASE WHEN r.r_od < 0.55 THEN 1 ELSE 1 + floor(r.r_from * (r.n_stops - 1))::int END AS from_seq
  FROM req r
),
od AS (
  SELECT t.*,
         CASE WHEN t.r_od < 0.55 THEN t.n_stops
              ELSE t.from_seq + 1 + floor(t.r_to * (t.n_stops - t.from_seq))::int END AS to_seq
  FROM typed t
)
SELECT row_number() OVER ()                         AS req_id,
       od.journey_id, od.train_no, od.journey_date, od.class_code, od.is_ac, od.has_berths, od.quota_code,
       od.from_seq, od.to_seq, fs.station_code AS from_station, ts.station_code AS to_station,
       (od.journey_date + fs.day_offset)            AS boarding_date,
       LEAST(CASE od.quota_code WHEN 'TQ' THEN 4 WHEN 'SS' THEN 2 ELSE 6 END,
             CASE WHEN od.r_pax < 0.38 THEN 1 WHEN od.r_pax < 0.68 THEN 2 WHEN od.r_pax < 0.80 THEN 3
                  WHEN od.r_pax < 0.91 THEN 4 WHEN od.r_pax < 0.96 THEN 5 ELSE 6 END) AS pax,
       od.r_time, od.r_rush,
       rail.stop_time(od.journey_id, od.from_seq)  AS dep_at,
       rail.chart_time(od.journey_id)              AS chart_at
FROM od
JOIN rail.train_stops fs ON fs.train_no = od.train_no AND fs.stop_seq = od.from_seq
JOIN rail.train_stops ts ON ts.train_no = od.train_no AND ts.stop_seq = od.to_seq;

-- request timestamps
ALTER TABLE sim.requests ADD COLUMN request_at timestamptz, ADD COLUMN user_id int,
                          ADD COLUMN passengers jsonb, ADD COLUMN confirm_only boolean, ADD COLUMN channel text;

UPDATE sim.requests r SET request_at =
  CASE
    WHEN quota_code = 'TQ' THEN
      ((journey_date - 1) + CASE WHEN is_ac THEN time '10:00' ELSE time '11:00' END) AT TIME ZONE 'Asia/Kolkata'
      + CASE WHEN r_rush < 0.85 THEN (-ln(1 - r_time * 0.999) * 3) * interval '1 minute'   -- first-minutes stampede
             ELSE r_time * interval '9 hours' END
    WHEN r_rush < 0.22 THEN                                                               -- ARP-opening rush
      ((boarding_date - 60) + time '08:00') AT TIME ZONE 'Asia/Kolkata' + (r_time ^ 3) * interval '2 days'
    ELSE
      dep_at - interval '6 hours' - (r_time ^ 1.6) * interval '58 days'
  END;
UPDATE sim.requests SET request_at = LEAST(request_at, chart_at - interval '20 minutes');
UPDATE sim.requests SET request_at = GREATEST(request_at, ((boarding_date - 60) + time '08:00') AT TIME ZONE 'Asia/Kolkata')
 WHERE quota_code <> 'TQ';

UPDATE sim.requests SET
  user_id = CASE WHEN quota_code = 'TQ' AND random() < 0.22
                 THEN 1 + floor(random() * 15)::int
                 ELSE 16 + floor(random() * 3985)::int END,
  confirm_only = random() < 0.05,
  channel = CASE WHEN random() < 0.60 THEN 'APP' WHEN random() < 0.92 THEN 'WEB' ELSE 'COUNTER' END;

-- passenger lists
UPDATE sim.requests r SET passengers = x.pl
FROM (
  SELECT r.req_id,
         jsonb_agg(jsonb_build_object(
             'name',   sim.person_name(g.gender),
             'age',    g.age,
             'gender', g.gender,
             'berth_pref', CASE WHEN random() < 0.35 THEN
                              CASE WHEN r.has_berths THEN (ARRAY['LB','LB','MB','UB','UB','SL','SU'])[1 + floor(random()*7)::int]
                                   ELSE (ARRAY['WS','WS','AS','MS'])[1 + floor(random()*4)::int] END
                           END)
           ORDER BY g.n) AS pl
  FROM sim.requests r
  CROSS JOIN LATERAL (
    SELECT n, gender,
           CASE WHEN r.quota_code = 'SS' THEN CASE WHEN gender = 'M' THEN 60 + floor(random()*25)::int ELSE 45 + floor(random()*35)::int END
                WHEN ra < 0.10 THEN 5 + floor(random()*13)::int
                WHEN ra < 0.88 THEN 18 + floor(random()*42)::int
                ELSE 60 + floor(random()*25)::int END AS age
    FROM (SELECT n, random() AS ra,
                 CASE WHEN r.quota_code = 'LD' OR random() < 0.42 THEN 'F' ELSE 'M' END AS gender
          FROM generate_series(1, r.pax) n) z
  ) g
  GROUP BY r.req_id
) x
WHERE x.req_id = r.req_id;

-- -----------------------------------------------------------------------------
-- Event queue, replayed in time order
-- -----------------------------------------------------------------------------
CREATE TABLE sim.events (
  event_id  bigserial PRIMARY KEY,
  event_at  timestamptz NOT NULL,
  kind      text NOT NULL,            -- BOOK | CANCEL | CHART | DEPART
  ref_id    bigint,                   -- req_id or journey_id
  pnr       char(10),
  pax_nos   smallint[]
);
CREATE INDEX ON sim.events (event_at, event_id);

INSERT INTO sim.events (event_at, kind, ref_id) SELECT request_at, 'BOOK', req_id FROM sim.requests;
INSERT INTO sim.events (event_at, kind, ref_id) SELECT rail.chart_time(journey_id), 'CHART', journey_id FROM rail.journeys;
INSERT INTO sim.events (event_at, kind, ref_id) SELECT rail.stop_time(journey_id, 1), 'DEPART', journey_id FROM rail.journeys;

CREATE PROCEDURE sim.run(p_until timestamptz)
LANGUAGE plpgsql AS $$
DECLARE
  e        sim.events;
  q        sim.requests;
  v_pnr    char(10);
  v_wl     boolean;
  v_pax    smallint;
  v_n      bigint := 0;
  v_cancel_at timestamptz;
  v_state  text; v_msg text;
BEGIN
  PERFORM setseed(0.5813);
  LOOP
    DELETE FROM sim.events WHERE event_id = (SELECT event_id FROM sim.events ORDER BY event_at, event_id LIMIT 1)
    RETURNING * INTO e;
    EXIT WHEN e.event_id IS NULL OR e.event_at > p_until;
    PERFORM set_config('rail.now', e.event_at::text, false);

    IF e.kind = 'BOOK' THEN
      SELECT * INTO q FROM sim.requests WHERE req_id = e.ref_id;
      BEGIN
        SELECT b.pnr, bool_or(b.status <> 'CNF'), max(b.passenger_no) INTO v_pnr, v_wl, v_pax
        FROM rail.book_ticket(q.user_id, q.train_no, q.boarding_date, q.from_station, q.to_station,
                              q.class_code, q.quota_code, q.passengers, q.confirm_only, q.channel) b
        GROUP BY b.pnr;
        INSERT INTO rail.booking_attempts (user_id, train_no, journey_date, from_station, to_station, class_code,
                                           quota_code, pax_count, attempted_at, outcome, pnr)
        VALUES (q.user_id, q.train_no, q.boarding_date, q.from_station, q.to_station, q.class_code,
                q.quota_code, q.pax, e.event_at, 'BOOKED', v_pnr);

        -- some travellers cancel later (waitlisted ones far more often)
        IF random() < (CASE WHEN q.quota_code = 'TQ' THEN 0.04 WHEN v_wl THEN 0.24 ELSE 0.16 END) THEN
          v_cancel_at := e.event_at + random() * (q.dep_at - interval '45 minutes' - e.event_at);
          INSERT INTO sim.events (event_at, kind, pnr, pax_nos)
          VALUES (v_cancel_at, 'CANCEL', v_pnr,
                  CASE WHEN v_pax > 1 AND random() < 0.25 THEN ARRAY[(1 + floor(random() * v_pax))::smallint] END);
        END IF;
      EXCEPTION WHEN SQLSTATE 'RL001' OR SQLSTATE 'RL002' OR SQLSTATE 'RL003' OR SQLSTATE 'RL004' THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
        INSERT INTO rail.booking_attempts (user_id, train_no, journey_date, from_station, to_station, class_code,
                                           quota_code, pax_count, attempted_at, outcome, message)
        VALUES (q.user_id, q.train_no, q.boarding_date, q.from_station, q.to_station, q.class_code, q.quota_code,
                q.pax, e.event_at,
                CASE v_state WHEN 'RL001' THEN 'REGRET' WHEN 'RL002' THEN 'NOT_CONFIRMED'
                             WHEN 'RL003' THEN 'WINDOW_CLOSED' ELSE 'INVALID' END, v_msg);
      END;

    ELSIF e.kind = 'CANCEL' THEN
      BEGIN
        PERFORM rail.cancel_ticket(e.pnr, e.pax_nos, 'USER');
      EXCEPTION WHEN SQLSTATE 'RL003' OR SQLSTATE 'RL004' THEN NULL;   -- already auto-cancelled / departed
      END;

    ELSIF e.kind = 'CHART' THEN
      PERFORM rail.prepare_chart(e.ref_id);

    ELSIF e.kind = 'DEPART' THEN
      UPDATE rail.journeys SET status = 'DEPARTED' WHERE journey_id = e.ref_id AND status = 'CHART_PREPARED';
    END IF;

    v_n := v_n + 1;
    IF v_n % 5000 = 0 OR v_n = 500 THEN
      COMMIT;
      ANALYZE rail.bookings, rail.passengers, rail.seat_allocations, rail.passenger_status_history;
      RAISE NOTICE '% events replayed, sim clock %', v_n, e.event_at;
    END IF;
  END LOOP;
  COMMIT;
  RAISE NOTICE 'done: % events replayed', v_n;
END;
$$;

CALL sim.run('2026-11-15 23:00+05:30');

-- Leave the session/business clock at "dataset today"
ALTER DATABASE :"DBNAME" SET rail.now = '2026-11-15 23:00:00+05:30';
