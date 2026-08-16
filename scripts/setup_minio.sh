#!/usr/bin/env bash
# Generate MinIO root + lab-user Secrets (gitignored) and optionally apply them.
# Reuses existing secrets/local files if present unless --force.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/secrets/local"
APPLY=false
FORCE=false
FROM_ENV=false

usage() {
  cat <<'EOF'
Usage: scripts/setup_minio.sh [--apply] [--force] [--from-env]

Creates:
  secrets/local/minio-root.yaml          (MinIO admin/root)
  secrets/local/minio-lab-user.yaml      (app user, mirrored to agent namespaces)
  secrets/local/redaction-secrets.yaml
  secrets/local/discovery-secrets.yaml
  secrets/local/mcp-secrets.yaml

Env (--from-env):
  MINIO_ROOT_USER, MINIO_ROOT_PASSWORD, MINIO_LAB_USER, MINIO_LAB_PASSWORD
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --force) FORCE=true; shift ;;
    --from-env) FROM_ENV=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; usage; exit 1 ;;
  esac
done

mkdir -p "${OUT}"
gen_password() { openssl rand -base64 24 | tr -d '/+=' | head -c 32; }
yaml_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

if [[ "${FORCE}" != true && -f "${OUT}/minio-root.yaml" && -f "${OUT}/minio-lab-user.yaml" ]]; then
  echo "Existing secrets/local MinIO files found (reuse). Pass --force to regenerate."
else
  if [[ "${FROM_ENV}" == true ]]; then
    MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
    MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-}"
    MINIO_LAB_USER="${MINIO_LAB_USER:-labuser}"
    MINIO_LAB_PASSWORD="${MINIO_LAB_PASSWORD:-}"
    [[ -n "${MINIO_ROOT_PASSWORD}" ]] || { echo "MINIO_ROOT_PASSWORD required with --from-env"; exit 1; }
    [[ -n "${MINIO_LAB_PASSWORD}" ]] || MINIO_LAB_PASSWORD="$(gen_password)"
  else
    echo "Generating MinIO admin + lab-user credentials (gitignored)."
    read -r -p "MinIO root user [minioadmin]: " MINIO_ROOT_USER
    MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
    read -r -s -p "MinIO root password [auto]: " MINIO_ROOT_PASSWORD; echo
    [[ -n "${MINIO_ROOT_PASSWORD}" ]] || MINIO_ROOT_PASSWORD="$(gen_password)"
    read -r -p "MinIO lab user [labuser]: " MINIO_LAB_USER
    MINIO_LAB_USER="${MINIO_LAB_USER:-labuser}"
    read -r -s -p "MinIO lab password [auto]: " MINIO_LAB_PASSWORD; echo
    [[ -n "${MINIO_LAB_PASSWORD}" ]] || MINIO_LAB_PASSWORD="$(gen_password)"
  fi

  R_USER="$(yaml_escape "${MINIO_ROOT_USER}")"
  R_PASS="$(yaml_escape "${MINIO_ROOT_PASSWORD}")"
  L_USER="$(yaml_escape "${MINIO_LAB_USER}")"
  L_PASS="$(yaml_escape "${MINIO_LAB_PASSWORD}")"

  cat > "${OUT}/minio-root.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: minio-root
  namespace: minio
  labels:
    app.kubernetes.io/part-of: auto-redaction-agent
type: Opaque
stringData:
  rootUser: "${R_USER}"
  rootPassword: "${R_PASS}"
EOF

  # Lab user secret mirrored into app namespaces (same keys agents expect)
  for ns in minio redaction-agent discovery-agent mcp-gateway; do
    case "${ns}" in
      minio) name=minio-lab-user; file="${OUT}/minio-lab-user.yaml" ;;
      redaction-agent) name=redaction-secrets; file="${OUT}/redaction-secrets.yaml" ;;
      discovery-agent) name=discovery-secrets; file="${OUT}/discovery-secrets.yaml" ;;
      mcp-gateway) name=redaction-secrets; file="${OUT}/mcp-secrets.yaml" ;;
    esac
    cat > "${file}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app.kubernetes.io/part-of: auto-redaction-agent
type: Opaque
stringData:
  S3_ACCESS_KEY: "${L_USER}"
  S3_SECRET_KEY: "${L_PASS}"
  rootUser: "${L_USER}"
  rootPassword: "${L_PASS}"
  accessKey: "${L_USER}"
  secretKey: "${L_PASS}"
  LLM_API_KEY: unused
  EMBEDDING_API_KEY: unused
EOF
  done
  # Keep lab user credentials for mc user create job
  cat > "${OUT}/minio-lab-user-creds.env" <<EOF
MINIO_LAB_USER=${MINIO_LAB_USER}
MINIO_LAB_PASSWORD=${MINIO_LAB_PASSWORD}
EOF
  chmod 600 "${OUT}"/* || true
  echo "Wrote secrets under ${OUT}"
fi

if [[ "${APPLY}" == true ]]; then
  command -v oc >/dev/null || { echo "oc required for --apply"; exit 1; }
  for ns in minio redaction-agent discovery-agent mcp-gateway rhoai-models; do
    oc get ns "${ns}" >/dev/null 2>&1 || oc create ns "${ns}"
  done
  oc apply -f "${OUT}/minio-root.yaml"
  oc apply -f "${OUT}/minio-lab-user.yaml"
  oc apply -f "${OUT}/redaction-secrets.yaml"
  oc apply -f "${OUT}/discovery-secrets.yaml"
  oc apply -f "${OUT}/mcp-secrets.yaml"
  echo "Secrets applied. Ensure MinIO PostSync job creates buckets + lab user."
fi
