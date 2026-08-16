#!/usr/bin/env bash
# Apply Argo CD root Application after prereq + secrets checks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIP_CHECK=false
SKIP_OBS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-check) SKIP_CHECK=true; shift ;;
    --non-cloud) NON_CLOUD_FLAG="--non-cloud"; shift ;;
    --skip-observability) SKIP_OBS=true; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done
NON_CLOUD_FLAG="${NON_CLOUD_FLAG:-}"

if [[ "${SKIP_CHECK}" != true ]]; then
  OBS_FLAG=""
  [[ "${SKIP_OBS}" == true ]] && OBS_FLAG="--skip-observability"
  bash "${ROOT}/scripts/check_prerequisites.sh" ${NON_CLOUD_FLAG} ${OBS_FLAG}
fi

if [[ ! -f "${ROOT}/secrets/local/minio-root.yaml" ]]; then
  echo "No secrets/local/minio-root.yaml — run: scripts/setup_minio.sh --apply"
  exit 1
fi

# Ensure namespaces + secrets exist before Argo syncs workloads that mount them
bash "${ROOT}/scripts/setup_minio.sh" --apply

echo "Applying Argo CD root Application..."
oc apply -f "${ROOT}/.argocd/root-application.yaml"

echo "Waiting for Argo Applications (up to ~5m)..."
for i in $(seq 1 60); do
  apps=$(oc get applications -n openshift-gitops -l app.kubernetes.io/part-of=auto-redaction-agent --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${apps}" -ge 1 ]]; then
    oc get applications -n openshift-gitops -l app.kubernetes.io/part-of=auto-redaction-agent || \
      oc get applications -n openshift-gitops
    break
  fi
  # root app may create children without the label initially
  oc get applications -n openshift-gitops 2>/dev/null | head -20 || true
  sleep 5
done

echo
echo "Watch sync: oc get applications -n openshift-gitops -w"
echo "UI route (when Ready): oc -n redaction-agent get route redaction-ui"
echo "Next: deploy catalog models (README Step 4), then scripts/fetch_dataset.sh && scripts/seed_minio.sh"
