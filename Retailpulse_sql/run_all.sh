#!/usr/bin/env bash
# Builds the RetailPulse database and runs every analysis file.
# Usage:  ./run_all.sh [db_name]        (uses standard PG* env vars for host/user)
set -euo pipefail
export PGOPTIONS="${PGOPTIONS:-} --client-min-messages=warning"
DB="${1:-retailpulse}"
cd "$(dirname "$0")/sql"
createdb "$DB" 2>/dev/null || true
for f in 01_schema.sql 02_seed_data.sql 03_views_functions.sql 04_indexes.sql; do
  echo ">> $f"; psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f" > /dev/null
done
mkdir -p ../results
for f in analysis/*.sql; do
  out="../results/$(basename "${f%.sql}").txt"
  echo ">> $f  ->  results/$(basename "$out")"
  psql -d "$DB" -v ON_ERROR_STOP=1 -f "$f" > "$out" 2>&1
done
echo "Done."
