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
for db in app app_restored app_no_key app_decrypted; do psql -d postgres -qc "DROP DATABASE IF EXISTS $db"; done
psql -d postgres -qc "CREATE DATABASE app"
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

step "encrypted backup: unreadable without the key, restorable with it"
age-keygen -o "$METRICS_DIR/age.key" 2>/dev/null
recipient=$(age-keygen -y "$METRICS_DIR/age.key")
AGE_RECIPIENT="$recipient" ./pg-backup-s3.sh
enc_key="$S3_PREFIX/app/$(s3 ls "s3://$S3_BUCKET/$S3_PREFIX/app/" | awk '{print $4}' | grep '\.age$' | tail -1)"
[[ $enc_key == *.sql.gz.age ]] || fail "no encrypted backup uploaded"
grep -q 'pg_backup_encrypted{db="app"} 1' "$METRICS_DIR/pg_backup_app.prom" || fail "encrypted metric"
if s3 cp "s3://$S3_BUCKET/$enc_key" - | gunzip -t 2>/dev/null; then fail "encrypted object is readable as plain gzip"; fi
if ./restore.sh "$enc_key" app_no_key 2>/dev/null; then fail "restore without AGE_IDENTITY succeeded"; fi
AGE_IDENTITY="$METRICS_DIR/age.key" ./restore.sh "$enc_key" app_decrypted
[[ $(psql -d app_decrypted -tAc "SELECT sum(total) FROM orders") == "$want_sum" ]] || fail "decrypted data differs"

step "restore check of the latest backup"
AGE_IDENTITY="$METRICS_DIR/age.key" CHECK_TABLE=orders CHECK_MIN_ROWS=5000 \
  CHECK_SQL="SELECT sum(total) = $want_sum FROM orders" ./restore-check.sh
cat "$METRICS_DIR/pg_restore_check_app.prom"
grep -q 'pg_restore_check_success{db="app"} 1' "$METRICS_DIR/pg_restore_check_app.prom" || fail "restore check metric"
[[ -z $(psql -d postgres -tAc "SELECT datname FROM pg_database WHERE datname LIKE 'app_restore_check_%'") ]] || fail "scratch database left behind"

step "restore check fails loudly when the data is wrong"
if AGE_IDENTITY="$METRICS_DIR/age.key" CHECK_TABLE=orders CHECK_MIN_ROWS=999999 ./restore-check.sh 2>/dev/null; then fail "check passed with too few rows"; fi
grep -q 'pg_restore_check_success{db="app"} 0' "$METRICS_DIR/pg_restore_check_app.prom" || fail "failed check not reported"
[[ -z $(psql -d postgres -tAc "SELECT datname FROM pg_database WHERE datname LIKE 'app_restore_check_%'") ]] || fail "scratch database left behind after failure"

step "a failed backup is reported as failed"
if PGDATABASE=does_not_exist ./pg-backup-s3.sh 2>/dev/null; then fail "backup of a missing db succeeded"; fi
grep -q 'pg_backup_success{db="does_not_exist"} 0' "$METRICS_DIR/pg_backup_does_not_exist.prom" || fail "failure metric"

echo; echo "e2e OK"
