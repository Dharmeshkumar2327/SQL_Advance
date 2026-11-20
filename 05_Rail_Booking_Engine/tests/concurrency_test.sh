#!/usr/bin/env bash
# Fires N simultaneous booking requests at a train with 10 berths + 2 RAC places + 20 WL cap,
# using pgbench (one transaction per client, all at once), then proves:
#   exactly 10 CNF on 10 different berths, 2 RAC, 20 WL numbered 1..20, everybody else REGRET.
# Runs on a throw-away copy of the database (<db>_race), which is dropped afterwards.
set -euo pipefail
cd "$(dirname "$0")"
SRC="${PGDATABASE:-railway}"
DB="${SRC}_race"
CLIENTS="${CLIENTS:-64}"

psql -X -q -d postgres -c "DROP DATABASE IF EXISTS \"$DB\""
psql -X -q -d postgres -c "CREATE DATABASE \"$DB\" TEMPLATE \"$SRC\""
psql -X -q -d "$DB" -f race_setup.sql
echo ">>> $CLIENTS concurrent clients racing for 10 berths"
pgbench -n -d "$DB" -c "$CLIENTS" -j "$(( CLIENTS < 16 ? CLIENTS : 16 ))" -t 1 -f race_book.sql | grep -E "transactions actually processed|failed|latency average"
psql -X -q -d "$DB" -f race_verify.sql
psql -X -q -d postgres -c "DROP DATABASE \"$DB\""
