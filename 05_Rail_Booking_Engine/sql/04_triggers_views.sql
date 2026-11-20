-- =============================================================================
-- 04_triggers_views.sql
-- Defence in depth (state machine + immutability triggers), audit trail,
-- and the read-side views used by apps and analysts.
-- =============================================================================
\set ON_ERROR_STOP on
SET search_path = rail, public;

-- -----------------------------------------------------------------------------
-- Passenger status state machine
--   WL  -> RAC | CNF | CAN
--   RAC -> CNF | CAN
--   CNF -> CAN
--   CAN -> (terminal)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_passenger_status_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.current_status = OLD.current_status THEN RETURN NEW; END IF;
  IF NOT (
       (OLD.current_status = 'WL'  AND NEW.current_status IN ('RAC','CNF','CAN'))
    OR (OLD.current_status = 'RAC' AND NEW.current_status IN ('CNF','CAN'))
    OR (OLD.current_status = 'CNF' AND NEW.current_status = 'CAN')
  ) THEN
    RAISE EXCEPTION 'Illegal status transition % -> % for passenger %',
      OLD.current_status, NEW.current_status, OLD.passenger_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER passenger_status_guard
BEFORE UPDATE OF current_status ON passengers
FOR EACH ROW EXECUTE FUNCTION trg_passenger_status_guard();

-- -----------------------------------------------------------------------------
-- Audit trail: every status a passenger ever had, with reason and business time
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_passenger_status_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO rail.passenger_status_history (passenger_id, old_status, new_status, status_label, reason, changed_at)
    VALUES (NEW.passenger_id, NULL, NEW.current_status, NEW.booking_status, 'BOOKED', rail.app_now());
  ELSIF NEW.current_status IS DISTINCT FROM OLD.current_status THEN
    INSERT INTO rail.passenger_status_history (passenger_id, old_status, new_status, status_label, reason, changed_at)
    VALUES (NEW.passenger_id, OLD.current_status, NEW.current_status,
            CASE NEW.current_status
              WHEN 'RAC' THEN 'RAC/' || NEW.rac_number
              WHEN 'CNF' THEN 'CNF/' || COALESCE((SELECT rail.seat_label(a.seat_id) FROM rail.seat_allocations a
                                                  WHERE a.passenger_id = NEW.passenger_id AND a.is_active), '?')
              ELSE NEW.current_status::text END,
            COALESCE(NULLIF(current_setting('rail.status_reason', true), ''), 'MANUAL'),
            rail.app_now());
  END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER passenger_status_audit
AFTER INSERT OR UPDATE OF current_status ON passengers
FOR EACH ROW EXECUTE FUNCTION trg_passenger_status_audit();

-- -----------------------------------------------------------------------------
-- Bookings are immutable on the fields that define the journey
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_booking_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.pnr, NEW.journey_id, NEW.class_code, NEW.quota_code, NEW.from_seq, NEW.to_seq,
      NEW.from_station, NEW.to_station, NEW.user_id, NEW.booked_at)
     IS DISTINCT FROM
     (OLD.pnr, OLD.journey_id, OLD.class_code, OLD.quota_code, OLD.from_seq, OLD.to_seq,
      OLD.from_station, OLD.to_station, OLD.user_id, OLD.booked_at) THEN
    RAISE EXCEPTION 'Booking % is immutable: cancel and re-book instead', OLD.pnr;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER booking_immutable
BEFORE UPDATE ON bookings
FOR EACH ROW EXECUTE FUNCTION trg_booking_immutable();

-- No booking can be inserted into a journey whose chart is out (even bypassing book_ticket)
CREATE OR REPLACE FUNCTION trg_booking_journey_open() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT status FROM rail.journeys WHERE journey_id = NEW.journey_id) <> 'SCHEDULED' THEN
    RAISE EXCEPTION 'Journey % is closed for booking', NEW.journey_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER booking_journey_open
BEFORE INSERT ON bookings
FOR EACH ROW EXECUTE FUNCTION trg_booking_journey_open();

-- Seat allocations are an append-only ledger: rows can only be released, never edited or revived
CREATE OR REPLACE FUNCTION trg_allocation_ledger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'seat_allocations is append-only';
  END IF;
  IF (NEW.journey_id, NEW.seat_id, NEW.passenger_id, NEW.kind, NEW.slot, NEW.seg_range, NEW.allocated_at)
     IS DISTINCT FROM
     (OLD.journey_id, OLD.seat_id, OLD.passenger_id, OLD.kind, OLD.slot, OLD.seg_range, OLD.allocated_at)
     OR (NOT OLD.is_active AND NEW.is_active) THEN
    RAISE EXCEPTION 'Allocation % can only be released, not modified', OLD.allocation_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER allocation_ledger
