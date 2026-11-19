#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-command end-to-end run (Linux / macOS / Git Bash on Windows).
#
#   ./scripts/run_pipeline.sh            # full: generate data + build engine
#   ./scripts/run_pipeline.sh --small    # quick demo dataset (~120k txns)
#   ./scripts/run_pipeline.sh --rules    # re-run rules only (data already loaded)
#
# Connection settings come from the standard Postgres env vars:
#   PGHOST (default localhost) PGPORT (5432) PGUSER (postgres) PGPASSWORD PGDATABASE (upi_fraud)
# -----------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGDATABASE="${PGDATABASE:-upi_fraud}"
PYTHON="${PYTHON:-python3}"

MODE="${1:-full}"

echo ">> target database: $PGUSER@$PGHOST:$PGPORT/$PGDATABASE"

# create the database if it does not exist yet
if ! psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$PGDATABASE'" | grep -q 1; then
    echo ">> creating database $PGDATABASE"
    psql -d postgres -c "CREATE DATABASE $PGDATABASE"
fi

mkdir -p dashboard/data

case "$MODE" in
    --rules)
        psql -q -v skip_load=1 -f sql/run_all.sql
        ;;
    --small)
        "$PYTHON" data_generator/generate_data.py --accounts 10000 --txns 120000
        psql -q -f sql/run_all.sql
        ;;
    *)
        "$PYTHON" data_generator/generate_data.py
        psql -q -f sql/run_all.sql
        ;;
esac
