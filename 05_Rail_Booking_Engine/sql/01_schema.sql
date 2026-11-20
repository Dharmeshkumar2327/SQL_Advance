-- =============================================================================
-- 01_schema.sql
-- Core data model: network (stations, trains, stops), rolling stock (coaches,
-- seats), runs (journeys + inventory locks), customers, bookings, passengers,
-- seat allocations, cancellations and audit history.
-- =============================================================================
\set ON_ERROR_STOP on
SET search_path = rail, public;

-- -----------------------------------------------------------------------------
-- Enumerated types
-- -----------------------------------------------------------------------------
CREATE TYPE passenger_status AS ENUM ('CNF', 'RAC', 'WL', 'CAN');
CREATE TYPE journey_status   AS ENUM ('SCHEDULED', 'CHART_PREPARED', 'DEPARTED', 'CANCELLED');
-- LB/MB/UB = lower/middle/upper berth, SL/SU = side lower/side upper,
-- WS/MS/AS = window/middle/aisle seat (chair cars)
CREATE TYPE berth_type       AS ENUM ('LB', 'MB', 'UB', 'SL', 'SU', 'WS', 'MS', 'AS');
CREATE TYPE allocation_kind  AS ENUM ('CNF', 'RAC');

-- -----------------------------------------------------------------------------
-- Network
-- -----------------------------------------------------------------------------
CREATE TABLE stations (
    station_code  varchar(5)  PRIMARY KEY CHECK (station_code ~ '^[A-Z]{1,5}$'),
    station_name  text        NOT NULL,
    city          text        NOT NULL,
    state         text        NOT NULL,
    zone          varchar(4)  NOT NULL
);

CREATE TABLE train_types (
    train_type        text PRIMARY KEY,
    is_superfast      boolean NOT NULL,       -- attracts superfast surcharge
    fare_multiplier   numeric(4,2) NOT NULL CHECK (fare_multiplier > 0),
    catering_included boolean NOT NULL DEFAULT false
);

CREATE TABLE trains (
    train_no     char(5)     PRIMARY KEY CHECK (train_no ~ '^[0-9]{5}$'),
    train_name   text        NOT NULL,
    train_type   text        NOT NULL REFERENCES train_types,
    runs_on      smallint[]  NOT NULL                       -- ISO day of week, 1 = Monday
                 CHECK (runs_on <@ ARRAY[1,2,3,4,5,6,7]::smallint[] AND cardinality(runs_on) > 0),
    is_active    boolean     NOT NULL DEFAULT true
);

CREATE TABLE train_stops (
    train_no        char(5)     NOT NULL REFERENCES trains ON DELETE CASCADE,
    stop_seq        smallint    NOT NULL CHECK (stop_seq >= 1),
    station_code    varchar(5)  NOT NULL REFERENCES stations,
    arrival_time    time,                                   -- NULL at origin
    departure_time  time,                                   -- NULL at destination
    day_offset      smallint    NOT NULL DEFAULT 0 CHECK (day_offset BETWEEN 0 AND 3),
    distance_km     integer     NOT NULL CHECK (distance_km >= 0),
    PRIMARY KEY (train_no, stop_seq),
    UNIQUE (train_no, station_code),
    CHECK (arrival_time IS NOT NULL OR departure_time IS NOT NULL)
);
CREATE INDEX ix_train_stops_station ON train_stops (station_code, train_no);

-- -----------------------------------------------------------------------------
-- Classes, quotas, fare rules
-- -----------------------------------------------------------------------------
CREATE TABLE travel_classes (
    class_code            varchar(2) PRIMARY KEY,
    class_name            text       NOT NULL,
    is_ac                 boolean    NOT NULL,
    has_berths            boolean    NOT NULL,
    display_order         smallint   NOT NULL,
    seats_per_coach       smallint   NOT NULL CHECK (seats_per_coach > 0),
    rac_berths_per_coach  smallint   NOT NULL DEFAULT 0,  -- side-lowers shared by 2 RAC passengers
    tatkal_per_coach      smallint   NOT NULL DEFAULT 0,
    max_waitlist          integer    NOT NULL,            -- beyond this => REGRET
    fare_per_km           numeric(6,3) NOT NULL,
    reservation_charge    numeric(6,2) NOT NULL,
    superfast_charge      numeric(6,2) NOT NULL,
    tatkal_pct            numeric(4,2) NOT NULL,          -- % of base fare
    tatkal_min            numeric(6,2) NOT NULL,
    tatkal_max            numeric(6,2) NOT NULL,
    catering_charge       numeric(6,2) NOT NULL DEFAULT 0,
    cancel_flat_charge    numeric(6,2) NOT NULL           -- min deduction for CNF cancellation
);

CREATE TABLE quotas (
    quota_code   varchar(2) PRIMARY KEY,
    quota_name   text NOT NULL,
    allows_rac   boolean NOT NULL,
    allows_wl    boolean NOT NULL,
    max_pax      smallint NOT NULL
);

-- Global tunables (single source of truth for business rules)
CREATE TABLE rules (
    rule_key   text PRIMARY KEY,
    rule_value text NOT NULL,
    note       text
);

