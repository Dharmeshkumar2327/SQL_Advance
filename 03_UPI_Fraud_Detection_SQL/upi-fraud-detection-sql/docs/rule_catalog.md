# Rule catalogue

Each rule lives in its own file in `sql/10_rules/` and follows the same contract:

1. Delete its own previous hits, so it is **idempotent** and safe to re-run.
2. Read every threshold from `fraud.rule_config` through `fraud.param(rule, key)`.
3. Insert one row per flagged transaction into `fraud.rule_hits`, with a JSONB `evidence` object.
4. Do nothing if `is_active = false`.
5. Log its row count and runtime to `fraud.engine_run_log`.

`account_id` in `rule_hits` is the account **under suspicion**. That is the payer for most rules, and the **receiver** for R03 (mule chain) and R06 (fan-in scam).

Severity points add up to the transaction risk score, plus 15 bonus points for every additional rule that agrees. The total is capped at 100.

| Band | Score | Action |
|---|---|---|
| LOW | 1–24 | allow and monitor |
| MEDIUM | 25–49 | step-up authentication |
| HIGH | 50–74 | hold for review |
| CRITICAL | 75–100 | block |

---

## R01 – Velocity burst · 35 pts
**Scenario:** a fraudster takes over an account and empties it with many quick transfers before the customer notices.

**Logic:** for every successful debit, count and sum the payer's debits in the trailing `window_minutes`, using a `RANGE BETWEEN interval PRECEDING AND CURRENT ROW` frame. If both `min_txns` and `min_total_amount` are crossed, every payment inside that window is flagged, not only the one that tipped it over.

**Defaults:** 10 min, ≥ 6 payments, ≥ ₹10,000.

**Known false positives:** shopping sprees (several shops within minutes).
**Known misses:** "low and slow" takeovers that spread 4–5 payments over 40 minutes.

## R02 – Impossible travel · 30 pts
**Scenario:** the customer pays in Hyderabad, and 29 minutes later "they" pay from Kolkata.

**Logic:** `LAG()` finds the previous successful payment by the same account. The cities are joined to their coordinates, and `fraud.haversine_km()` gives the distance. Implied speed = distance ÷ time. The rule flags payments with distance ≥ `min_distance_km` and speed ≥ `max_speed_kmph`. With `require_device_change = 1`, the device must also differ from the previous payment's.

**Defaults:** 300 km, 500 km/h, device change required.

**Tuning story:** location alone gave 15.9 % precision. Adding the device condition raised it to 68.2 % with no recall lost. See `sql/60_analyst_toolkit/01_rule_tuning_r02.sql`.

## R03 – Mule chain (layering) · 40 pts
**Scenario:** the victim pays mule A, A forwards about 98 % to mule B within minutes, B pays C, and so on until a gift-card or crypto merchant cashes it out.

**Logic:** a `WITH RECURSIVE` CTE.
- **Anchor:** every successful payment ≥ `min_start_amount`.
- **Recursive step:** the receiver pays onward within `max_hop_minutes`, forwarding between `min_forward_ratio` and 100 % of the amount.

An `account_path` array prevents cycles, and `max_depth` caps recursion. The rule keeps the longest path per root, removes chains that are just the tail of a longer one, and requires ≥ `min_chain_txns` hops. It also creates two tables:
- `fraud.mule_chains`: one row per hop.
- `fraud.suspected_mule_accounts`: accounts that both received and forwarded chain money.

**Defaults:** ₹10,000 start, 60 min per hop, forward ≥ 90 %, ≥ 3 transactions in the chain, depth ≤ 8.

**Known misses:** slow chains with hops 70–180 minutes apart.

## R04 – New device + high value · 30 pts
**Scenario:** SIM swap. An established customer pays a huge amount from a phone that has never been seen on their account.

**Logic:** `ROW_NUMBER()` per (account, device) marks the first use of a device. A running `AVG(amount)` over the payer's earlier payments (frame `ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING`) gives a baseline that is not polluted by the current payment. Flag when the device is new, the payer has ≥ `min_history_txns` prior payments, and the amount ≥ max(`min_amount`, `avg_multiplier` × baseline).

**Defaults:** ≥ 5 prior payments, ≥ ₹20,000, ≥ 5× normal spend.

**Known false positives:** a genuine new phone followed by rent or fee payments.

## R05 – Structuring · 25 pts
**Scenario:** to avoid review, the fraudster sends five payments of ₹9,900 instead of one of ₹50,000.

**Logic:** filter payments in [`band_lower`, `band_upper`), group them by payer and calendar day, keep days with `HAVING COUNT(*) >= min_txns_per_day`, and flag every payment on those days.

**Defaults:** ₹9,500–₹9,999.99, ≥ 4 per day.

**Known false positives:** rent split into four payments to the landlord.
**Known misses:** structuring spread across two days (3 + 3).

## R06 – Fan-in collect scam · 30 pts
**Scenario:** a brand-new personal account collects ₹499–₹4,999 from dozens of strangers in one day (fake job or lottery collect requests).

**Logic:** only inbound payments to **personal** accounts younger than `max_account_age_days` are checked. Merchants are excluded on purpose: a new shop receiving many payments is normal. PostgreSQL does not support `COUNT(DISTINCT)` as a window function, so a `CROSS JOIN LATERAL` subquery counts the distinct payers in the trailing `window_hours`, using the `(payee_account_id, txn_ts)` index. Every inbound payment inside a breaching window is flagged.

**Defaults:** account ≤ 30 days old, 24 h window, ≥ 10 distinct payers.

**Known false positives:** a student collecting trip money from friends.

## R07 – Odd-hour amount anomaly · 25 pts
**Scenario:** a 2 am payment many times larger than anything the customer usually spends.

**Logic:** a running `AVG` and `STDDEV_SAMP` over the payer's earlier payments give z = (amount − avg) / std. Flag z ≥ `z_threshold`, amount ≥ `min_amount`, hour between `start_hour` and `end_hour`, and ≥ `min_history_txns` of history.

**Defaults:** 1 am–4 am, z ≥ 3, ≥ ₹5,000, ≥ 5 prior payments.

**Known false positives:** late-night emergencies (hospital, flight tickets).

## R08 – PIN brute force · 35 pts
**Scenario:** someone without the PIN guesses it. Several "wrong PIN" failures are followed by a success.

**Logic:** one pass over all attempts of accounts that ever entered a wrong PIN. `COUNT(*) FILTER (WHERE status = 'FAILED' AND failure_reason = 'WRONG_PIN') OVER (RANGE window)` counts recent failures. A successful payment with ≥ `min_failed_attempts` failures in the window is flagged.

**Defaults:** 10 min, ≥ 3 failures.
