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

# Prefer lab user; if unset, parse MinIO root from secrets/local (admin can create buckets).
if [[ -z "${ACCESS}" || -z "${SECRET}" ]]; then
  ROOT_YAML="${ROOT}/secrets/local/minio-root.yaml"
  if [[ -f "${ROOT_YAML}" ]]; then
    ACCESS="$(python3 -c 'import re,sys; t=open(sys.argv[1]).read(); m=re.search(r"rootUser:\s*\"?([^\n\"]+)\"?", t); print(m.group(1) if m else "")' "${ROOT_YAML}")"
    SECRET="$(python3 -c 'import re,sys; t=open(sys.argv[1]).read(); m=re.search(r"rootPassword:\s*\"?([^\n\"]+)\"?", t); print(m.group(1) if m else "")' "${ROOT_YAML}")"
    echo "Using MinIO root credentials from secrets/local/minio-root.yaml (lab user not set)."
  fi
fi
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

# Ensure laptop Python has the few packages seed scripts need (base conda often lacks them).
python3 - <<'PY'
import importlib, subprocess, sys
need = []
for mod, pkg in [("boto3", "boto3"), ("fitz", "pymupdf"), ("pydantic_settings", "pydantic-settings"), ("yaml", "pyyaml")]:
    try:
        importlib.import_module(mod)
    except ImportError:
        need.append(pkg)
if need:
    print(f"Installing: {', '.join(need)}")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", *need])
PY

# If lab keys are InvalidAccessKeyId (bucket Job never created the user), fall back to root.
rm -f "${ROOT}/scratch/.seed_minio_creds.env"
python3 - <<'PY'
import os, re, sys
from pathlib import Path
from botocore.client import Config
from botocore.exceptions import ClientError
import boto3

endpoint = os.environ["S3_ENDPOINT_URL"]
access, secret = os.environ["S3_ACCESS_KEY"], os.environ["S3_SECRET_KEY"]
cfg = Config(signature_version="s3v4", s3={"addressing_style": "path"})

def client(ak, sk):
    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=ak,
        aws_secret_access_key=sk,
        region_name="us-east-1",
        config=cfg,
    )

def ok(ak, sk):
    try:
        client(ak, sk).list_buckets()
        return True
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        print(f"S3 auth check failed ({code}): {e.response.get('Error', {}).get('Message', e)}")
        return False

if ok(access, secret):
    print(f"S3 credentials OK against {endpoint}")
    sys.exit(0)

root_yaml = Path(os.environ["ROOT"]) / "secrets/local/minio-root.yaml"
if not root_yaml.exists():
    print("Lab/S3 keys rejected and no secrets/local/minio-root.yaml for fallback.", file=sys.stderr)
    sys.exit(1)
text = root_yaml.read_text()
ru = re.search(r'rootUser:\s*"?([^\n"]+)"?', text)
rp = re.search(r'rootPassword:\s*"?([^\n"]+)"?', text)
if not ru or not rp:
    print("Could not parse minio-root.yaml", file=sys.stderr)
    sys.exit(1)
ru, rp = ru.group(1), rp.group(1)
if access == ru:
    print("Root credentials also failed — is MinIO up and does minio-root match the server?", file=sys.stderr)
    sys.exit(1)
if not ok(ru, rp):
    print("Root fallback also failed.", file=sys.stderr)
    sys.exit(1)
print("Lab user invalid (buckets Job likely never created it). Falling back to MinIO root for this seed.")
# Write for the parent shell via a tiny env file in scratch (gitignored).
out = Path(os.environ["ROOT"]) / "scratch" / ".seed_minio_creds.env"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(f"S3_ACCESS_KEY={ru}\nS3_SECRET_KEY={rp}\n")
out.chmod(0o600)
print(f"WROTE_FALLBACK={out}")
PY
FALLBACK_RC=$?
if [[ "${FALLBACK_RC}" -ne 0 ]]; then
  echo "Cannot authenticate to MinIO. Fix the create-buckets Job (HOME=/tmp) then re-run, or check secrets."
  exit 1
fi
if [[ -f "${ROOT}/scratch/.seed_minio_creds.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT}/scratch/.seed_minio_creds.env"
  export S3_ACCESS_KEY S3_SECRET_KEY
  rm -f "${ROOT}/scratch/.seed_minio_creds.env"
fi

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
