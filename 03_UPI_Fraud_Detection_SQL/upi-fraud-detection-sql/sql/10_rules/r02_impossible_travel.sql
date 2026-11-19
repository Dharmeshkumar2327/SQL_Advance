/* =============================================================================
   R02 - IMPOSSIBLE TRAVEL
   Pattern : the same account pays from Delhi and, 20 minutes later, from
             Chennai. Nobody travels at 6,000 km/h - credentials are compromised.
   Logic   : LAG() gives the previous payment of the same account; join both
             cities to get coordinates; haversine distance / time = speed.
             Tuning: GPS / IP geolocation is noisy, so with require_device_change = 1
             the jump only counts if the device ALSO changed. See
             sql/60_experiments/01_rule_tuning_r02.sql for the before/after numbers.
   SQL     : LAG window function, custom IMMUTABLE function, multi-join
   ============================================================================= */
\echo '  R02 impossible travel'
SELECT clock_timestamp()::timestamp AS t0 \gset

DELETE FROM fraud.rule_hits WHERE rule_code = 'R02';

WITH ordered AS (
    SELECT
        t.txn_id,
        t.payer_account_id,
        t.txn_ts,
        t.txn_city,
        t.device_id,
        LAG(t.device_id) OVER w AS prev_device_id,
        LAG(t.txn_id)   OVER w AS prev_txn_id,
        LAG(t.txn_ts)   OVER w AS prev_ts,
        LAG(t.txn_city) OVER w AS prev_city
    FROM upi.transactions t
    WHERE t.status = 'SUCCESS'
    WINDOW w AS (PARTITION BY t.payer_account_id ORDER BY t.txn_ts, t.txn_id)
),
moves AS (
    SELECT
        o.*,
        fraud.haversine_km(c1.latitude, c1.longitude, c2.latitude, c2.longitude) AS distance_km,
        EXTRACT(EPOCH FROM (o.txn_ts - o.prev_ts)) / 3600.0                      AS hours_apart
    FROM ordered o
    JOIN upi.cities c1 ON c1.city = o.prev_city
    JOIN upi.cities c2 ON c2.city = o.txn_city
    WHERE o.prev_city IS NOT NULL
      AND o.prev_city <> o.txn_city
)
INSERT INTO fraud.rule_hits (txn_id, account_id, rule_code, evidence)
SELECT
    txn_id,
    payer_account_id,
    'R02',
    jsonb_build_object(
        'from_city',          prev_city,
        'to_city',            txn_city,
        'previous_txn_id',    prev_txn_id,
        'device_changed',     device_id <> prev_device_id,
        'distance_km',        ROUND(distance_km),
        'minutes_apart',      ROUND((hours_apart * 60)::NUMERIC, 1),
        'implied_speed_kmph', ROUND(distance_km / GREATEST(hours_apart, 1 / 60.0))
    )
FROM moves
WHERE distance_km >= fraud.param('R02', 'min_distance_km')
  AND distance_km / GREATEST(hours_apart, 1 / 60.0) >= fraud.param('R02', 'max_speed_kmph')
  AND (fraud.param('R02', 'require_device_change') = 0 OR device_id <> prev_device_id)
  AND fraud.is_active('R02');

SELECT fraud.log_step('R02', (SELECT COUNT(*) FROM fraud.rule_hits WHERE rule_code = 'R02'), :'t0') AS logged \gset