-- -----------------------------------------------------------------------------
-- Rolling stock: coach composition per train, seat map per coach
-- -----------------------------------------------------------------------------
CREATE TABLE coaches (
    coach_id    serial      PRIMARY KEY,
    train_no    char(5)     NOT NULL REFERENCES trains ON DELETE CASCADE,
    coach_no    varchar(4)  NOT NULL,                 -- e.g. S1, B3, A1, H1, C2
    class_code  varchar(2)  NOT NULL REFERENCES travel_classes,
    position    smallint    NOT NULL,                 -- order in the rake
    UNIQUE (train_no, coach_no)
);
CREATE INDEX ix_coaches_train_class ON coaches (train_no, class_code);

CREATE TABLE seats (
    seat_id       serial      PRIMARY KEY,
    coach_id      integer     NOT NULL REFERENCES coaches ON DELETE CASCADE,
    berth_no      smallint    NOT NULL CHECK (berth_no > 0),
    berth_type    berth_type  NOT NULL,
    quota_code    varchar(2)  NOT NULL DEFAULT 'GN' REFERENCES quotas,
    is_rac_berth  boolean     NOT NULL DEFAULT false,
    UNIQUE (coach_id, berth_no),
    CHECK (NOT is_rac_berth OR berth_type = 'SL')     -- only side-lowers are shared under RAC
);
CREATE INDEX ix_seats_coach_quota ON seats (coach_id, quota_code, is_rac_berth);

-- -----------------------------------------------------------------------------
-- Runs of a train (one row per train per origin date) and inventory locks
-- -----------------------------------------------------------------------------
CREATE TABLE journeys (
    journey_id         bigserial       PRIMARY KEY,
    train_no           char(5)         NOT NULL REFERENCES trains,
    journey_date       date            NOT NULL,           -- departure date from ORIGIN
    status             journey_status  NOT NULL DEFAULT 'SCHEDULED',
    chart_prepared_at  timestamptz,
    UNIQUE (train_no, journey_date),
    CHECK ((status = 'SCHEDULED') = (chart_prepared_at IS NULL) OR status = 'CANCELLED')
);

-- One row per journey x class x quota. Booking/cancellation/promotion code takes
-- a row lock here (SELECT ... FOR UPDATE), which serialises all writers that touch
-- the same pool while leaving other pools / trains fully concurrent.
CREATE TABLE journey_inventory (
    journey_id   bigint      NOT NULL REFERENCES journeys ON DELETE CASCADE,
    class_code   varchar(2)  NOT NULL REFERENCES travel_classes,
    quota_code   varchar(2)  NOT NULL REFERENCES quotas,
    wl_counter   integer     NOT NULL DEFAULT 0,   -- last WL ticket number issued
    rac_counter  integer     NOT NULL DEFAULT 0,   -- last RAC ticket number issued
    PRIMARY KEY (journey_id, class_code, quota_code)
);

