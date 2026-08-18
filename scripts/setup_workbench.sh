#!/usr/bin/env bash
# Step 9 — create an OpenShift AI Workbench preloaded with the lab walkthrough notebook.
#
# Usage:
#   ./scripts/setup_workbench.sh              # create + wait + copy notebooks + print URLs
#   ./scripts/setup_workbench.sh --seed-only  # only copy notebooks into an existing workbench
#   ./scripts/setup_workbench.sh --delete     # tear down the workbench + PVC
#
# Demo tip: run this before your audience arrives, then open the printed Workbench URL.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${WORKBENCH_NAMESPACE:-rhoai-models}"
NAME="${WORKBENCH_NAME:-lab-walkthrough}"
IMAGE_TAG="${WORKBENCH_IMAGE_TAG:-3.4}"
IMAGE="${WORKBENCH_IMAGE:-image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/s2i-generic-data-science-notebook:${IMAGE_TAG}}"
SEED_ONLY=false
DELETE=false
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

usage() {
  cat <<'EOF'
Usage: scripts/setup_workbench.sh [--namespace NS] [--name NAME] [--seed-only] [--delete]

Creates an OpenShift AI Workbench (Notebook CR) in a Data Science project, copies
notebooks/lab_walkthrough.ipynb into it, and prints audience-ready URLs.

Env overrides:
  WORKBENCH_NAMESPACE   default: rhoai-models
  WORKBENCH_NAME        default: lab-walkthrough
  WORKBENCH_IMAGE_TAG   default: 3.4
  WAIT_TIMEOUT          seconds to wait for Running (default 300)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --seed-only) SEED_ONLY=true; shift ;;
    --delete) DELETE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1"; usage; exit 1 ;;
  esac
done

need_oc() {
  command -v oc >/dev/null 2>&1 || { echo "oc CLI required"; exit 1; }
  oc whoami >/dev/null 2>&1 || { echo "oc login required"; exit 1; }
}

dashboard_host() {
  oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null \
    || oc get route -n redhat-ods-applications -o jsonpath='{.items[0].spec.host}' 2>/dev/null \
    || true
}

