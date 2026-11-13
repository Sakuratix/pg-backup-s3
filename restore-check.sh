#!/usr/bin/env bash
# Prove the latest backup can actually be restored: restore it into a throwaway
# database, run sanity checks, drop it, and report the result to Prometheus.
#
# Same env as pg-backup-s3.sh (PGHOST PGUSER PGDATABASE S3_BUCKET ...), plus:
#   AGE_IDENTITY     private key file, if backups are encrypted
#   CHECK_TABLE      table that must have rows after restore (optional)
#   CHECK_MIN_ROWS   minimum rows in CHECK_TABLE (default 1)
#   CHECK_SQL        extra query that must return 't' (optional)
set -Eeuo pipefail

S3_PREFIX="${S3_PREFIX:-postgres}"
S3_ENDPOINT="${S3_ENDPOINT:-https://storage.yandexcloud.net}"
METRICS_DIR="${METRICS_DIR:-/var/lib/node_exporter/textfile}"
CHECK_MIN_ROWS="${CHECK_MIN_ROWS:-1}"
: "${PGDATABASE:?PGDATABASE is required}" "${S3_BUCKET:?S3_BUCKET is required}"

here="$(cd "$(dirname "$0")" && pwd)"
scratch="${PGDATABASE}_restore_check_$(date -u +%Y%m%d%H%M%S)"
start="$(date +%s)"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
q() { psql -X -tA --set ON_ERROR_STOP=1 -d "$scratch" -c "$1"; }

report() {  # $1 = success (0/1), $2 = backup age in seconds (or empty)
  [[ -d "$METRICS_DIR" ]] || return 0
  local f="$METRICS_DIR/pg_restore_check_${PGDATABASE}.prom"
  {
    echo "# HELP pg_restore_check_success Latest backup restored and passed checks (1) or not (0)."
    echo "# TYPE pg_restore_check_success gauge"
    echo "pg_restore_check_success{db=\"$PGDATABASE\"} $1"
    echo "# HELP pg_restore_check_last_run_timestamp_seconds Time of the last restore check."
    echo "# TYPE pg_restore_check_last_run_timestamp_seconds gauge"
    echo "pg_restore_check_last_run_timestamp_seconds{db=\"$PGDATABASE\"} $(date +%s)"
    echo "# HELP pg_restore_check_duration_seconds Time the restore took (your real RTO)."
    echo "# TYPE pg_restore_check_duration_seconds gauge"
    echo "pg_restore_check_duration_seconds{db=\"$PGDATABASE\"} $(( $(date +%s) - start ))"
    if [[ -n "${2:-}" ]]; then
      echo "# HELP pg_restore_check_backup_age_seconds Age of the backup that was checked."
      echo "# TYPE pg_restore_check_backup_age_seconds gauge"
      echo "pg_restore_check_backup_age_seconds{db=\"$PGDATABASE\"} $2"
    fi
  } > "$f.$$" && mv "$f.$$" "$f"
}
cleanup() { dropdb --if-exists "$scratch" 2>/dev/null || true; }
trap 'report 0; cleanup' ERR
trap cleanup EXIT

latest="$(aws --endpoint-url "$S3_ENDPOINT" s3 ls "s3://$S3_BUCKET/$S3_PREFIX/$PGDATABASE/" | awk '{print $4}' | grep -E '\.sql\.gz(\.age)?$' | sort | tail -1)"
[[ -n "$latest" ]] || { log "no backups found for $PGDATABASE"; false; }
taken="$(sed -E 's/.*-([0-9]{8})T([0-9]{2})([0-9]{2})([0-9]{2})Z.*/\1 \2:\3:\4/' <<<"$latest")"
age_s=$(( $(date +%s) - $(date -u -d "$taken" +%s) ))

log "restoring $latest into $scratch"
"$here/restore.sh" "$S3_PREFIX/$PGDATABASE/$latest" "$scratch" >/dev/null

tables="$(q "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')")"
log "restored $tables tables"
(( tables > 0 )) || { log "restored database has no tables"; false; }
if [[ -n "${CHECK_TABLE:-}" ]]; then
  rows="$(q "SELECT count(*) FROM ${CHECK_TABLE}")"
  log "$CHECK_TABLE has $rows rows (need >= $CHECK_MIN_ROWS)"
  (( rows >= CHECK_MIN_ROWS )) || { log "too few rows in $CHECK_TABLE"; false; }
fi
if [[ -n "${CHECK_SQL:-}" ]]; then
  [[ "$(q "$CHECK_SQL")" == t ]] || { log "CHECK_SQL returned false: $CHECK_SQL"; false; }
fi

report 1 "$age_s"
log "restore check passed in $(( $(date +%s) - start ))s, backup is $(( age_s / 3600 ))h old"
