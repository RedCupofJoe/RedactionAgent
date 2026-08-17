#!/usr/bin/env bash
# Upload scratch/datasets PDFs + synthetic samples into MinIO raw-documents.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${ROOT}/scratch/datasets"
export ROOT SCRATCH

if [[ -n "${S3_ENDPOINT_URL:-}" ]]; then
  ENDPOINT="${S3_ENDPOINT_URL}"
else
  HOST=$(oc -n minio get route minio-api -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [[ -z "${HOST}" ]]; then
    echo "MinIO API route not found. Set S3_ENDPOINT_URL or deploy MinIO first."
    exit 1
  fi
  ENDPOINT="https://${HOST}"
fi

if [[ -f "${ROOT}/secrets/local/minio-lab-user-creds.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT}/secrets/local/minio-lab-user-creds.env"
fi

ACCESS="${S3_ACCESS_KEY:-${MINIO_LAB_USER:-}}"
SECRET="${S3_SECRET_KEY:-${MINIO_LAB_PASSWORD:-}}"
if [[ -z "${ACCESS}" || -z "${SECRET}" ]]; then
  echo "Set S3_ACCESS_KEY/S3_SECRET_KEY or run scripts/setup_minio.sh first."
  exit 1
fi

export S3_ENDPOINT_URL="${ENDPOINT}"
export S3_ACCESS_KEY="${ACCESS}"
export S3_SECRET_KEY="${SECRET}"
export S3_SECURE="${S3_SECURE:-true}"
export S3_RAW_BUCKET="${S3_RAW_BUCKET:-raw-documents}"
export PYTHONPATH="${ROOT}${PYTHONPATH:+:$PYTHONPATH}"

echo "Using endpoint ${S3_ENDPOINT_URL}"
echo "Seeding synthetic samples (optional FOIA demos)..."
if ! python3 "${ROOT}/scripts/seed_dataset.py"; then
  echo "WARN: synthetic seed failed — continuing with scratch/ DocLayNet PDFs only."
fi

if [[ -d "${SCRATCH}" ]]; then
  echo "Uploading scratch PDFs from ${SCRATCH}..."
  python3 -c '
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["ROOT"])
from src.services.s3_client import S3Client
from src.services.settings import get_settings
settings = get_settings()
s3 = S3Client(settings)
s3.ensure_buckets()
scratch = Path(os.environ["SCRATCH"])
count = 0
for pdf in sorted(scratch.rglob("*.pdf")):
    key = f"hf/{pdf.name}"
    s3.upload_bytes(settings.s3_raw_bucket, key, pdf.read_bytes())
    count += 1
    if count % 25 == 0:
        print(f"  … uploaded {count}")
    else:
        print(f"Uploaded s3://{settings.s3_raw_bucket}/{key}")
print(f"Uploaded {count} scratch PDF(s)")
'
else
  echo "No scratch/datasets yet (optional). Run scripts/fetch_dataset.sh to pull HF samples."
fi

echo "Done."