BEFORE UPDATE OR DELETE ON seat_allocations
FOR EACH ROW EXECUTE FUNCTION trg_allocation_ledger();

-- -----------------------------------------------------------------------------
-- Views
-- -----------------------------------------------------------------------------

-- Live queue position (what the passenger sees as "WL 12" today)
CREATE OR REPLACE VIEW v_queue_position AS
SELECT p.passenger_id, b.journey_id, b.class_code, b.quota_code, p.current_status,
       ROW_NUMBER() OVER (PARTITION BY b.journey_id, b.class_code, b.quota_code, p.current_status
                          ORDER BY CASE p.current_status WHEN 'WL' THEN p.wl_number ELSE p.rac_number END) AS position
FROM passengers p
JOIN bookings b ON b.pnr = p.pnr
WHERE p.current_status IN ('WL','RAC');

-- PNR enquiry: booking-time status vs current status, like the IRCTC PNR page
CREATE OR REPLACE VIEW v_pnr_status AS
SELECT b.pnr,
       t.train_no, t.train_name,
       j.journey_date + fs.day_offset                     AS boarding_date,
       b.from_station, b.to_station, b.class_code, b.quota_code,
       p.passenger_no, p.full_name, p.age, p.gender,
       p.booking_status,
       CASE p.current_status
         WHEN 'CNF' THEN 'CNF/' || seat_label(a.seat_id)
         WHEN 'RAC' THEN CASE WHEN j.status = 'SCHEDULED' THEN 'RAC ' || q.position
                              ELSE 'RAC/' || seat_label(a.seat_id) END
         WHEN 'WL'  THEN 'WL ' || q.position
         ELSE 'CAN'
       END                                                AS current_status,
       p.fare,
       CASE j.status WHEN 'SCHEDULED' THEN 'CHART NOT PREPARED' ELSE j.status::text END AS chart_status
FROM bookings b
JOIN journeys j      ON j.journey_id = b.journey_id
JOIN trains t        ON t.train_no = j.train_no
JOIN train_stops fs  ON fs.train_no = t.train_no AND fs.stop_seq = b.from_seq
JOIN passengers p    ON p.pnr = b.pnr
LEFT JOIN seat_allocations a ON a.passenger_id = p.passenger_id AND a.is_active
LEFT JOIN v_queue_position q ON q.passenger_id = p.passenger_id;

-- Per journey & class: berth-km sold vs berth-km offered ("seat-km utilisation")
CREATE OR REPLACE VIEW v_journey_class_utilisation AS
WITH route AS (
  SELECT train_no, MAX(distance_km) AS route_km FROM train_stops GROUP BY train_no
),
capacity AS (
  SELECT c.train_no, c.class_code, count(*) FILTER (WHERE NOT s.is_rac_berth) AS berths,
         count(*) FILTER (WHERE s.is_rac_berth) AS rac_berths
  FROM coaches c JOIN seats s USING (coach_id) GROUP BY c.train_no, c.class_code
),
sold AS (
  SELECT a.journey_id, c.class_code,
         SUM(CASE WHEN a.kind = 'CNF' THEN te.distance_km - tf.distance_km ELSE (te.distance_km - tf.distance_km) / 2.0 END) AS berth_km
  FROM seat_allocations a
  JOIN seats s       ON s.seat_id = a.seat_id
  JOIN coaches c     ON c.coach_id = s.coach_id
  JOIN train_stops tf ON tf.train_no = c.train_no AND tf.stop_seq = lower(a.seg_range)
  JOIN train_stops te ON te.train_no = c.train_no AND te.stop_seq = upper(a.seg_range)
  WHERE a.is_active
  GROUP BY a.journey_id, c.class_code
)
SELECT j.journey_id, j.train_no, j.journey_date, cap.class_code, cap.berths, cap.rac_berths,
       r.route_km,
       COALESCE(sd.berth_km, 0)                                              AS berth_km_sold,
       (cap.berths + cap.rac_berths) * r.route_km                            AS berth_km_offered,
       ROUND(100.0 * COALESCE(sd.berth_km, 0) / NULLIF((cap.berths + cap.rac_berths) * r.route_km, 0), 1) AS utilisation_pct
FROM journeys j
JOIN capacity cap ON cap.train_no = j.train_no
JOIN route r      ON r.train_no = j.train_no
LEFT JOIN sold sd ON sd.journey_id = j.journey_id AND sd.class_code = cap.class_code;
