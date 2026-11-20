-- =============================================================================
-- 06_analytics.sql
-- 26 analyst queries + a waitlist-confirmation predictor, grouped by theme.
-- Run section by section, e.g.  psql -d railway -f sql/06_analytics.sql
-- Techniques: window functions (ROW_NUMBER, LAG, running sums, moving averages,
-- NTILE, PERCENT_RANK), gaps-and-islands, range types, generate_series,
-- FILTER aggregates, PERCENTILE_CONT, recursive-free path building with
-- STRING_AGG, materialized views, LATERAL joins.
-- =============================================================================
SET search_path = rail, public;
SET timezone = 'Asia/Kolkata';
\pset footer off

-- #############################################################################
-- A. OPERATIONS & CAPACITY
-- #############################################################################

\echo '=== Q01. Journey snapshot: passenger status mix per train-run (pivot with FILTER) ==='
SELECT j.train_no, j.journey_date, j.status,
       count(*) FILTER (WHERE p.current_status = 'CNF') AS cnf,
       count(*) FILTER (WHERE p.current_status = 'RAC') AS rac,
       count(*) FILTER (WHERE p.current_status = 'WL')  AS wl,
       count(*) FILTER (WHERE p.current_status = 'CAN') AS can,
       round(100.0 * count(*) FILTER (WHERE p.current_status = 'CNF')
             / NULLIF(count(*) FILTER (WHERE p.current_status <> 'CAN'), 0), 1) AS pct_cnf_of_live
FROM journeys j
JOIN bookings b   ON b.journey_id = j.journey_id
JOIN passengers p ON p.pnr = b.pnr
WHERE j.journey_date BETWEEN '2026-11-13' AND '2026-11-17'
GROUP BY j.train_no, j.journey_date, j.status
ORDER BY j.train_no, j.journey_date
LIMIT 20;

\echo '=== Q02. Berth-km utilisation by train & class, ranked within each train ==='
SELECT train_no, class_code,
       round(avg(utilisation_pct), 1)                                   AS avg_util_pct,
       RANK() OVER (PARTITION BY train_no ORDER BY avg(utilisation_pct) DESC) AS class_rank
FROM v_journey_class_utilisation
WHERE journey_date <= '2026-11-15'                      -- completed runs
GROUP BY train_no, class_code
ORDER BY train_no, class_rank;

\echo '=== Q03. Busiest segment of every train (segment explosion with generate_series) ==='
WITH seg_load AS (
  SELECT j.train_no, g.seg, count(*) AS pax_on_segment
  FROM seat_allocations a
  JOIN journeys j ON j.journey_id = a.journey_id
  CROSS JOIN LATERAL generate_series(lower(a.seg_range), upper(a.seg_range) - 1) AS g(seg)
  WHERE a.is_active AND j.journey_date <= '2026-11-15'
  GROUP BY j.train_no, g.seg
),
ranked AS (
  SELECT s.*, ROW_NUMBER() OVER (PARTITION BY s.train_no ORDER BY s.pax_on_segment DESC) AS rn
  FROM seg_load s
)
SELECT r.train_no, f.station_code || ' -> ' || t.station_code AS busiest_segment, r.pax_on_segment
FROM ranked r
JOIN train_stops f ON f.train_no = r.train_no AND f.stop_seq = r.seg
JOIN train_stops t ON t.train_no = r.train_no AND t.stop_seq = r.seg + 1
WHERE r.rn = 1
ORDER BY r.pax_on_segment DESC;

