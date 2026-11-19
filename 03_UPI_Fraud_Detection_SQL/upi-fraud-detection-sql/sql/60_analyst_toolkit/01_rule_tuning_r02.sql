/* =============================================================================
   01_rule_tuning_r02.sql  -  A/B test a rule change, entirely in SQL.

   Question: R02 (impossible travel) raised many false alarms because city
   geolocation is noisy. Does also requiring a DEVICE CHANGE fix it without
   losing real fraud?

   Run after the main pipeline:
       psql -d upi_fraud -f sql/60_analyst_toolkit/01_rule_tuning_r02.sql
   The rule is left in its production setting (require_device_change = 1).
   ============================================================================= */
\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP TABLE IF EXISTS pg_temp.r02_experiment;
CREATE TEMP TABLE r02_experiment (version TEXT, alerts INT, true_pos INT, false_pos INT,
                                  precision NUMERIC, recall_on_target NUMERIC);

-- ---------- version A: location only ----------
UPDATE fraud.rule_config SET params = jsonb_set(params, '{require_device_change}', '0') WHERE rule_code = 'R02';
\i sql/10_rules/r02_impossible_travel.sql
INSERT INTO r02_experiment
SELECT 'A: location jump only',
       COUNT(*), COUNT(l.txn_id), COUNT(*) - COUNT(l.txn_id),
       ROUND(COUNT(l.txn_id)::NUMERIC / NULLIF(COUNT(*), 0), 4),
       ROUND(COUNT(*) FILTER (WHERE l.fraud_pattern = 'IMPOSSIBLE_TRAVEL')::NUMERIC
             / (SELECT COUNT(*) FROM eval.fraud_labels WHERE fraud_pattern = 'IMPOSSIBLE_TRAVEL'), 4)
FROM fraud.rule_hits h LEFT JOIN eval.fraud_labels l USING (txn_id)
WHERE h.rule_code = 'R02';

-- ---------- version B: location jump + device change (production) ----------
UPDATE fraud.rule_config SET params = jsonb_set(params, '{require_device_change}', '1') WHERE rule_code = 'R02';
\i sql/10_rules/r02_impossible_travel.sql
INSERT INTO r02_experiment
SELECT 'B: location jump + new device',
       COUNT(*), COUNT(l.txn_id), COUNT(*) - COUNT(l.txn_id),
       ROUND(COUNT(l.txn_id)::NUMERIC / NULLIF(COUNT(*), 0), 4),
       ROUND(COUNT(*) FILTER (WHERE l.fraud_pattern = 'IMPOSSIBLE_TRAVEL')::NUMERIC
             / (SELECT COUNT(*) FROM eval.fraud_labels WHERE fraud_pattern = 'IMPOSSIBLE_TRAVEL'), 4)
FROM fraud.rule_hits h LEFT JOIN eval.fraud_labels l USING (txn_id)
WHERE h.rule_code = 'R02';

\echo ''
\echo 'R02 tuning experiment'
SELECT * FROM r02_experiment;

SELECT
    ROUND(100.0 * (a.false_pos - b.false_pos) / NULLIF(a.false_pos, 0), 1) AS pct_false_alarms_removed,
    b.recall_on_target - a.recall_on_target                                AS recall_change
FROM r02_experiment a, r02_experiment b
WHERE a.version LIKE 'A%' AND b.version LIKE 'B%';
