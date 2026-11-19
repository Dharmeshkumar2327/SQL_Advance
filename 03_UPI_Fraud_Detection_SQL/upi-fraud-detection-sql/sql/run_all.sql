/* =============================================================================
   run_all.sql  -  runs the whole engine end to end.

   Run from the REPOSITORY ROOT (paths in \copy are relative to it):
       psql -d upi_fraud -f sql/run_all.sql

   Optional: skip the slow reload when only rules changed
       psql -d upi_fraud -v skip_load=1 -f sql/run_all.sql
   ============================================================================= */
\set ON_ERROR_STOP on
\timing off
SET client_min_messages = warning;

\echo '================================================================'
\echo ' UPI FRAUD DETECTION ENGINE'
\echo '================================================================'

\if :{?skip_load}
    \echo '[1/7] setup skipped (skip_load set) - re-running rules only'
    TRUNCATE fraud.rule_hits, fraud.engine_run_log;
    DROP SCHEMA analytics CASCADE;          -- views depend on the tables we rebuild
    CREATE SCHEMA analytics;
\else
    \echo '[1/7] schemas, tables, data load, indexes'
    \i sql/00_setup/01_schemas_and_tables.sql
    \i sql/00_setup/02_load_data.sql
    \i sql/00_setup/03_constraints_and_indexes.sql
    \i sql/00_setup/04_helper_functions.sql
    \i sql/00_setup/05_rule_config.sql
\endif

\echo '[2/7] data quality tests'
\i sql/90_tests/01_data_quality_tests.sql
\echo '  all data quality tests passed'

\echo '[3/7] detection rules'
\i sql/10_rules/r01_velocity_burst.sql
\i sql/10_rules/r02_impossible_travel.sql
\i sql/10_rules/r03_mule_chain.sql
\i sql/10_rules/r04_new_device_high_value.sql
\i sql/10_rules/r05_structuring.sql
\i sql/10_rules/r06_fan_in_collect_scam.sql
\i sql/10_rules/r07_odd_hour_anomaly.sql
\i sql/10_rules/r08_pin_brute_force.sql

\echo '[4/7] risk scoring'
\i sql/20_scoring/01_txn_risk_scores.sql
\i sql/20_scoring/02_account_risk_profile.sql

\echo '[5/7] evaluation'
\i sql/30_evaluation/01_model_evaluation.sql

\echo '[6/7] analytics views + dashboard export'
\i sql/40_analytics/01_reporting_views.sql
\i sql/50_export/01_export_dashboard_data.sql

\echo '[7/7] engine tests'
\i sql/90_tests/02_engine_tests.sql

\echo ''
\echo '---- run log ----'
SELECT step, rows_written,
       ROUND(EXTRACT(EPOCH FROM finished_at - started_at)::NUMERIC, 2) AS seconds
FROM fraud.engine_run_log
ORDER BY run_id;

\echo '================================================================'
\echo ' DONE - open the dashboard with:  streamlit run dashboard/app.py'
\echo '================================================================'
