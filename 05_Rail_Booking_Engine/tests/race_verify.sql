\set ON_ERROR_STOP on
SET search_path = rail, public;
\echo 'Outcome of the race:'
SELECT outcome, count(*) FROM race_results GROUP BY outcome ORDER BY outcome;

DO $$
DECLARE n_total int; n_cnf int; n_rac int; n_wl int; n_regret int; n_seats int; n_overlap int; wl_ok boolean;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE outcome = 'CNF'), count(*) FILTER (WHERE outcome = 'RAC'),
         count(*) FILTER (WHERE outcome = 'GNWL'), count(*) FILTER (WHERE outcome = 'REGRET')
    INTO n_total, n_cnf, n_rac, n_wl, n_regret FROM race_results;

  SELECT count(DISTINCT a.seat_id) INTO n_seats
  FROM seat_allocations a JOIN journeys j USING (journey_id)
  WHERE j.train_no = '99998' AND a.is_active AND a.kind = 'CNF';

  SELECT count(*) INTO n_overlap
  FROM seat_allocations a JOIN seat_allocations b
    ON a.journey_id = b.journey_id AND a.seat_id = b.seat_id AND a.slot = b.slot
   AND a.allocation_id < b.allocation_id AND a.seg_range && b.seg_range AND a.is_active AND b.is_active;

  -- waitlist tickets must be exactly 1..n with no gaps or duplicates
  SELECT min(wl_number) = 1 AND max(wl_number) = count(*) AND count(DISTINCT wl_number) = count(*)
    INTO wl_ok
  FROM passengers p JOIN bookings b USING (pnr) JOIN journeys j USING (journey_id)
  WHERE j.train_no = '99998' AND p.wl_number IS NOT NULL;

  RAISE NOTICE 'clients=% cnf=% rac=% wl=% regret=% distinct_cnf_berths=% overlaps=%',
    n_total, n_cnf, n_rac, n_wl, n_regret, n_seats, n_overlap;

  IF n_cnf <> 10 OR n_seats <> 10 THEN RAISE EXCEPTION 'FAIL: expected exactly 10 confirmed on 10 distinct berths'; END IF;
  IF n_rac <> 2  THEN RAISE EXCEPTION 'FAIL: expected exactly 2 RAC'; END IF;
  IF n_wl  <> 20 THEN RAISE EXCEPTION 'FAIL: expected exactly 20 waitlisted (cap)'; END IF;
  IF n_regret <> n_total - 32 THEN RAISE EXCEPTION 'FAIL: everyone else must get REGRET'; END IF;
  IF n_overlap <> 0 THEN RAISE EXCEPTION 'FAIL: double booking detected'; END IF;
  IF NOT wl_ok THEN RAISE EXCEPTION 'FAIL: waitlist numbers not contiguous'; END IF;
  RAISE NOTICE 'PASS  concurrency: no double booking, no lost or duplicate WL numbers';
END $$;
