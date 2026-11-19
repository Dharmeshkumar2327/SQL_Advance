/* =============================================================================
   03_constraints_and_indexes.sql
   Foreign keys and indexes are added AFTER the bulk load - much faster than
   checking them row by row during \copy.
   ============================================================================= */

ALTER TABLE upi.accounts
    ADD CONSTRAINT fk_accounts_city FOREIGN KEY (home_city) REFERENCES upi.cities (city);

ALTER TABLE upi.transactions
    ADD CONSTRAINT fk_txn_payer FOREIGN KEY (payer_account_id) REFERENCES upi.accounts (account_id),
    ADD CONSTRAINT fk_txn_payee FOREIGN KEY (payee_account_id) REFERENCES upi.accounts (account_id),
    ADD CONSTRAINT fk_txn_city  FOREIGN KEY (txn_city)         REFERENCES upi.cities (city);

ALTER TABLE eval.fraud_labels
    ADD CONSTRAINT fk_label_txn FOREIGN KEY (txn_id) REFERENCES upi.transactions (txn_id);

-- Almost every rule looks at "this payer's recent history" -> composite index
CREATE INDEX idx_txn_payer_ts  ON upi.transactions (payer_account_id, txn_ts);
-- Fan-in and mule-chain rules walk money INTO an account
CREATE INDEX idx_txn_payee_ts  ON upi.transactions (payee_account_id, txn_ts);
-- Partial index: wrong-PIN failures are rare, so this index is tiny
CREATE INDEX idx_txn_wrong_pin ON upi.transactions (payer_account_id, txn_ts)
    WHERE status = 'FAILED' AND failure_reason = 'WRONG_PIN';
-- BRIN index: compact index for time-range scans on an append-only table
CREATE INDEX idx_txn_ts_brin   ON upi.transactions USING BRIN (txn_ts);

ANALYZE upi.cities;
ANALYZE upi.accounts;
ANALYZE upi.transactions;
ANALYZE eval.fraud_labels;
