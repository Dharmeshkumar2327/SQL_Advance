/* =============================================================================
   01_export_dashboard_data.sql
   Writes small, aggregated CSVs to dashboard/data/ so the Streamlit dashboard
   can run anywhere (including Streamlit Community Cloud) without a database.
   ============================================================================= */
\echo '  exporting dashboard data to dashboard/data/'

\copy (SELECT * FROM analytics.kpi_summary)                                   TO 'dashboard/data/kpi_summary.csv'          WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM analytics.daily_alert_trend)                             TO 'dashboard/data/daily_alert_trend.csv'    WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM analytics.hourly_risk_heatmap ORDER BY iso_dow, hour_of_day) TO 'dashboard/data/hourly_risk_heatmap.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM analytics.city_risk ORDER BY alert_rank)                 TO 'dashboard/data/city_risk.csv'            WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM analytics.channel_risk ORDER BY alerts DESC)             TO 'dashboard/data/channel_risk.csv'         WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM analytics.rule_overlap ORDER BY shared_txns DESC)        TO 'dashboard/data/rule_overlap.csv'         WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM analytics.top_risky_accounts WHERE risk_rank <= 500 ORDER BY risk_rank) TO 'dashboard/data/top_risky_accounts.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM analytics.mule_network_edges ORDER BY chain_id, hop_no)  TO 'dashboard/data/mule_network_edges.csv'   WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM analytics.alert_queue ORDER BY risk_score DESC, txn_ts DESC LIMIT 1000) TO 'dashboard/data/alert_queue.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT rule_code, rule_name, description, target_pattern, severity_points, params::TEXT AS params FROM fraud.rule_config WHERE rule_code <> 'COMBO' ORDER BY rule_code) TO 'dashboard/data/rule_config.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM eval.overall_metrics)                                    TO 'dashboard/data/overall_metrics.csv'      WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM eval.rule_performance)                                   TO 'dashboard/data/rule_performance.csv'     WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM eval.pattern_coverage)                                   TO 'dashboard/data/pattern_coverage.csv'     WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM eval.threshold_curve)                                    TO 'dashboard/data/threshold_curve.csv'      WITH (FORMAT csv, HEADER true)
\copy (SELECT risk_band, action, COUNT(*) AS txns, SUM(amount) AS amount FROM fraud.txn_risk_scores GROUP BY risk_band, action ORDER BY MIN(risk_score)) TO 'dashboard/data/risk_band_summary.csv' WITH (FORMAT csv, HEADER true)
