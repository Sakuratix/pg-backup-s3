#!/usr/bin/env bash
# End-to-end test: real PostgreSQL + an S3-compatible server (see .github/workflows/ci.yml).
# Backs up a database, checks pruning and metrics, restores it and compares data.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

export PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres PGDATABASE=app
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
export S3_ENDPOINT=http://localhost:9000 S3_BUCKET=backups S3_PREFIX=postgres
METRICS_DIR="$(mktemp -d)"; export METRICS_DIR

s3() { aws --endpoint-url "$S3_ENDPOINT" s3 "$@"; }
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

step "seed a database"
psql -d postgres -qc "DROP DATABASE IF EXISTS app" -c "DROP DATABASE IF EXISTS app_restored" -c "CREATE DATABASE app"
psql -q <<'SQL'
CREATE TABLE orders (id serial PRIMARY KEY, total numeric(10,2) NOT NULL, note text);
INSERT INTO orders (total, note) SELECT round((random() * 100)::numeric, 2), 'order ' || g FROM generate_series(1, 5000) g;
SQL
want_sum=$(psql -tAc "SELECT sum(total) FROM orders")

step "prepare bucket with one expired backup"
s3 mb "s3://$S3_BUCKET" >/dev/null 2>&1 || true
echo stale | gzip | s3 cp - "s3://$S3_BUCKET/$S3_PREFIX/app/app-20200101T000000Z.sql.gz"

step "backup"
./pg-backup-s3.sh

keys=$(s3 ls "s3://$S3_BUCKET/$S3_PREFIX/app/" | awk '{print $4}')
echo "$keys"
grep -q 20200101 <<<"$keys" && fail "expired backup was not pruned"
key="$S3_PREFIX/app/$(tail -1 <<<"$keys")"
[[ $key == *.sql.gz ]] || fail "unexpected key $key"

step "metrics"
cat "$METRICS_DIR/pg_backup_app.prom"
grep -q 'pg_backup_success{db="app"} 1' "$METRICS_DIR/pg_backup_app.prom" || fail "success metric"
grep -Eq 'pg_backup_size_bytes\{db="app"\} [1-9][0-9]+' "$METRICS_DIR/pg_backup_app.prom" || fail "size metric"

step "restore into a new database and compare"
./restore.sh "$key" app_restored
got_count=$(psql -d app_restored -tAc "SELECT count(*) FROM orders")
got_sum=$(psql -d app_restored -tAc "SELECT sum(total) FROM orders")
[[ $got_count == 5000 ]] || fail "restored $got_count rows, want 5000"
[[ $got_sum == "$want_sum" ]] || fail "restored sum $got_sum, want $want_sum"

step "a failed backup is reported as failed"
if PGDATABASE=does_not_exist ./pg-backup-s3.sh 2>/dev/null; then fail "backup of a missing db succeeded"; fi
grep -q 'pg_backup_success{db="does_not_exist"} 0' "$METRICS_DIR/pg_backup_does_not_exist.prom" || fail "failure metric"

echo; echo "e2e OK"
