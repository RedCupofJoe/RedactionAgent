#!/usr/bin/env bash
# Create MinIO buckets used by the Auto Redaction Agent.
set -euo pipefail

MINIO_ALIAS="${MINIO_ALIAS:-local}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://localhost:9000}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"
RAW_BUCKET="${S3_RAW_BUCKET:-raw-documents}"
REDACTED_BUCKET="${S3_REDACTED_BUCKET:-redacted-documents}"

if ! command -v mc >/dev/null 2>&1; then
  echo "ERROR: MinIO Client (mc) is required. Install from https://min.io/docs/minio/linux/reference/minio-mc.html"
  exit 1
fi

echo "Configuring mc alias '${MINIO_ALIAS}' -> ${MINIO_ENDPOINT}"
mc alias set "${MINIO_ALIAS}" "${MINIO_ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"

for bucket in "${RAW_BUCKET}" "${REDACTED_BUCKET}"; do
  if mc ls "${MINIO_ALIAS}/${bucket}" >/dev/null 2>&1; then
    echo "Bucket exists: ${bucket}"
  else
    echo "Creating bucket: ${bucket}"
    mc mb "${MINIO_ALIAS}/${bucket}"
  fi
done

echo "Applying anonymous download policy on ${RAW_BUCKET} (optional demo read)..."
mc anonymous set download "${MINIO_ALIAS}/${RAW_BUCKET}" || true

echo "Done. Buckets ready:"
mc ls "${MINIO_ALIAS}"