\echo '=== Q04. Occupancy profile along the route: 12627 Karnataka Express, 3A & SL (avg per run) ==='
WITH runs AS (SELECT count(*) AS n FROM journeys WHERE train_no = '12627' AND journey_date <= '2026-11-15'),
load AS (
  SELECT g.seg, c.class_code, count(*) AS occ
  FROM seat_allocations a
  JOIN journeys j ON j.journey_id = a.journey_id AND j.train_no = '12627' AND j.journey_date <= '2026-11-15'
  JOIN seats s ON s.seat_id = a.seat_id
  JOIN coaches c ON c.coach_id = s.coach_id
  CROSS JOIN LATERAL generate_series(lower(a.seg_range), upper(a.seg_range) - 1) g(seg)
  WHERE a.is_active AND c.class_code IN ('3A','SL')
  GROUP BY g.seg, c.class_code
)
SELECT f.station_code || '-' || t.station_code AS segment,
       round(max(occ) FILTER (WHERE class_code = '3A') / (SELECT n FROM runs)::numeric, 0) AS avg_3a_occupied,
       round(max(occ) FILTER (WHERE class_code = 'SL') / (SELECT n FROM runs)::numeric, 0) AS avg_sl_occupied
FROM load l
JOIN train_stops f ON f.train_no = '12627' AND f.stop_seq = l.seg
JOIN train_stops t ON t.train_no = '12627' AND t.stop_seq = l.seg + 1
GROUP BY l.seg, f.station_code, t.station_code
ORDER BY l.seg;

\echo '=== Q05. Seat fragmentation (gaps & islands): free 1-segment holes nobody can buy end-to-end ==='
-- For every berth on every completed run, find gaps between consecutive occupied
-- ranges; a gap of exactly one segment is a "dead" fragment.
WITH occ AS (
  SELECT a.journey_id, a.seat_id, a.seg_range,
         LAG(upper(a.seg_range)) OVER (PARTITION BY a.journey_id, a.seat_id, a.slot ORDER BY lower(a.seg_range)) AS prev_end
  FROM seat_allocations a
  JOIN journeys j ON j.journey_id = a.journey_id
  WHERE a.is_active AND a.kind = 'CNF' AND j.journey_date <= '2026-11-15'
),
gaps AS (
  SELECT journey_id, seat_id, lower(seg_range) - prev_end AS gap_segments
  FROM occ WHERE prev_end IS NOT NULL AND lower(seg_range) > prev_end
)
SELECT j.train_no,
       count(*)                                        AS internal_gaps,
       count(*) FILTER (WHERE gap_segments = 1)        AS one_segment_holes,
       round(avg(gap_segments), 2)                     AS avg_gap_segments
FROM gaps g JOIN journeys j USING (journey_id)
GROUP BY j.train_no
ORDER BY internal_gaps DESC;

\echo '=== Q06. Unused quota released at chart time (Tatkal / Ladies / Senior berths re-used by GN) ==='
SELECT b.class_code, s.quota_code AS berth_quota, b.quota_code AS passenger_quota, count(*) AS passengers_seated
FROM passenger_status_history h
JOIN passengers p ON p.passenger_id = h.passenger_id
JOIN bookings b ON b.pnr = p.pnr
JOIN seat_allocations a ON a.passenger_id = p.passenger_id AND a.is_active
JOIN seats s ON s.seat_id = a.seat_id
WHERE h.reason = 'CHART_QUOTA_RELEASE' AND h.new_status = 'CNF'
GROUP BY 1, 2, 3
ORDER BY passengers_seated DESC;

-- #############################################################################
-- B. WAITLIST INTELLIGENCE
-- #############################################################################

