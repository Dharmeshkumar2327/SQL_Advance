/* =============================================================================
   02_load_data.sql
   Loads the generated CSV files. \copy runs on the client side, so psql must be
   started from the repository root (run_all.sql / Makefile do this for you).
   ============================================================================= */

\echo '  loading cities...'
\copy upi.cities       FROM 'data/cities.csv'       WITH (FORMAT csv, HEADER true)
\echo '  loading accounts...'
\copy upi.accounts     FROM 'data/accounts.csv'     WITH (FORMAT csv, HEADER true)
\echo '  loading transactions...'
\copy upi.transactions FROM 'data/transactions.csv' WITH (FORMAT csv, HEADER true)
\echo '  loading ground-truth labels (eval only)...'
\copy eval.fraud_labels FROM 'data/fraud_labels.csv' WITH (FORMAT csv, HEADER true)

SELECT 'cities' AS table_name, COUNT(*) AS row_count FROM upi.cities
UNION ALL SELECT 'accounts',     COUNT(*) FROM upi.accounts
UNION ALL SELECT 'transactions', COUNT(*) FROM upi.transactions
UNION ALL SELECT 'fraud_labels', COUNT(*) FROM eval.fraud_labels;
