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

# OpenShift GitOps only manages namespaces labeled for it (otherwise syncs fail with Forbidden).
# The default managed-by Role also cannot create ResourceQuotas — grant admin for lab namespaces.
LAB_NS=(redaction-agent discovery-agent mcp-gateway minio lab-observability rhoai-models)
ARGO_SA="system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller"
echo "Labeling lab namespaces for openshift-gitops + granting admin to application-controller..."
for ns in "${LAB_NS[@]}"; do
  oc get ns "${ns}" >/dev/null 2>&1 || oc create namespace "${ns}"
  oc label namespace "${ns}" argocd.argoproj.io/managed-by=openshift-gitops --overwrite >/dev/null
  oc adm policy add-role-to-user admin "${ARGO_SA}" -n "${ns}" >/dev/null
done

echo "Applying Argo CD root Application..."
oc apply -f "${ROOT}/.argocd/root-application.yaml"

# Force sync — apps that already exhausted retries stay OutOfSync until a new operation.
ARGO_APP="applications.argoproj.io"
echo "Triggering sync on lab Applications..."
sleep 5
for app in $(oc get "${ARGO_APP}" -n openshift-gitops -o name 2>/dev/null | grep -E 'redaction|discovery|mcp|minio|lab-observability|rhoai|auto-redaction' || true); do
  oc -n openshift-gitops patch "${app}" --type merge \
    -p '{"operation":{"initiatedBy":{"username":"deploy-lab"},"sync":{"revision":"HEAD"}}}' >/dev/null 2>&1 || true
done

echo "Waiting for Argo Applications (up to ~5m)..."
# NOTE: use applications.argoproj.io — bare 'applications' is OpenShift app.k8s.io, not Argo CD.
for i in $(seq 1 60); do
  apps=$(oc get "${ARGO_APP}" -n openshift-gitops -l app.kubernetes.io/part-of=auto-redaction-agent --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${apps}" -ge 1 ]]; then
    oc get "${ARGO_APP}" -n openshift-gitops -l app.kubernetes.io/part-of=auto-redaction-agent || \
      oc get "${ARGO_APP}" -n openshift-gitops
    break
  fi
  oc get "${ARGO_APP}" -n openshift-gitops 2>/dev/null | head -20 || true
  sleep 5
done

echo
echo "Watch sync: oc get applications.argoproj.io -n openshift-gitops -w"
echo "  (do not use plain 'oc get applications' — that lists app.k8s.io, not Argo CD)"
echo "UI route (when Ready): oc -n redaction-agent get route redaction-ui"
echo "Next: deploy catalog models (README Step 5), then scripts/fetch_dataset.sh && scripts/seed_minio.sh"
