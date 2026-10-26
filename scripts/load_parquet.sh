#!/bin/bash
# Load every <table>.parquet in /dump into the matching table. Smallest first.
# FROM INFILE ... FORMAT Parquet matches columns by name, not position.
# `info` is skipped: schema.sql already inserts the same 3.1.0 row.
set -euo pipefail
ch() { clickhouse client -u "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" -d "$CLICKHOUSE_DB" "$@"; }
for f in $(ls -Sr /dump/*.parquet); do
  t=$(basename "$f" .parquet)
  [ "$t" = info ] && continue
  if [ "$(ch -q "select count() from \`$t\`")" != 0 ]; then echo "skip $t (not empty)"; continue; fi
  start=$(date +%s)
  ch --max_insert_threads=16 -q "INSERT INTO \`$t\` FROM INFILE '$f' FORMAT Parquet"
  echo "$t $(ch -q "select count() from \`$t\`") rows $(( $(date +%s) - start ))s"
done
echo LOAD_DONE