\echo '=== Q07. Will my waitlist confirm? Final outcome by initial WL number (charted runs) ==='
WITH wl AS (
  SELECT p.passenger_id, b.class_code, p.wl_number,
         -- final outcome: status reached before any user cancellation
         CASE
           WHEN EXISTS (SELECT 1 FROM passenger_status_history h WHERE h.passenger_id = p.passenger_id AND h.new_status = 'CNF') THEN 'CNF'
           WHEN EXISTS (SELECT 1 FROM passenger_status_history h WHERE h.passenger_id = p.passenger_id AND h.new_status = 'RAC') THEN 'RAC'
           ELSE 'NOT CONFIRMED' END AS outcome
  FROM passengers p
  JOIN bookings b ON b.pnr = p.pnr
  JOIN journeys j ON j.journey_id = b.journey_id
  LEFT JOIN cancellations c ON c.passenger_id = p.passenger_id
  WHERE p.booking_status LIKE 'GNWL/%' AND j.status <> 'SCHEDULED'
    AND (c.reason IS DISTINCT FROM 'USER')               -- exclude people who gave up themselves
)
SELECT width_bucket(wl_number, 0, 200, 10)                         AS bucket,
       min(wl_number) || '-' || max(wl_number)                     AS wl_range,
       count(*)                                                    AS passengers,
       round(100.0 * count(*) FILTER (WHERE outcome = 'CNF') / count(*), 1)            AS pct_cnf,
       round(100.0 * count(*) FILTER (WHERE outcome IN ('CNF','RAC')) / count(*), 1)   AS pct_can_board
FROM wl
GROUP BY bucket
ORDER BY bucket;

\echo '=== Q08. WL clearance by train & class: how deep into the queue did confirmations reach? ==='
SELECT j.train_no, b.class_code,
       count(*) FILTER (WHERE p.booking_status LIKE 'GNWL/%')                              AS wl_issued,
       max(p.wl_number) FILTER (WHERE p.booking_status LIKE 'GNWL/%' AND h.new_status = 'CNF') AS deepest_wl_confirmed,
       round(avg(p.wl_number) FILTER (WHERE p.booking_status LIKE 'GNWL/%' AND h.new_status = 'CNF'), 1) AS avg_wl_confirmed
FROM passengers p
JOIN bookings b ON b.pnr = p.pnr
JOIN journeys j ON j.journey_id = b.journey_id AND j.status <> 'SCHEDULED'
LEFT JOIN passenger_status_history h ON h.passenger_id = p.passenger_id AND h.new_status = 'CNF'
GROUP BY j.train_no, b.class_code
HAVING count(*) FILTER (WHERE p.booking_status LIKE 'GNWL/%') > 0
ORDER BY wl_issued DESC
LIMIT 15;

\echo '=== Q09. Time-to-confirm for RAC/WL passengers (median and p90, PERCENTILE_CONT) ==='
WITH firsts AS (
  SELECT h.passenger_id,
         min(h.changed_at) FILTER (WHERE h.reason = 'BOOKED')  AS booked_at,
         min(h.changed_at) FILTER (WHERE h.new_status = 'CNF') AS cnf_at,
         (array_agg(h.new_status ORDER BY h.changed_at))[1]    AS first_status
  FROM passenger_status_history h
  GROUP BY h.passenger_id
)
SELECT first_status,
       count(*)                                                                    AS eventually_confirmed,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY cnf_at - booked_at)             AS median_wait,
       percentile_cont(0.9) WITHIN GROUP (ORDER BY cnf_at - booked_at)             AS p90_wait
FROM firsts
WHERE first_status IN ('RAC','WL') AND cnf_at IS NOT NULL
GROUP BY first_status;

\echo '=== Q10. Most common passenger status journeys (path strings from the audit trail) ==='
WITH paths AS (
  SELECT h.passenger_id, string_agg(h.new_status::text, ' > ' ORDER BY h.changed_at, h.history_id) AS path
  FROM passenger_status_history h
  GROUP BY h.passenger_id
)
SELECT path, count(*) AS passengers, round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM paths
GROUP BY path
ORDER BY passengers DESC
LIMIT 12;

\echo '=== Q11. Split families: live PNRs with mixed statuses or spread across coaches ==='
WITH pnr_state AS (
  SELECT b.pnr, b.pax_count,
         count(DISTINCT p.current_status) FILTER (WHERE p.current_status <> 'CAN') AS distinct_statuses,
         count(DISTINCT s.coach_id)                                                AS coaches_used
  FROM bookings b
  JOIN passengers p ON p.pnr = b.pnr
  LEFT JOIN seat_allocations a ON a.passenger_id = p.passenger_id AND a.is_active AND a.kind = 'CNF'
  LEFT JOIN seats s ON s.seat_id = a.seat_id
  WHERE b.pax_count > 1
  GROUP BY b.pnr, b.pax_count
)
SELECT pax_count,
       count(*)                                                  AS group_pnrs,
       round(100.0 * count(*) FILTER (WHERE distinct_statuses > 1) / count(*), 1) AS pct_mixed_status,
       round(100.0 * count(*) FILTER (WHERE coaches_used > 1) / count(*), 1)      AS pct_split_coaches