-- -----------------------------------------------------------------------------
-- Customers & bookings
-- -----------------------------------------------------------------------------
CREATE TABLE users (
    user_id     serial       PRIMARY KEY,
    full_name   text         NOT NULL,
    email       text         NOT NULL UNIQUE CHECK (email ~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$'),
    phone       char(10)     NOT NULL CHECK (phone ~ '^[6-9][0-9]{9}$'),
    gender      char(1)      NOT NULL CHECK (gender IN ('M','F','T')),
    created_at  timestamptz  NOT NULL DEFAULT now()
);

CREATE SEQUENCE pnr_seq START 100001;

CREATE TABLE bookings (
    pnr           char(10)     PRIMARY KEY CHECK (pnr ~ '^[0-9]{10}$'),
    user_id       integer      NOT NULL REFERENCES users,
    journey_id    bigint       NOT NULL REFERENCES journeys,
    class_code    varchar(2)   NOT NULL REFERENCES travel_classes,
    quota_code    varchar(2)   NOT NULL REFERENCES quotas,
    from_seq      smallint     NOT NULL,
    to_seq        smallint     NOT NULL,
    from_station  varchar(5)   NOT NULL REFERENCES stations,
    to_station    varchar(5)   NOT NULL REFERENCES stations,
    distance_km   integer      NOT NULL CHECK (distance_km > 0),
    pax_count     smallint     NOT NULL CHECK (pax_count BETWEEN 1 AND 6),
    total_fare    numeric(10,2) NOT NULL CHECK (total_fare >= 0),
    channel       text         NOT NULL DEFAULT 'WEB' CHECK (channel IN ('WEB','APP','COUNTER','AGENT')),
    booked_at     timestamptz  NOT NULL,
    CHECK (from_seq < to_seq),
    FOREIGN KEY (journey_id, class_code, quota_code) REFERENCES journey_inventory
);
CREATE INDEX ix_bookings_journey ON bookings (journey_id, class_code, quota_code);
CREATE INDEX ix_bookings_user    ON bookings (user_id, booked_at);

CREATE TABLE passengers (
    passenger_id     bigserial         PRIMARY KEY,
    pnr              char(10)          NOT NULL REFERENCES bookings ON DELETE CASCADE,
    passenger_no     smallint          NOT NULL CHECK (passenger_no BETWEEN 1 AND 6),
    full_name        text              NOT NULL,
    age              smallint          NOT NULL CHECK (age BETWEEN 5 AND 125),
    gender           char(1)           NOT NULL CHECK (gender IN ('M','F','T')),
    berth_pref       berth_type,
    booking_status   text              NOT NULL,   -- status label at booking time, frozen (e.g. 'WL/23')
    current_status   passenger_status  NOT NULL,
    wl_number        integer,                      -- queue ticket; current position is computed
    rac_number       integer,
    fare             numeric(10,2)     NOT NULL CHECK (fare >= 0),
    UNIQUE (pnr, passenger_no),
    CHECK (current_status <> 'WL'  OR wl_number  IS NOT NULL),
    CHECK (current_status <> 'RAC' OR rac_number IS NOT NULL)
);
CREATE INDEX ix_passengers_pnr ON passengers (pnr);

-- -----------------------------------------------------------------------------
-- Seat allocations: the heart of the engine.
-- A passenger travelling stop 3 -> stop 7 occupies segments [3,7) of the route.
-- Two allocations on the same seat (and same RAC slot) on the same journey may
-- never overlap. Enforced by the database itself, not just application code.
-- -----------------------------------------------------------------------------
CREATE TABLE seat_allocations (
    allocation_id  bigserial        PRIMARY KEY,
    journey_id     bigint           NOT NULL REFERENCES journeys,
    seat_id        integer          NOT NULL REFERENCES seats,
    passenger_id   bigint           NOT NULL REFERENCES passengers ON DELETE CASCADE,
    kind           allocation_kind  NOT NULL,
    slot           smallint         NOT NULL DEFAULT 1 CHECK (slot IN (1,2)),  -- RAC berths have 2 slots
    seg_range      int4range        NOT NULL CHECK (NOT isempty(seg_range)),
    is_active      boolean          NOT NULL DEFAULT true,
    allocated_at   timestamptz      NOT NULL,
    released_at    timestamptz,
    CHECK (kind = 'RAC' OR slot = 1),
    CHECK (is_active = (released_at IS NULL)),
    CONSTRAINT no_double_booking EXCLUDE USING gist (
        journey_id WITH =,
        seat_id    WITH =,
        slot       WITH =,
        seg_range  WITH &&
    ) WHERE (is_active)
);
-- a passenger holds at most one live allocation
CREATE UNIQUE INDEX ux_alloc_one_active_per_passenger ON seat_allocations (passenger_id) WHERE is_active;
CREATE INDEX ix_alloc_journey ON seat_allocations (journey_id) WHERE is_active;

-- -----------------------------------------------------------------------------
-- Cancellations, refunds and audit trail
-- -----------------------------------------------------------------------------
CREATE TABLE cancellations (
    cancellation_id   bigserial         PRIMARY KEY,
    passenger_id      bigint            NOT NULL UNIQUE REFERENCES passengers,
    pnr               char(10)          NOT NULL REFERENCES bookings,
    status_at_cancel  passenger_status  NOT NULL CHECK (status_at_cancel <> 'CAN'),
    reason            text              NOT NULL CHECK (reason IN ('USER','CHART_AUTO','TRAIN_CANCELLED')),
    hours_before_dep  numeric(8,2)      NOT NULL,
    fare              numeric(10,2)     NOT NULL,
    charge            numeric(10,2)     NOT NULL CHECK (charge >= 0),
    refund            numeric(10,2)     NOT NULL CHECK (refund >= 0),
    cancelled_at      timestamptz       NOT NULL,
    CHECK (charge + refund = fare)
);
CREATE INDEX ix_cancellations_pnr ON cancellations (pnr);

CREATE TABLE passenger_status_history (
    history_id     bigserial         PRIMARY KEY,
    passenger_id   bigint            NOT NULL REFERENCES passengers ON DELETE CASCADE,
    old_status     passenger_status,
    new_status     passenger_status  NOT NULL,
    status_label   text,
    reason         text,
    changed_at     timestamptz       NOT NULL
);
CREATE INDEX ix_history_passenger ON passenger_status_history (passenger_id, changed_at);

-- Every booking attempt, including rejected ones (REGRET, window closed ...).
-- Rejected demand is invisible in `bookings`, but it is what capacity planning needs.
CREATE TABLE booking_attempts (
    attempt_id    bigserial    PRIMARY KEY,
    user_id       integer      REFERENCES users,
    train_no      char(5),
    journey_date  date,
    from_station  varchar(5),
    to_station    varchar(5),
    class_code    varchar(2),
    quota_code    varchar(2),
    pax_count     smallint,
    attempted_at  timestamptz  NOT NULL,
    outcome       text         NOT NULL,   -- BOOKED | REGRET | NOT_CONFIRMED | WINDOW_CLOSED | INVALID
    pnr           char(10),
    message       text
);
CREATE INDEX ix_attempts_outcome ON booking_attempts (outcome, train_no, journey_date);
