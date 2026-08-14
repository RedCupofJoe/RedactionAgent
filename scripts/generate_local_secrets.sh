#!/usr/bin/env bash
# Generate OpenShift Secret manifests under secrets/local/ (gitignored).
# Optionally apply them to the cluster with --apply.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT}/secrets/local"
APPLY=false

usage() {
  cat <<'EOF'
Usage: scripts/generate_local_secrets.sh [--apply] [--from-env]

Creates gitignored Secret YAML files in secrets/local/:
  - minio-root.yaml
  - redaction-secrets.yaml          (namespace: redaction-agent)
  - redaction-secrets-mcp.yaml      (namespace: mcp-gateway)

Options:
  --apply      Run 'oc apply -f' on the generated files after writing them
  --from-env   Read values from environment (no prompts):
                 MINIO_ROOT_USER, MINIO_ROOT_PASSWORD,
                 LLM_API_KEY (optional), EMBEDDING_API_KEY (optional)
  -h, --help   Show this help

Examples:
  ./scripts/generate_local_secrets.sh
  MINIO_ROOT_USER=lab MINIO_ROOT_PASSWORD='s3cret' ./scripts/generate_local_secrets.sh --from-env --apply
EOF
}

FROM_ENV=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --from-env) FROM_ENV=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl is required to generate passwords." >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

gen_password() {
  openssl rand -base64 24 | tr -d '/+=' | head -c 32
}

if [[ "${FROM_ENV}" == true ]]; then
  MINIO_ROOT_USER="${MINIO_ROOT_USER:-}"
  MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-}"
  LLM_API_KEY="${LLM_API_KEY:-unused}"
  EMBEDDING_API_KEY="${EMBEDDING_API_KEY:-unused}"
  if [[ -z "${MINIO_ROOT_USER}" || -z "${MINIO_ROOT_PASSWORD}" ]]; then
    echo "ERROR: --from-env requires MINIO_ROOT_USER and MINIO_ROOT_PASSWORD." >&2
    exit 1
  fi
else
  echo "Generating local Secret manifests (will not be committed)."
  echo
  read -r -p "MinIO root user [minioadmin]: " MINIO_ROOT_USER
  MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"

  read -r -s -p "MinIO root password [auto-generate]: " MINIO_ROOT_PASSWORD
  echo
  if [[ -z "${MINIO_ROOT_PASSWORD}" ]]; then
    MINIO_ROOT_PASSWORD="$(gen_password)"
    echo "Generated MinIO password (saved only in secrets/local/)."
  fi

  read -r -p "LLM API key [unused]: " LLM_API_KEY
  LLM_API_KEY="${LLM_API_KEY:-unused}"

  read -r -p "Embedding API key [unused]: " EMBEDDING_API_KEY
  EMBEDDING_API_KEY="${EMBEDDING_API_KEY:-unused}"
fi

# Escape YAML double-quoted string values (minimal)
yaml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

USER_ESC="$(yaml_escape "${MINIO_ROOT_USER}")"
PASS_ESC="$(yaml_escape "${MINIO_ROOT_PASSWORD}")"
LLM_ESC="$(yaml_escape "${LLM_API_KEY}")"
EMBED_ESC="$(yaml_escape "${EMBEDDING_API_KEY}")"

cat > "${OUT_DIR}/minio-root.yaml" <<EOF
# GENERATED — do not commit (see secrets/local/ in .gitignore)
apiVersion: v1
kind: Secret
metadata:
  name: minio-root
  namespace: minio
  labels:
    app.kubernetes.io/part-of: auto-redaction-agent
type: Opaque
stringData:
  rootUser: "${USER_ESC}"
  rootPassword: "${PASS_ESC}"
EOF

cat > "${OUT_DIR}/redaction-secrets.yaml" <<EOF
# GENERATED — do not commit (see secrets/local/ in .gitignore)
apiVersion: v1
kind: Secret
metadata:
  name: redaction-secrets
  namespace: redaction-agent
  labels:
    app.kubernetes.io/part-of: auto-redaction-agent
type: Opaque
stringData:
  S3_ACCESS_KEY: "${USER_ESC}"
  S3_SECRET_KEY: "${PASS_ESC}"
  LLM_API_KEY: "${LLM_ESC}"
  EMBEDDING_API_KEY: "${EMBED_ESC}"
EOF

cat > "${OUT_DIR}/redaction-secrets-mcp.yaml" <<EOF
# GENERATED — do not commit (see secrets/local/ in .gitignore)
apiVersion: v1
kind: Secret
metadata:
  name: redaction-secrets
  namespace: mcp-gateway
  labels:
    app.kubernetes.io/part-of: auto-redaction-agent
type: Opaque
stringData:
  S3_ACCESS_KEY: "${USER_ESC}"
  S3_SECRET_KEY: "${PASS_ESC}"
  LLM_API_KEY: "${LLM_ESC}"
  EMBEDDING_API_KEY: "${EMBED_ESC}"
EOF

chmod 600 "${OUT_DIR}"/*.yaml

echo
echo "Wrote:"
ls -la "${OUT_DIR}"/*.yaml
echo
echo "These files are gitignored. Apply with:"
echo "  oc apply -f secrets/local/"
echo "Or re-run this script with --apply."

if [[ "${APPLY}" == true ]]; then
  if ! command -v oc >/dev/null 2>&1; then
    echo "ERROR: --apply requires oc in PATH." >&2
    exit 1
  fi
  echo
  echo "Applying secrets to the cluster..."
  oc apply -f "${OUT_DIR}/minio-root.yaml"
  oc apply -f "${OUT_DIR}/redaction-secrets.yaml"
  oc apply -f "${OUT_DIR}/redaction-secrets-mcp.yaml"
  echo "Done."
fi