FROM pnr_state
GROUP BY pax_count
ORDER BY pax_count;

-- Waitlist-confirmation model: probability that GN waitlist N on train/class reaches CNF
SET client_min_messages = warning;
DROP MATERIALIZED VIEW IF EXISTS mv_wl_confirmation;
SET client_min_messages = notice;
CREATE MATERIALIZED VIEW mv_wl_confirmation AS
WITH wl AS (
  SELECT j.train_no, b.class_code, p.wl_number,
         EXISTS (SELECT 1 FROM passenger_status_history h
                 WHERE h.passenger_id = p.passenger_id AND h.new_status = 'CNF') AS confirmed
  FROM passengers p
  JOIN bookings b ON b.pnr = p.pnr
  JOIN journeys j ON j.journey_id = b.journey_id
  LEFT JOIN cancellations c ON c.passenger_id = p.passenger_id
  WHERE p.booking_status LIKE 'GNWL/%' AND j.status <> 'SCHEDULED'
    AND c.reason IS DISTINCT FROM 'USER'
)
SELECT train_no, class_code, (wl_number - 1) / 10 * 10 + 1 AS wl_from, (wl_number - 1) / 10 * 10 + 10 AS wl_to,
       count(*) AS sample_size, avg(confirmed::int)::numeric(5,3) AS p_confirm
FROM wl
GROUP BY 1, 2, 3, 4;
CREATE UNIQUE INDEX ON mv_wl_confirmation (train_no, class_code, wl_from);

CREATE OR REPLACE FUNCTION predict_confirmation(p_train_no char(5), p_class varchar, p_wl integer)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    (SELECT round(p_confirm * 100) || '% chance (based on ' || sample_size || ' past WL ' || wl_from || '-' || wl_to || ' passengers)'
     FROM rail.mv_wl_confirmation
     WHERE train_no = p_train_no AND class_code = p_class AND p_wl BETWEEN wl_from AND wl_to),
    'no history for this waitlist depth')
$$;

\echo '=== Q12. Predictor in action: chance of confirmation for live waitlisted passengers ==='
SELECT DISTINCT ON (v.train_no, v.class_code)
       v.pnr, v.train_no, v.class_code, v.boarding_date, v.booking_status, v.current_status,
       predict_confirmation(v.train_no, v.class_code, p.wl_number) AS prediction
FROM v_pnr_status v
JOIN passengers p ON p.pnr = v.pnr AND p.passenger_no = v.passenger_no
WHERE v.current_status LIKE 'WL%' AND v.booking_status LIKE 'GNWL/%' AND v.chart_status = 'CHART NOT PREPARED'
ORDER BY v.train_no, v.class_code, p.wl_number DESC;

-- #############################################################################
-- C. DEMAND & REVENUE
-- #############################################################################

\echo '=== Q13. Lost demand: REGRET & unconfirmed attempts, and the revenue they represent ==='
SELECT a.train_no, a.class_code,
       count(*)                                          AS rejected_requests,
       sum(a.pax_count)                                  AS rejected_passengers,
       sum(a.pax_count * compute_fare(a.train_no, a.class_code, a.quota_code,
             (SELECT t.distance_km - f.distance_km FROM train_stops f JOIN train_stops t
                ON t.train_no = f.train_no AND t.station_code = a.to_station
              WHERE f.train_no = a.train_no AND f.station_code = a.from_station))) AS revenue_at_risk
