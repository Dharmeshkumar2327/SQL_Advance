-- Fixture for the concurrency test (runs in a throw-away copy of the database)
\set ON_ERROR_STOP on
SET search_path = rail, public;

DO $$ BEGIN
  EXECUTE format('ALTER DATABASE %I SET rail.now = %L', current_database(), '2026-11-15 23:00:00+05:30');
END $$;

INSERT INTO trains VALUES ('99998', 'Race Test Express', 'SUPERFAST', '{1,2,3,4,5,6,7}', true);
INSERT INTO train_stops VALUES
  ('99998', 1, 'NDLS', NULL, '06:00', 0, 0),
  ('99998', 2, 'BPL', '13:00', NULL, 0, 702);
INSERT INTO coaches (train_no, coach_no, class_code, position) VALUES ('99998', 'S1', 'SL', 1);
-- 10 normal berths + 1 RAC side-lower (2 RAC places)
INSERT INTO seats (coach_id, berth_no, berth_type, is_rac_berth)
SELECT c.coach_id, b, (CASE WHEN b = 11 THEN 'SL' ELSE 'LB' END)::berth_type, b = 11
FROM coaches c, generate_series(1, 11) b WHERE c.train_no = '99998';
INSERT INTO journeys (train_no, journey_date) VALUES ('99998', '2026-11-30');
INSERT INTO journey_inventory (journey_id, class_code, quota_code)
SELECT journey_id, 'SL', 'GN' FROM journeys WHERE train_no = '99998';
UPDATE travel_classes SET max_waitlist = 20 WHERE class_code = 'SL';

CREATE TABLE race_results (client_pid int, outcome text, label text, at timestamptz DEFAULT clock_timestamp());

CREATE FUNCTION race_try_book() RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_label text; v_state text;
BEGIN
  PERFORM pg_sleep(random() * 0.005);            -- jitter so clients collide
  SELECT status_label INTO v_label
  FROM rail.book_ticket(16 + (random() * 3000)::int, '99998', '2026-11-30', 'NDLS', 'BPL', 'SL', 'GN',
                        '[{"name":"Racer","age":30,"gender":"M"}]');
  INSERT INTO rail.race_results (client_pid, outcome, label) VALUES (pg_backend_pid(), split_part(v_label, '/', 1), v_label);
EXCEPTION WHEN SQLSTATE 'RL001' THEN
  INSERT INTO rail.race_results (client_pid, outcome) VALUES (pg_backend_pid(), 'REGRET');
END $$;
