-- =============================================================================
-- 07_demo.sql  -  a guided tour of the engine on the live (week-2) data.
-- Everything runs in a transaction that is rolled back, so you can replay it.
--   psql -d railway -f sql/07_demo.sql
-- The business clock is frozen at 2026-11-15 23:00 IST (see README).
-- =============================================================================
SET search_path = rail, public;
SET timezone = 'Asia/Kolkata';
\pset footer off
BEGIN;

\echo '--- 1. Search trains Bhopal -> New Delhi boarding on 20 Nov, with live availability'
SELECT train_no, train_name, to_char(departs, 'DD Mon HH24:MI') AS departs, to_char(arrives, 'DD Mon HH24:MI') AS arrives,
       duration, class_code, fare, availability
FROM search_trains('BPL', 'NDLS', '2026-11-20');

\echo '--- 2. Book a family of three on 12627 Karnataka Express, 3A'
CREATE TEMP TABLE my_booking AS
SELECT * FROM book_ticket(
  42, '12627', '2026-11-20', 'BPL', 'NDLS', '3A', 'GN',
  '[{"name":"Dharmesh Kumar","age":34,"gender":"M","berth_pref":"UB"},
    {"name":"Priya Kumar",   "age":31,"gender":"F","berth_pref":"MB"},
    {"name":"Sita Devi",     "age":63,"gender":"F"}]');
SELECT * FROM my_booking;

\echo '--- 3. PNR enquiry'
SELECT pnr, train_no, boarding_date, from_station, to_station, class_code, passenger_no, full_name,
       booking_status, current_status, chart_status
FROM v_pnr_status WHERE pnr = (SELECT pnr FROM my_booking LIMIT 1);

\echo '--- 4. Pick the busiest live waitlist and look at the head of its queue'
CREATE TEMP TABLE pool AS
SELECT b.journey_id, b.class_code, b.quota_code, count(*) AS waiting
FROM passengers p JOIN bookings b USING (pnr) JOIN journeys j USING (journey_id)
WHERE p.current_status IN ('RAC','WL') AND j.status = 'SCHEDULED' AND b.quota_code = 'GN'
  AND b.from_seq = 1 AND b.to_seq = (SELECT max(stop_seq) FROM train_stops ts WHERE ts.train_no = j.train_no)
GROUP BY 1, 2, 3 ORDER BY waiting DESC LIMIT 1;
SELECT j.train_no, j.journey_date, pool.* FROM pool JOIN journeys j USING (journey_id);

CREATE TEMP TABLE queue_before AS
SELECT v.pnr, v.passenger_no, v.full_name, v.booking_status, v.current_status AS status_before
FROM v_pnr_status v
JOIN bookings b ON b.pnr = v.pnr
JOIN pool ON pool.journey_id = b.journey_id AND pool.class_code = b.class_code AND pool.quota_code = b.quota_code
WHERE v.current_status ~ '^(RAC|WL) ' ORDER BY v.current_status ~ '^WL', substring(v.current_status FROM '\d+')::int LIMIT 6;
SELECT * FROM queue_before;

\echo '--- 5. A confirmed end-to-end passenger in that pool cancels (refund rules apply) ...'
CREATE TEMP TABLE victim AS
SELECT b.pnr FROM bookings b JOIN pool USING (journey_id, class_code, quota_code)
JOIN passengers p USING (pnr)
WHERE p.current_status = 'CNF' AND b.from_seq = 1
  AND b.to_seq = (SELECT max(stop_seq) FROM train_stops ts JOIN journeys j USING (train_no) WHERE j.journey_id = b.journey_id)
GROUP BY b.pnr HAVING bool_and(p.current_status = 'CNF') AND count(*) = 2
LIMIT 1;
SELECT * FROM cancel_ticket((SELECT pnr FROM victim));

\echo '--- ... and the queue moves on its own: RAC -> CNF, WL -> RAC'
SELECT q.pnr, q.full_name, q.booking_status, q.status_before, v.current_status AS status_now
FROM queue_before q JOIN v_pnr_status v USING (pnr, passenger_no)
ORDER BY q.status_before;

\echo '--- 6. Full audit trail of the first passenger in that queue'
SELECT h.changed_at, h.old_status, h.new_status, h.status_label, h.reason
FROM passenger_status_history h JOIN passengers p USING (passenger_id)
WHERE (p.pnr, p.passenger_no) = (SELECT pnr, passenger_no FROM queue_before LIMIT 1)
ORDER BY h.history_id;

\echo '--- 7. Waitlist prediction from history'
SELECT predict_confirmation('12627', '3A', 15) AS "12627 3A GNWL 15",
       predict_confirmation('12951', '3A', 40) AS "12951 3A GNWL 40";

ROLLBACK;
