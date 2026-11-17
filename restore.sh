#!/usr/bin/env bash
# Restore a backup into a database: ./restore.sh <s3 key> <target db>
# Restore into a fresh database and check it before switching the app over.
# Encrypted backups (*.age) need AGE_IDENTITY=<path to the age private key file>.
set -Eeuo pipefail
key="${1:?usage: restore.sh <s3 key> <target db>}"; target="${2:?target db}"
S3_ENDPOINT="${S3_ENDPOINT:-https://storage.yandexcloud.net}"
: "${S3_BUCKET:?S3_BUCKET is required}"
decrypt() { cat; }
if [[ "$key" == *.age ]]; then
  : "${AGE_IDENTITY:?AGE_IDENTITY (path to the age private key) is required for encrypted backups}"
  decrypt() { age --decrypt --identity "$AGE_IDENTITY"; }
fi
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
aws --endpoint-url "$S3_ENDPOINT" s3 cp --only-show-errors "s3://$S3_BUCKET/$key" "$tmp/backup"

# verify before anything touches a database: a truncated download or a
# bit-rotted object fails here instead of halfway through psql
want="$(aws --endpoint-url "$S3_ENDPOINT" s3api head-object --bucket "$S3_BUCKET" --key "$key" \
  --query 'Metadata.sha256' --output text)"
if [[ "$want" =~ ^[0-9a-f]{64}$ ]]; then
  got="$(sha256sum "$tmp/backup" | cut -d' ' -f1)"
  [[ "$got" == "$want" ]] || { echo "checksum mismatch for $key: object says $want, downloaded $got" >&2; exit 1; }
  echo "sha256 ok" >&2
else
  echo "warning: $key has no sha256 metadata (made by an older version), restoring unverified" >&2
fi

createdb "$target"
decrypt < "$tmp/backup" | gunzip | psql --set ON_ERROR_STOP=1 -q -d "$target"
echo "restored $key into $target"
