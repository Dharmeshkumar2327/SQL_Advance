/* =============================================================================
   04_helper_functions.sql
   Small reusable SQL functions used by the rules.
   ============================================================================= */

-- Great-circle distance between two points, in kilometres
CREATE OR REPLACE FUNCTION fraud.haversine_km(
    lat1 NUMERIC, lon1 NUMERIC, lat2 NUMERIC, lon2 NUMERIC
) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT (2 * 6371 * asin(sqrt(
               power(sin(radians(lat2 - lat1) / 2), 2) +
               cos(radians(lat1)) * cos(radians(lat2)) *
               power(sin(radians(lon2 - lon1) / 2), 2)
           )))::NUMERIC
$$;

-- Read one numeric threshold of a rule, e.g. fraud.param('R01', 'min_txns')
CREATE OR REPLACE FUNCTION fraud.param(p_rule TEXT, p_key TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT (params ->> p_key)::NUMERIC
    FROM fraud.rule_config
    WHERE rule_code = p_rule
$$;

-- Is the rule switched on?
CREATE OR REPLACE FUNCTION fraud.is_active(p_rule TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT is_active FROM fraud.rule_config WHERE rule_code = p_rule), FALSE)
$$;

-- Write a line to the run log. Called at the end of each step as
--     SELECT fraud.log_step(...) AS logged \gset     (\gset keeps psql output clean)
CREATE OR REPLACE FUNCTION fraud.log_step(p_step TEXT, p_rows BIGINT, p_started TIMESTAMP)
RETURNS VOID
LANGUAGE sql AS $$
    INSERT INTO fraud.engine_run_log (step, rows_written, started_at)
    VALUES (p_step, p_rows, p_started)
$$;