print_demo_card() {
  local dash="$1"
  local wb_url="https://${dash}/projects/${NS}?notebookName=${NAME}"
  local notebook_route
  notebook_route=$(oc get route -n "${NS}" -o jsonpath="{.items[?(@.metadata.name=='${NAME}')].spec.host}" 2>/dev/null || true)
  if [[ -z "${notebook_route}" ]]; then
    notebook_route=$(oc get route -n "${NS}" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
  fi
  local redact_route disco_route ui_route
  redact_route=$(oc get route -n redaction-agent redaction-agent-api -o jsonpath='{.spec.host}' 2>/dev/null || true)
  disco_route=$(oc get route -n discovery-agent discovery-agent-api -o jsonpath='{.spec.host}' 2>/dev/null || true)
  ui_route=$(oc get route -n redaction-agent redaction-ui -o jsonpath='{.spec.host}' 2>/dev/null || true)

  cat <<EOF

══════════════════════════════════════════════════════════════════
  Step 9 — Audience walkthrough (ready)
══════════════════════════════════════════════════════════════════

  OpenShift AI project:  ${NS}
  Workbench name:        ${NAME}

  Direct notebook URL (use this for the demo):
    https://${dash}/notebook/${NS}/${NAME}/lab

  Dashboard project page:
    https://${dash}/projects/${NS}
${notebook_route:+
  Workbench Route (OAuth):
    https://${notebook_route}
}

  In-cluster APIs (already set as env in the workbench):
    REDACT_API_URL=http://redaction-agent.redaction-agent.svc.cluster.local:8000
    DISCOVERY_API_URL=http://discovery-agent.discovery-agent.svc.cluster.local:8001

  Optional laptop Routes (for side-by-side demos):
    Redaction API:  ${redact_route:+https://${redact_route}}
    Discovery API:   ${disco_route:+https://${disco_route}}
    Streamlit UI:    ${ui_route:+https://${ui_route}}

  Talk track (Run All / cell-by-cell):
    1. Health checks — both agents return ok
    2. List documents — MinIO raw-documents
    3. Redact first PDF — Jordan Hale / Plant B / July 2021
    4. Discovery — index + search "chemical spill at Plant B"
    5. Optional: Tempo traces + Streamlit UI tabs

  Notebook file in workbench home:
    /opt/app-root/src/lab_walkthrough.ipynb

══════════════════════════════════════════════════════════════════
EOF
}

delete_workbench() {
  echo "Deleting Notebook/${NAME} and PVC/${NAME} in ${NS}..."
  oc delete notebook -n "${NS}" "${NAME}" --ignore-not-found=true --wait=true
  oc delete pvc -n "${NS}" "${NAME}" --ignore-not-found=true --wait=false
  echo "Deleted (PVC may take a moment to release)."
}

ensure_project() {
  oc get ns "${NS}" >/dev/null 2>&1 || oc create namespace "${NS}"
  oc label namespace "${NS}" \
    opendatahub.io/dashboard=true \
    modelmesh-enabled=true \
    --overwrite >/dev/null
  # Display name for the dashboard project list
  oc annotate namespace "${NS}" \
    openshift.io/display-name="OpenShift AI Lab Models" \
    --overwrite >/dev/null 2>&1 || true
}

apply_workbench() {
  local dash="$1"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN

  sed "s/name: lab-walkthrough/name: ${NAME}/" "${ROOT}/manifests/workbench/pvc.yaml" \
    | oc apply -n "${NS}" -f -

  sed \
    -e "s/__NS__/${NS}/g" \
    -e "s/__NAME__/${NAME}/g" \
    -e "s/__DASHBOARD__/${dash}/g" \
    -e "s|__IMAGE__|${IMAGE}|g" \
    -e "s/__IMAGE_TAG__/${IMAGE_TAG}/g" \
    "${ROOT}/manifests/workbench/notebook.yaml.tmpl" > "${tmp}/notebook.yaml"

  # Clear stop annotation if re-running on a stopped workbench
  oc apply -f "${tmp}/notebook.yaml"
  oc annotate notebook -n "${NS}" "${NAME}" kubeflow-resource-stopped- --overwrite >/dev/null 2>&1 || true
}

wait_running() {
  echo "Waiting up to ${WAIT_TIMEOUT}s for Notebook/${NAME} pods Running..."
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  while (( SECONDS < deadline )); do
    local phase ready
    phase=$(oc get notebook -n "${NS}" "${NAME}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    ready=$(oc get pods -n "${NS}" -l notebook-name="${NAME}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
    if [[ "${phase}" == "1" ]] || [[ "${ready}" == "Running" ]]; then
      # Prefer container ready
      if oc get pods -n "${NS}" -l notebook-name="${NAME}" -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
        echo "Workbench is Running."
        return 0
      fi
      if [[ "${ready}" == "Running" ]]; then
        echo "Pod Running (containers still starting)..."
      fi
    fi
    oc get pods -n "${NS}" -l notebook-name="${NAME}" --no-headers 2>/dev/null || true
    sleep 5
  done
  echo "WARN: timed out waiting for workbench. Check: oc get notebook,pods -n ${NS}"
  oc get notebook -n "${NS}" "${NAME}" -o yaml | sed -n '1,80p' || true
  return 1
}

seed_notebooks() {
  local pod
  pod=$(oc get pods -n "${NS}" -l notebook-name="${NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "${pod}" ]]; then
    echo "No workbench pod found in ${NS} (label notebook-name=${NAME})."
    exit 1
  fi
  echo "Copying walkthrough into ${pod}:/opt/app-root/src/ ..."
  # Target the notebook container (not oauth-proxy)
  local container="${NAME}"
  oc cp "${ROOT}/notebooks/lab_walkthrough.ipynb" "${NS}/${pod}:/opt/app-root/src/lab_walkthrough.ipynb" -c "${container}"
  oc cp "${ROOT}/notebooks/lab_walkthrough.py" "${NS}/${pod}:/opt/app-root/src/lab_walkthrough.py" -c "${container}"
  # Ensure httpx is available for the demo cells
  oc exec -n "${NS}" "${pod}" -c "${container}" -- \
    python3 -c 'import httpx' 2>/dev/null \
    || oc exec -n "${NS}" "${pod}" -c "${container}" -- \
      python3 -m pip install --user -q httpx
  echo "Seeded lab_walkthrough.ipynb + lab_walkthrough.py"
}

# --- main ---
need_oc

if [[ "${DELETE}" == true ]]; then
  delete_workbench
  exit 0
fi

DASH="$(dashboard_host)"
if [[ -z "${DASH}" ]]; then
  echo "ERROR: could not find rhods-dashboard Route in redhat-ods-applications"
  exit 1
fi
echo "OpenShift AI dashboard: https://${DASH}"

if [[ "${SEED_ONLY}" == true ]]; then
  seed_notebooks
  print_demo_card "${DASH}"
  exit 0
fi

ensure_project
apply_workbench "${DASH}"
wait_running || true
seed_notebooks
print_demo_card "${DASH}"
