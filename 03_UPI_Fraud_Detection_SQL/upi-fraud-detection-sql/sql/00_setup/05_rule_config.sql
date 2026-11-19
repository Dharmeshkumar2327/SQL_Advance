/* =============================================================================
   05_rule_config.sql
   The rule catalogue. Thresholds live in JSONB so the engine is configurable:

       UPDATE fraud.rule_config
       SET params = jsonb_set(params, '{min_txns}', '8')
       WHERE rule_code = 'R01';

   then re-run the rules and the evaluation to see the precision/recall impact.
   ============================================================================= */

INSERT INTO fraud.rule_config (rule_code, rule_name, description, target_pattern, severity_points, params) VALUES
('R01', 'Velocity burst',
 'Many successful debits from one account inside a short rolling window - typical of an account takeover draining funds.',
 'VELOCITY_BURST', 35,
 '{"window_minutes": 10, "min_txns": 6, "min_total_amount": 10000}'),

('R02', 'Impossible travel',
 'Two consecutive payments from cities so far apart that the customer would have to travel faster than a plane - and (by default) from a different device.',
 'IMPOSSIBLE_TRAVEL', 30,
 '{"min_distance_km": 300, "max_speed_kmph": 500, "require_device_change": 1}'),

('R03', 'Mule chain (layering)',
 'Money that is received and forwarded almost in full, again and again, within minutes - a money-mule chain found with a recursive CTE.',
 'MULE_CHAIN', 40,
 '{"min_start_amount": 10000, "max_hop_minutes": 60, "min_forward_ratio": 0.90, "min_chain_txns": 3, "max_depth": 8}'),

('R04', 'New device + high value',
 'First ever payment from a device for an established customer, for an amount far above their normal spend (SIM-swap / device takeover).',
 'NEW_DEVICE_HIGH_VALUE', 30,
 '{"min_history_txns": 5, "min_amount": 20000, "avg_multiplier": 5}'),

('R05', 'Structuring',
 'Several payments on the same day just below a review threshold - splitting money to avoid scrutiny.',
 'STRUCTURING', 25,
 '{"band_lower": 9500, "band_upper": 10000, "min_txns_per_day": 4}'),

('R06', 'Fan-in collect scam',
 'A brand-new personal account receiving money from many different people within 24 hours (fake collect requests, lottery/job scams).',
 'FAN_IN_COLLECT_SCAM', 30,
 '{"max_account_age_days": 30, "window_hours": 24, "min_distinct_payers": 10}'),

('R07', 'Odd-hour amount anomaly',
 'A late-night payment whose amount is a statistical outlier (z-score) versus the customer''s own history.',
 'ODD_HOUR_ANOMALY', 25,
 '{"start_hour": 1, "end_hour": 4, "min_history_txns": 5, "z_threshold": 3, "min_amount": 5000}'),

('R08', 'PIN brute force',
 'A successful payment that comes right after several wrong-PIN failures - someone guessing the UPI PIN.',
 'PIN_BRUTE_FORCE', 35,
 '{"window_minutes": 10, "min_failed_attempts": 3}');

-- Extra points when several independent rules agree on the same transaction
INSERT INTO fraud.rule_config (rule_code, rule_name, description, target_pattern, severity_points, params, is_active) VALUES
('COMBO', 'Multi-rule bonus',
 'Not a detection rule. Bonus points added per additional rule that fires on the same transaction.',
 'N/A', 15, '{"bonus_per_extra_rule": 15}', FALSE);

INSERT INTO fraud.risk_bands (risk_band, min_score, max_score, action, sort_order) VALUES
('NONE',     0,   0,   'ALLOW',            1),
('LOW',      1,   24,  'ALLOW_AND_MONITOR', 2),
('MEDIUM',   25,  49,  'STEP_UP_AUTH',     3),
('HIGH',     50,  74,  'HOLD_FOR_REVIEW',  4),
('CRITICAL', 75,  100, 'BLOCK',            5);
