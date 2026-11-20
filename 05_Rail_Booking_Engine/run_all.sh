#!/usr/bin/env bash
# Build the whole project into a PostgreSQL database.
#   ./run_all.sh                  -> uses database "railway"
#   PGDATABASE=mydb ./run_all.sh  -> any other database
set -euo pipefail
cd "$(dirname "$0")"
DB="${PGDATABASE:-railway}"

psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB'" | grep -q 1 \
  || psql -d postgres -c "CREATE DATABASE \"$DB\""

for f in sql/00_setup.sql sql/01_schema.sql sql/02_reference_data.sql \
         sql/03_engine.sql sql/04_triggers_views.sql sql/05_simulate.sql; do
  echo ">>> $f"
  start=$(date +%s)
  psql -q -X -v ON_ERROR_STOP=1 -d "$DB" -f "$f"
  echo "    done in $(( $(date +%s) - start ))s"
done

echo ">>> sql/06_analytics.sql (building predictor + running reports)"
psql -q -X -v ON_ERROR_STOP=1 -d "$DB" -f sql/06_analytics.sql > docs/analytics_output.txt
echo "    report written to docs/analytics_output.txt"

echo ">>> tests"
psql -q -X -v ON_ERROR_STOP=1 -d "$DB" -f tests/test_engine.sql
echo "All done."
