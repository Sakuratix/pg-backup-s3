#!/usr/bin/env bash
# Restore a backup into a database: ./restore.sh <s3 key> <target db>
# Restore into a fresh database and check it before switching the app over.
set -Eeuo pipefail
key="${1:?usage: restore.sh <s3 key> <target db>}"; target="${2:?target db}"
S3_ENDPOINT="${S3_ENDPOINT:-https://storage.yandexcloud.net}"
: "${S3_BUCKET:?S3_BUCKET is required}"
createdb "$target"
aws --endpoint-url "$S3_ENDPOINT" s3 cp "s3://$S3_BUCKET/$key" - | gunzip | psql --set ON_ERROR_STOP=1 -q -d "$target"
echo "restored $key into $target"