FROM booking_attempts a
WHERE a.outcome IN ('REGRET','NOT_CONFIRMED')
GROUP BY a.train_no, a.class_code
ORDER BY revenue_at_risk DESC
LIMIT 12;

\echo '=== Q14. Top origin-destination pairs by passengers and net revenue ==='
SELECT b.from_station || ' -> ' || b.to_station AS od_pair,
       count(DISTINCT b.pnr)                      AS pnrs,
       count(*) FILTER (WHERE p.current_status <> 'CAN') AS travelling_pax,
       sum(p.fare) - COALESCE(sum(c.refund), 0)   AS net_revenue
FROM bookings b
JOIN passengers p ON p.pnr = b.pnr
LEFT JOIN cancellations c ON c.passenger_id = p.passenger_id
GROUP BY od_pair
ORDER BY net_revenue DESC
LIMIT 12;

\echo '=== Q15. Booking lead time (days before departure) by quota ==='
SELECT b.quota_code,
       CASE WHEN lead_days < 1 THEN '0 (same/prev day)'
            WHEN lead_days < 7 THEN '1-6'
            WHEN lead_days < 15 THEN '7-14'
            WHEN lead_days < 30 THEN '15-29'
            WHEN lead_days < 50 THEN '30-49'
            ELSE '50-60' END                         AS lead_bucket,
       count(*)                                     AS pnrs,
       round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY b.quota_code), 1) AS pct_of_quota
FROM bookings b
CROSS JOIN LATERAL (SELECT EXTRACT(EPOCH FROM stop_time(b.journey_id, b.from_seq) - b.booked_at) / 86400 AS lead_days) l
GROUP BY b.quota_code, lead_bucket
ORDER BY b.quota_code, min(lead_days);

\echo '=== Q16. Tatkal sell-out speed: minutes from window opening until the first Tatkal waitlist ticket ==='
WITH tq AS (
  SELECT b.journey_id, b.class_code, j.train_no,
         ((j.journey_date - 1)
           + CASE WHEN tc.is_ac THEN time '10:00' ELSE time '11:00' END) AT TIME ZONE 'Asia/Kolkata' AS opened_at,
         min(b.booked_at) FILTER (WHERE p.booking_status LIKE 'TQWL/%') AS first_wl_at
  FROM bookings b
  JOIN journeys j ON j.journey_id = b.journey_id
  JOIN travel_classes tc ON tc.class_code = b.class_code
  JOIN passengers p ON p.pnr = b.pnr
  WHERE b.quota_code = 'TQ' AND b.from_seq = 1
  GROUP BY 1, 2, 3, 4
)
SELECT train_no, class_code,
       count(*)                                                                  AS runs,
       count(first_wl_at)                                                        AS runs_sold_out,
       round(avg(EXTRACT(EPOCH FROM first_wl_at - opened_at) / 60)::numeric, 1)  AS avg_minutes_to_sellout
FROM tq
GROUP BY train_no, class_code
HAVING count(first_wl_at) > 0
ORDER BY avg_minutes_to_sellout
LIMIT 12;

