#!/usr/bin/env bash
# =============================================================================
# GST Reconciliation Engine - one-command build
# Author : Dharmesh Kumar
#
# Usage:
#   ./run_all.sh                  # uses data/ already in the repo
#   ./run_all.sh --regenerate     # rebuilds the synthetic data first
#
# Connection settings come from the standard libpq variables, e.g.
#   PGHOST=localhost PGPORT=5432 PGUSER=postgres ./run_all.sh
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")"
DB_NAME="${DB_NAME:-gst_recon}"

if [[ "${1:-}" == "--regenerate" ]]; then
  echo "==> Generating synthetic data"
  python3 data_generator/generate_data.py
fi

echo "==> (Re)creating database ${DB_NAME}"
dropdb --if-exists "${DB_NAME}"
createdb "${DB_NAME}"

for f in sql/0*.sql; do
  echo "==> Running ${f}"
  psql -d "${DB_NAME}" -v ON_ERROR_STOP=1 -q -f "${f}"
done

echo
echo "Done. Connect with:  psql -d ${DB_NAME}"
echo "Try:  SELECT * FROM gst.v_recon_summary;"
