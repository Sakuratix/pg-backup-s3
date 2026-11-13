#!/usr/bin/env bash
# Dump a PostgreSQL database, compress it, upload to S3-compatible storage,
# prune old backups and write Prometheus metrics for node_exporter's textfile collector.
#
# Required env: PGHOST PGUSER PGDATABASE (PGPASSWORD or ~/.pgpass), S3_BUCKET
# Optional env: S3_PREFIX (default: postgres), S3_ENDPOINT (default: https://storage.yandexcloud.net),
#               RETENTION_DAYS (default: 14), METRICS_DIR (default: /var/lib/node_exporter/textfile)
#               AGE_RECIPIENT  encrypt with age (https://age-encryption.org) to this public key;
#                              the private key is never on the database server
set -Eeuo pipefail

S3_PREFIX="${S3_PREFIX:-postgres}"
S3_ENDPOINT="${S3_ENDPOINT:-https://storage.yandexcloud.net}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
METRICS_DIR="${METRICS_DIR:-/var/lib/node_exporter/textfile}"
: "${PGDATABASE:?PGDATABASE is required}" "${S3_BUCKET:?S3_BUCKET is required}"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
AGE_RECIPIENT="${AGE_RECIPIENT:-}"
ext="sql.gz"; [[ -n "$AGE_RECIPIENT" ]] && ext="sql.gz.age"
key="${S3_PREFIX}/${PGDATABASE}/${PGDATABASE}-${ts}.${ext}"
tmp="$(mktemp -d)"
start="$(date +%s)"
trap 'rm -rf "$tmp"' EXIT

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

write_metrics() {  # $1 = success (0/1)
  [[ -d "$METRICS_DIR" ]] || return 0
  local f="$METRICS_DIR/pg_backup_${PGDATABASE}.prom"
  {
    echo "# HELP pg_backup_success Last backup succeeded (1) or failed (0)."
    echo "# TYPE pg_backup_success gauge"
    echo "pg_backup_success{db=\"$PGDATABASE\"} $1"
    echo "# HELP pg_backup_last_run_timestamp_seconds Time of the last run."
    echo "# TYPE pg_backup_last_run_timestamp_seconds gauge"
    echo "pg_backup_last_run_timestamp_seconds{db=\"$PGDATABASE\"} $(date +%s)"
    echo "# HELP pg_backup_duration_seconds Duration of the last run."
    echo "# TYPE pg_backup_duration_seconds gauge"
    echo "pg_backup_duration_seconds{db=\"$PGDATABASE\"} $(( $(date +%s) - start ))"
    if [[ "$1" == 1 ]]; then
      echo "# HELP pg_backup_size_bytes Size of the last successful backup."
      echo "# TYPE pg_backup_size_bytes gauge"
      echo "pg_backup_size_bytes{db=\"$PGDATABASE\"} $(stat -c %s "$tmp/upload")"
      echo "# HELP pg_backup_encrypted Last backup was encrypted with age (1) or not (0)."
      echo "# TYPE pg_backup_encrypted gauge"
      echo "pg_backup_encrypted{db=\"$PGDATABASE\"} $([[ -n "$AGE_RECIPIENT" ]] && echo 1 || echo 0)"
    fi
  } > "$f.$$" && mv "$f.$$" "$f"   # atomic for the textfile collector
}
trap 'write_metrics 0' ERR

s3() { aws --endpoint-url "$S3_ENDPOINT" s3 "$@"; }

log "dumping $PGDATABASE"
pg_dump --no-owner --format=plain | gzip -6 > "$tmp/dump.sql.gz"
gzip -t "$tmp/dump.sql.gz"   # fail early on a broken archive

if [[ -n "$AGE_RECIPIENT" ]]; then
  log "encrypting for $AGE_RECIPIENT"
  age --encrypt --recipient "$AGE_RECIPIENT" --output "$tmp/upload" "$tmp/dump.sql.gz"
else
  mv "$tmp/dump.sql.gz" "$tmp/upload"
fi

log "uploading s3://$S3_BUCKET/$key"
s3 cp --only-show-errors "$tmp/upload" "s3://$S3_BUCKET/$key"

log "pruning backups older than $RETENTION_DAYS days"
cutoff="$(date -u -d "-${RETENTION_DAYS} days" +%Y%m%d)"
s3 ls "s3://$S3_BUCKET/$S3_PREFIX/$PGDATABASE/" | awk '{print $4}' | while read -r name; do
  d="$(sed -E 's/.*-([0-9]{8})T.*/\1/' <<<"$name")"
  if [[ "$d" =~ ^[0-9]{8}$ && "$d" < "$cutoff" ]]; then
    log "delete $name"
    s3 rm --only-show-errors "s3://$S3_BUCKET/$S3_PREFIX/$PGDATABASE/$name"
  fi
done

write_metrics 1
log "done in $(( $(date +%s) - start ))s"