\echo '=== Q17. Daily bookings revenue with running total and 7-day moving average ==='
WITH daily AS (
  SELECT (booked_at AT TIME ZONE 'Asia/Kolkata')::date AS booking_day, sum(total_fare) AS gross
  FROM bookings GROUP BY 1
)
SELECT booking_day, gross,
       sum(gross) OVER (ORDER BY booking_day)                                              AS running_total,
       round(avg(gross) OVER (ORDER BY booking_day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 0) AS ma_7d,
       round(100.0 * (gross - LAG(gross, 7) OVER (ORDER BY booking_day)) / NULLIF(LAG(gross, 7) OVER (ORDER BY booking_day), 0), 1) AS wow_pct
FROM daily
ORDER BY booking_day DESC
LIMIT 14;

\echo '=== Q18. Class P&L: gross fare, refunds paid, cancellation income, share of net ==='
SELECT b.class_code,
       sum(p.fare)                                          AS gross_fare,
       COALESCE(sum(c.refund), 0)                           AS refunds_paid,
       COALESCE(sum(c.charge), 0)                           AS cancellation_income,
       sum(p.fare) - COALESCE(sum(c.refund), 0)             AS net_revenue,
       round(100.0 * (sum(p.fare) - COALESCE(sum(c.refund), 0))
             / sum(sum(p.fare) - COALESCE(sum(c.refund), 0)) OVER (), 1) AS pct_of_net
FROM bookings b
JOIN passengers p ON p.pnr = b.pnr
LEFT JOIN cancellations c ON c.passenger_id = p.passenger_id
GROUP BY b.class_code
ORDER BY net_revenue DESC;

\echo '=== Q19. Cancellations: when do people cancel and what does it cost them? ==='
SELECT status_at_cancel, reason,
       CASE WHEN hours_before_dep >= 48 THEN '>48h' WHEN hours_before_dep >= 12 THEN '12-48h'
            WHEN hours_before_dep >= 4 THEN '4-12h' ELSE '<4h' END AS window,
       count(*) AS passengers,
       round(avg(charge), 0) AS avg_charge,
       round(100.0 * sum(refund) / NULLIF(sum(fare), 0), 1) AS pct_refunded
FROM cancellations
GROUP BY 1, 2, 3
ORDER BY 1, 2, min(hours_before_dep) DESC;

\echo '=== Q20. Weekday demand index (journey weekday vs average, from all attempts) ==='
SELECT to_char(journey_date, 'Dy') AS weekday,
       count(*) AS attempts,
       round(count(*) / avg(count(*)) OVER (), 2) AS demand_index,
       round(100.0 * count(*) FILTER (WHERE outcome IN ('REGRET','NOT_CONFIRMED')) / count(*), 1) AS pct_rejected
FROM booking_attempts
GROUP BY EXTRACT(ISODOW FROM journey_date), to_char(journey_date, 'Dy')
ORDER BY EXTRACT(ISODOW FROM journey_date);

-- #############################################################################
-- D. CUSTOMERS, FAIRNESS & ABUSE
-- #############################################################################

\echo '=== Q21. Tatkal power users: bookings within 5 minutes of opening, z-score vs everyone ==='
WITH tq AS (
  SELECT b.user_id, b.booked_at,
         ((j.journey_date - 1)
           + CASE WHEN tc.is_ac THEN time '10:00' ELSE time '11:00' END) AT TIME ZONE 'Asia/Kolkata' AS opened_at
  FROM bookings b
  JOIN journeys j ON j.journey_id = b.journey_id
  JOIN travel_classes tc ON tc.class_code = b.class_code
  WHERE b.quota_code = 'TQ'
),
per_user AS (
  SELECT user_id, count(*) AS tq_bookings,
         count(*) FILTER (WHERE booked_at < opened_at + interval '5 minutes') AS first_5min
  FROM tq GROUP BY user_id
),
scored AS (
  SELECT pu.*, (first_5min - avg(first_5min) OVER ()) / NULLIF(stddev_pop(first_5min) OVER (), 0) AS z
  FROM per_user pu
)
SELECT s.user_id, u.full_name, s.tq_bookings, s.first_5min, round(s.z, 1) AS z_score
FROM scored s JOIN users u USING (user_id)
WHERE s.z > 3
ORDER BY s.z DESC
LIMIT 15;

\echo '=== Q22. Customer value tiers (NTILE on net spend) ==='
WITH spend AS (
  SELECT b.user_id, count(DISTINCT b.pnr) AS pnrs, sum(p.fare) - COALESCE(sum(c.refund), 0) AS net_spend
  FROM bookings b JOIN passengers p ON p.pnr = b.pnr
  LEFT JOIN cancellations c ON c.passenger_id = p.passenger_id
  WHERE b.user_id > 15
  GROUP BY b.user_id
),
tiers AS (SELECT s.*, NTILE(4) OVER (ORDER BY net_spend DESC) AS tier FROM spend s)
SELECT tier, count(*) AS users, round(avg(pnrs), 1) AS avg_pnrs, round(avg(net_spend), 0) AS avg_net_spend,
       round(100.0 * sum(net_spend) / sum(sum(net_spend)) OVER (), 1) AS pct_of_revenue
FROM tiers GROUP BY tier ORDER BY tier;

\echo '=== Q23. Berth preference fulfilment, and lower berths for seniors / women 45+ ==='
SELECT b.class_code,
       round(100.0 * count(*) FILTER (WHERE p.berth_pref IS NOT NULL AND s.berth_type = p.berth_pref)
             / NULLIF(count(*) FILTER (WHERE p.berth_pref IS NOT NULL), 0), 1) AS pct_pref_met,
       round(100.0 * count(*) FILTER (WHERE wants_lower(p.age, p.gender) AND s.berth_type IN ('LB','SL'))
             / NULLIF(count(*) FILTER (WHERE wants_lower(p.age, p.gender)), 0), 1) AS pct_seniors_on_lower,
       round(100.0 * count(*) FILTER (WHERE NOT wants_lower(p.age, p.gender) AND s.berth_type IN ('LB','SL'))
             / NULLIF(count(*) FILTER (WHERE NOT wants_lower(p.age, p.gender)), 0), 1) AS pct_others_on_lower
FROM passengers p
JOIN bookings b ON b.pnr = p.pnr
JOIN seat_allocations a ON a.passenger_id = p.passenger_id AND a.is_active AND a.kind = 'CNF'
JOIN seats s ON s.seat_id = a.seat_id
WHERE b.class_code IN ('1A','2A','3A','SL')
GROUP BY b.class_code
ORDER BY b.class_code;

\echo '=== Q24. Channel mix and outcome by channel ==='
SELECT b.channel, count(DISTINCT b.pnr) AS pnrs,
       round(100.0 * count(DISTINCT b.pnr) / sum(count(DISTINCT b.pnr)) OVER (), 1) AS pct_pnrs,
       round(100.0 * count(*) FILTER (WHERE p.booking_status LIKE 'CNF%') / count(*), 1) AS pct_cnf_at_booking
FROM bookings b JOIN passengers p ON p.pnr = b.pnr
GROUP BY b.channel ORDER BY pnrs DESC;

-- #############################################################################
-- E. DATA INTEGRITY AUDITS (should all return zero rows / zero counts)
-- #############################################################################

\echo '=== Q25. Double-booking audit (self-join on overlapping ranges) ==='
SELECT count(*) AS overlapping_pairs
FROM seat_allocations a
JOIN seat_allocations b
  ON a.journey_id = b.journey_id AND a.seat_id = b.seat_id AND a.slot = b.slot
 AND a.allocation_id < b.allocation_id AND a.seg_range && b.seg_range
WHERE a.is_active AND b.is_active;

\echo '=== Q26. Status / allocation consistency ==='
SELECT
  (SELECT count(*) FROM passengers p WHERE p.current_status IN ('CNF','RAC')
     AND NOT EXISTS (SELECT 1 FROM seat_allocations a WHERE a.passenger_id = p.passenger_id AND a.is_active
                     AND a.kind::text = p.current_status::text))                         AS seated_without_allocation,
  (SELECT count(*) FROM passengers p WHERE p.current_status IN ('WL','CAN')
     AND EXISTS (SELECT 1 FROM seat_allocations a WHERE a.passenger_id = p.passenger_id AND a.is_active)) AS unseated_holding_berth,
  (SELECT count(*) FROM passengers p WHERE p.current_status = 'CAN'
     AND NOT EXISTS (SELECT 1 FROM cancellations c WHERE c.passenger_id = p.passenger_id))  AS cancelled_without_refund_row,
  (SELECT count(*) FROM bookings b WHERE b.total_fare <> (SELECT sum(fare) FROM passengers p WHERE p.pnr = b.pnr)) AS fare_mismatch;
