-- =============================================================================
-- tests/test_engine.sql
-- Scenario tests for the reservation engine. Everything runs inside ONE
-- transaction on a tiny purpose-built test train and is rolled back at the end,
-- so the main dataset is never touched.
--
-- Test train 99999  NDLS --(seg 1)--> AGC --(seg 2)--> BPL, one SL coach:
--   berth 1 LB  GN     berth 2 UB  GN     berth 3 SL  RAC (2 slots)     berth 4 LB  TQ
-- =============================================================================
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null
SET search_path = rail, public;
SET client_min_messages = notice;

BEGIN;

CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', p_name; END IF;
  RAISE NOTICE 'PASS  %', p_name;
END $$;

-- expects the statement to fail with the given SQLSTATE
CREATE FUNCTION pg_temp.expect_error(p_sql text, p_state text, p_name text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_state text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    IF v_state = p_state THEN RAISE NOTICE 'PASS  %  (SQLSTATE %)', p_name, v_state; RETURN; END IF;
    RAISE EXCEPTION 'FAIL: % - expected %, got %', p_name, p_state, v_state;
  END;
  RAISE EXCEPTION 'FAIL: % - statement succeeded but should have failed', p_name;
END $$;

-- convenience: book one passenger and return the status label
CREATE FUNCTION pg_temp.book1(p_from text, p_to text, p_quota text DEFAULT 'GN', p_age int DEFAULT 30,
                              p_gender text DEFAULT 'M', p_date date DEFAULT '2026-12-20')
RETURNS text LANGUAGE sql AS $$
  SELECT b.pnr || ' ' || b.status_label
  FROM rail.book_ticket(100, '99999', p_date, p_from, p_to, 'SL', p_quota,
       jsonb_build_array(jsonb_build_object('name', 'Test Pax', 'age', p_age, 'gender', p_gender))) b
$$;

-- ---------------------------------------------------------------- fixture
INSERT INTO trains VALUES ('99999', 'Test Express', 'SUPERFAST', '{1,2,3,4,5,6,7}', true);
INSERT INTO train_stops VALUES
  ('99999', 1, 'NDLS', NULL,   '06:00', 0, 0),
  ('99999', 2, 'AGC',  '08:00','08:05', 0, 195),
  ('99999', 3, 'BPL',  '13:00', NULL,   0, 702);
INSERT INTO coaches (train_no, coach_no, class_code, position) VALUES ('99999', 'S1', 'SL', 1);
INSERT INTO seats (coach_id, berth_no, berth_type, quota_code, is_rac_berth)
SELECT coach_id, b, t::berth_type, q, r
FROM coaches, (VALUES (1,'LB','GN',false), (2,'UB','GN',false), (3,'SL','GN',true), (4,'LB','TQ',false)) v(b,t,q,r)
WHERE train_no = '99999';
INSERT INTO journeys (train_no, journey_date) VALUES ('99999', '2026-12-20'), ('99999', '2026-12-21');
INSERT INTO journey_inventory (journey_id, class_code, quota_code)
SELECT journey_id, 'SL', q FROM journeys, unnest('{GN,TQ}'::text[]) q WHERE train_no = '99999';

SET LOCAL rail.now = '2026-12-01 10:00+05:30';

CREATE TEMP TABLE t (tag text PRIMARY KEY, pnr char(10), label text);

-- ---------------------------------------------------------------- fares
SELECT pg_temp.check(compute_fare('99999','SL','GN',702) > 0 AND compute_fare('99999','SL','GN',702) % 5 = 0,
                     'fare is positive and rounded to Rs 5');
SELECT pg_temp.check(compute_fare('99999','SL','TQ',702) > compute_fare('99999','SL','GN',702),
                     'Tatkal fare carries a premium');
SELECT pg_temp.check(compute_fare('99999','3A','GN',702) > compute_fare('99999','SL','GN',702),
                     'AC fare (with GST) above sleeper');

-- ---------------------------------------------------------------- booking ladder
INSERT INTO t SELECT 'P1', split_part(x,' ',1), split_part(x,' ',2) FROM pg_temp.book1('NDLS','AGC') x;
INSERT INTO t SELECT 'P2', split_part(x,' ',1), split_part(x,' ',2) FROM pg_temp.book1('AGC','BPL') x;
SELECT pg_temp.check((SELECT label FROM t WHERE tag='P1') LIKE 'CNF/S1/%', 'P1 NDLS-AGC confirmed');
SELECT pg_temp.check((SELECT label FROM t WHERE tag='P2') = (SELECT label FROM t WHERE tag='P1'),
                     'P2 AGC-BPL re-uses the SAME berth (segment packing)');

INSERT INTO t SELECT 'P3', split_part(x,' ',1), split_part(x,' ',2) FROM pg_temp.book1('NDLS','BPL') x;
INSERT INTO t SELECT 'P4', split_part(x,' ',1), split_part(x,' ',2) FROM pg_temp.book1('NDLS','BPL') x;
INSERT INTO t SELECT 'P5', split_part(x,' ',1), split_part(x,' ',2) FROM pg_temp.book1('NDLS','BPL') x;
INSERT INTO t SELECT 'P6', split_part(x,' ',1), split_part(x,' ',2) FROM pg_temp.book1('NDLS','BPL') x;
INSERT INTO t SELECT 'P7', split_part(x,' ',1), split_part(x,' ',2) FROM pg_temp.book1('NDLS','AGC') x;
SELECT pg_temp.check((SELECT label FROM t WHERE tag='P3') LIKE 'CNF/S1/%', 'P3 confirmed on the last GN berth');
SELECT pg_temp.check((SELECT label FROM t WHERE tag='P4') = 'RAC/1', 'P4 gets RAC/1');
SELECT pg_temp.check((SELECT label FROM t WHERE tag='P5') = 'RAC/2', 'P5 gets RAC/2 (shares the side-lower)');
SELECT pg_temp.check((SELECT label FROM t WHERE tag='P6') = 'GNWL/1', 'P6 waitlisted GNWL/1');
SELECT pg_temp.check((SELECT label FROM t WHERE tag='P7') = 'GNWL/2', 'P7 waitlisted GNWL/2');
SELECT pg_temp.check(get_availability('99999','2026-12-20','NDLS','BPL','SL') = 'GNWL 3/WL 3',
                     'availability shows next waitlist number');
SELECT pg_temp.check(get_availability('99999','2026-12-20','NDLS','BPL','SL','TQ') = 'AVAILABLE-0001',
                     'Tatkal berth untouched by GN demand');

-- RAC passengers share one berth, in different slots
SELECT pg_temp.check((SELECT count(DISTINCT seat_id) = 1 AND count(DISTINCT slot) = 2
                      FROM seat_allocations a JOIN passengers p USING (passenger_id)
                      WHERE p.pnr IN (SELECT pnr FROM t WHERE tag IN ('P4','P5')) AND a.is_active),
                     'two RAC passengers on one berth, slots 1 and 2');

-- ---------------------------------------------------------------- confirm-only is atomic
SELECT pg_temp.expect_error(
  $q$SELECT * FROM rail.book_ticket(100,'99999','2026-12-20','NDLS','BPL','SL','GN',
       '[{"name":"A","age":30,"gender":"M"}]', true)$q$, 'RL002', 'confirm-only booking rejected when no berth');
SELECT pg_temp.check((SELECT count(*) FROM bookings b JOIN journeys j USING (journey_id) WHERE j.train_no='99999') = 7,
                     'rejected booking left no rows behind');

-- ---------------------------------------------------------------- cancellation + promotion
CREATE TEMP TABLE refund AS SELECT * FROM cancel_ticket((SELECT pnr FROM t WHERE tag='P3'));
SELECT pg_temp.check((SELECT charge FROM refund) = 120 AND (SELECT refund FROM refund) = (SELECT fare FROM refund) - 120,
                     'CNF cancelled >48h before departure: flat Rs 120 deducted');
SELECT pg_temp.check((SELECT current_status FROM v_pnr_status WHERE pnr = (SELECT pnr FROM t WHERE tag='P4')) LIKE 'CNF/S1/%',
                     'RAC/1 (P4) auto-promoted to CNF');
SELECT pg_temp.check((SELECT current_status FROM v_pnr_status WHERE pnr = (SELECT pnr FROM t WHERE tag='P5')) = 'RAC 1',
                     'P5 moved up to RAC 1');
SELECT pg_temp.check((SELECT current_status FROM v_pnr_status WHERE pnr = (SELECT pnr FROM t WHERE tag='P6')) = 'RAC 2',
                     'WL/1 (P6) promoted into the freed RAC slot');
SELECT pg_temp.check((SELECT current_status FROM v_pnr_status WHERE pnr = (SELECT pnr FROM t WHERE tag='P7')) = 'WL 1',
                     'P7 is now WL 1');
SELECT pg_temp.check((SELECT string_agg(new_status::text, '>' ORDER BY history_id)
                      FROM passenger_status_history h JOIN passengers p USING (passenger_id)
                      WHERE p.pnr = (SELECT pnr FROM t WHERE tag='P6')) = 'WL>RAC',
                     'audit trail records WL > RAC');

-- RAC / WL cancellation costs only clerkage
SELECT pg_temp.check((SELECT charge FROM cancel_ticket((SELECT pnr FROM t WHERE tag='P5'))) = 60,
                     'RAC cancellation: Rs 60 clerkage');
SELECT pg_temp.check((SELECT current_status FROM v_pnr_status WHERE pnr = (SELECT pnr FROM t WHERE tag='P6')) = 'RAC 1',
                     'P6 now RAC 1');
SELECT pg_temp.check((SELECT current_status FROM v_pnr_status WHERE pnr = (SELECT pnr FROM t WHERE tag='P7')) = 'RAC 2',
                     'P7 (NDLS-AGC) fits the RAC slot freed only on its segment');

-- ---------------------------------------------------------------- segment-aware availability & REGRET
UPDATE travel_classes SET max_waitlist = 0 WHERE class_code = 'SL';
SELECT pg_temp.check(get_availability('99999','2026-12-20','NDLS','BPL','SL') = 'REGRET',
                     'NDLS-BPL: no berth, no RAC, no waitlist => REGRET');
SELECT pg_temp.check(get_availability('99999','2026-12-20','AGC','BPL','SL') = 'RAC 3',
                     'AGC-BPL: same train still offers RAC (slot free on that segment)');
SELECT pg_temp.expect_error($q$SELECT pg_temp.book1('NDLS','BPL')$q$, 'RL001', 'waitlist full -> REGRET');
UPDATE travel_classes SET max_waitlist = 200 WHERE class_code = 'SL';

-- ---------------------------------------------------------------- quota rules
SELECT pg_temp.expect_error($q$SELECT pg_temp.book1('NDLS','BPL','TQ')$q$, 'RL003', 'Tatkal before window opens');
SELECT pg_temp.expect_error(
  $q$SELECT * FROM rail.book_ticket(100,'99999','2026-12-20','NDLS','BPL','SL','LD','[{"name":"A","age":30,"gender":"M"}]')$q$,
  'RL004', 'Ladies quota refuses adult male');
SELECT pg_temp.expect_error(
  $q$SELECT * FROM rail.book_ticket(100,'99999','2026-12-20','BPL','NDLS','SL','GN','[{"name":"A","age":30,"gender":"M"}]')$q$,
  'RL004', 'wrong direction rejected');
SELECT pg_temp.expect_error(
  $q$SELECT * FROM rail.book_ticket(100,'99999','2027-03-01','NDLS','BPL','SL','GN','[{"name":"A","age":30,"gender":"M"}]')$q$,
  'RL004', 'no such journey');

SET LOCAL rail.now = '2026-12-19 11:00:30+05:30';        -- non-AC Tatkal opens 11:00 the day before
INSERT INTO t SELECT 'TQ1', split_part(x,' ',1), split_part(x,' ',2) FROM pg_temp.book1('NDLS','BPL','TQ') x;
SELECT pg_temp.check((SELECT label FROM t WHERE tag='TQ1') = 'CNF/S1/4/LB', 'Tatkal opens on time and uses the TQ berth');
SELECT pg_temp.check((SELECT refund FROM cancel_ticket((SELECT pnr FROM t WHERE tag='TQ1'))) = 0,
                     'confirmed Tatkal cancellation: no refund');

-- ---------------------------------------------------------------- database-level guarantees
SELECT pg_temp.expect_error(
  $q$INSERT INTO rail.seat_allocations (journey_id, seat_id, passenger_id, kind, slot, seg_range, allocated_at)
     SELECT a.journey_id, a.seat_id, (SELECT passenger_id FROM rail.passengers p WHERE p.pnr = (SELECT pnr FROM t WHERE tag='P3')),
            'CNF', 1, int4range(1,3), now()
     FROM rail.seat_allocations a JOIN rail.passengers p USING (passenger_id)
     WHERE p.pnr = (SELECT pnr FROM t WHERE tag='P1') AND a.is_active$q$,
  '23P01', 'EXCLUDE constraint blocks an overlapping allocation');
SELECT pg_temp.expect_error(
  $q$UPDATE rail.passengers SET current_status = 'CNF' WHERE pnr = (SELECT pnr FROM t WHERE tag='P3')$q$,
  'P0001', 'state machine forbids CAN -> CNF');
SELECT pg_temp.expect_error(
  $q$UPDATE rail.bookings SET to_station = 'AGC', to_seq = 2 WHERE pnr = (SELECT pnr FROM t WHERE tag='P4')$q$,
  'P0001', 'booking journey fields are immutable');
SELECT pg_temp.expect_error(
  $q$DELETE FROM rail.seat_allocations WHERE passenger_id IN (SELECT passenger_id FROM rail.passengers WHERE pnr = (SELECT pnr FROM t WHERE tag='P1'))$q$,
  'P0001', 'allocation ledger is append-only');

-- ---------------------------------------------------------------- chart preparation
SET LOCAL rail.now = '2026-12-20 02:00+05:30';           -- 4h before 06:00 departure
CREATE TEMP TABLE chart AS SELECT * FROM prepare_chart((SELECT journey_id FROM journeys WHERE train_no='99999' AND journey_date='2026-12-20'));
SELECT pg_temp.check((SELECT current_status FROM v_pnr_status WHERE pnr = (SELECT pnr FROM t WHERE tag='P6')) LIKE 'CNF/S1/4/%',
                     'chart releases unused Tatkal berth to RAC passenger P6');
SELECT pg_temp.check((SELECT current_status FROM v_pnr_status WHERE pnr = (SELECT pnr FROM t WHERE tag='P7')) = 'RAC/S1/3/SL',
                     'P7 travels RAC; berth shown on the chart');
SELECT pg_temp.check((SELECT status FROM journeys WHERE train_no='99999' AND journey_date='2026-12-20') = 'CHART_PREPARED',
                     'journey locked after chart');
SELECT pg_temp.expect_error($q$SELECT pg_temp.book1('NDLS','BPL')$q$, 'RL003', 'no booking after chart');

-- fully waitlisted PNR is auto-cancelled at chart with refund minus clerkage
SET LOCAL rail.now = '2026-12-01 10:00+05:30';
UPDATE seats SET is_rac_berth = false WHERE coach_id = (SELECT coach_id FROM coaches WHERE train_no='99999') AND berth_no = 3; -- no RAC on 21st
INSERT INTO t SELECT 'D'||g, split_part(x,' ',1), split_part(x,' ',2)
FROM generate_series(1,5) g, LATERAL pg_temp.book1('NDLS','BPL','GN',30 + g,'M','2026-12-21') x;  -- depends on g => runs per row
SELECT pg_temp.check((SELECT label FROM t WHERE tag='D4') = 'GNWL/1' AND (SELECT label FROM t WHERE tag='D5') = 'GNWL/2',
                     'day 2: three berths sold, then waitlist');
SET LOCAL rail.now = '2026-12-21 02:00+05:30';
CREATE TEMP TABLE chart2 AS SELECT * FROM prepare_chart((SELECT journey_id FROM journeys WHERE train_no='99999' AND journey_date='2026-12-21'));
SELECT pg_temp.check((SELECT current_status FROM v_pnr_status WHERE pnr = (SELECT pnr FROM t WHERE tag='D4')) = 'CNF/S1/4/LB',
                     'WL/1 confirmed at chart on the unsold Tatkal berth');
SELECT pg_temp.check((SELECT count(*) FROM cancellations c JOIN passengers p USING (passenger_id)
                      WHERE p.pnr = (SELECT pnr FROM t WHERE tag = 'D5')
                        AND c.reason = 'CHART_AUTO' AND c.refund = c.fare - 60) = 1,
                     'still-waitlisted PNR auto-cancelled at chart, refund = fare - Rs 60');

-- ---------------------------------------------------------------- train cancelled
INSERT INTO journeys (train_no, journey_date) VALUES ('99999', '2026-12-22');
INSERT INTO journey_inventory SELECT journey_id, 'SL', 'GN' FROM journeys WHERE train_no='99999' AND journey_date='2026-12-22';
SET LOCAL rail.now = '2026-12-01 10:00+05:30';
SELECT pg_temp.book1('NDLS','BPL','GN',30,'M','2026-12-22') IS NOT NULL AS booked_for_cancel \gset
SELECT cancel_journey((SELECT journey_id FROM journeys WHERE train_no='99999' AND journey_date='2026-12-22')) AS pnrs_refunded \gset
SELECT pg_temp.check(:pnrs_refunded = 1
                     AND (SELECT sum(charge) FROM cancellations c JOIN bookings b USING (pnr) JOIN journeys j USING (journey_id)
                          WHERE j.train_no='99999' AND j.journey_date='2026-12-22') = 0,
                     'train cancellation: full refund');

-- ---------------------------------------------------------------- global integrity on the real dataset
SELECT pg_temp.check(NOT EXISTS (
  SELECT 1 FROM seat_allocations a JOIN seat_allocations b
    ON a.journey_id = b.journey_id AND a.seat_id = b.seat_id AND a.slot = b.slot
   AND a.allocation_id < b.allocation_id AND a.seg_range && b.seg_range
  WHERE a.is_active AND b.is_active), 'dataset: zero overlapping allocations');
SELECT pg_temp.check(NOT EXISTS (
  SELECT 1 FROM passengers p WHERE p.current_status IN ('CNF','RAC')
    AND NOT EXISTS (SELECT 1 FROM seat_allocations a WHERE a.passenger_id = p.passenger_id AND a.is_active)),
  'dataset: every CNF/RAC passenger holds a berth');
SELECT pg_temp.check(NOT EXISTS (
  SELECT 1 FROM passengers p WHERE p.current_status = 'CAN'
    AND NOT EXISTS (SELECT 1 FROM cancellations c WHERE c.passenger_id = p.passenger_id)),
  'dataset: every cancellation has a refund record');
SELECT pg_temp.check(NOT EXISTS (
  SELECT 1 FROM bookings b WHERE b.total_fare <> (SELECT sum(fare) FROM passengers p WHERE p.pnr = b.pnr)),
  'dataset: PNR totals equal passenger fares');
SELECT pg_temp.check(NOT EXISTS (
  SELECT 1 FROM journeys j JOIN bookings b USING (journey_id) JOIN passengers p USING (pnr)
  WHERE j.status = 'DEPARTED' AND p.current_status <> 'CAN'
  GROUP BY b.pnr HAVING bool_and(p.current_status = 'WL')),
  'dataset: no fully waitlisted PNR survived a chart');

ROLLBACK;
\o
\echo 'All engine tests passed.'
