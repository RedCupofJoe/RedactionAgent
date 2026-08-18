#!/usr/bin/env bash
# Step 9 — copy lab_walkthrough into an existing OpenShift AI Workbench.
#
# Create the workbench in the OpenShift AI dashboard first (see README Step 9),
# then run this script to place notebooks/lab_walkthrough.ipynb in the home dir.
#
# Usage:
#   ./scripts/setup_workbench.sh
#   ./scripts/setup_workbench.sh --namespace rhoai-models --name my-workbench
#   ./scripts/setup_workbench.sh --list
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${WORKBENCH_NAMESPACE:-rhoai-models}"
NAME="${WORKBENCH_NAME:-}"
LIST_ONLY=false
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"

usage() {
  cat <<'EOF'
Usage: scripts/setup_workbench.sh [--namespace NS] [--name WORKBENCH] [--list]

Copies notebooks/lab_walkthrough.ipynb (+ .py) into a Running OpenShift AI
Workbench. Create the workbench in the dashboard first (README Step 9).

Options:
  --namespace NS   Project/namespace (default: rhoai-models)
  --name NAME      Workbench / Notebook name (default: only Running notebook, or prompt)
  --list           List Notebooks in the namespace and exit

Env:
  WORKBENCH_NAMESPACE, WORKBENCH_NAME, WAIT_TIMEOUT
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --list) LIST_ONLY=true; shift ;;
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

list_notebooks() {
  echo "Notebooks in ${NS}:"
  if ! oc get notebook -n "${NS}" --no-headers 2>/dev/null | grep -q .; then
    echo "  (none — create a Workbench in the OpenShift AI UI first)"
    return 1
  fi
  oc get notebook -n "${NS}" -o custom-columns=\
NAME:.metadata.name,DISPLAY:.metadata.annotations.openshift\\.io/display-name,READY:.status.readyReplicas
}

resolve_name() {
  if [[ -n "${NAME}" ]]; then
    return 0
  fi
  local names
  names=$(oc get notebook -n "${NS}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  if [[ -z "${names}" ]]; then
    echo "ERROR: no Workbench/Notebook found in ${NS}."
    echo "Create one in OpenShift AI (README Step 9), then re-run:"
    echo "  ./scripts/setup_workbench.sh --namespace ${NS} --name <workbench-name>"
    exit 1
  fi
  # Prefer a single match; if several, require --name
  # shellcheck disable=SC2206
  local arr=(${names})
  if [[ "${#arr[@]}" -eq 1 ]]; then
    NAME="${arr[0]}"
    echo "Using workbench: ${NAME}"
    return 0
  fi
  echo "Multiple workbenches in ${NS}. Pass --name:"
  list_notebooks || true
  exit 1
}

notebook_container() {
  local pod="$1"
  pod="${pod##*/}" # strip pod/ prefix if present
  # UI-created notebooks: container name usually matches the Notebook name.
  local names
  names=$(oc get "pod/${pod}" -n "${NS}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)
  if printf '%s\n' ${names} | grep -qx "${NAME}"; then
    echo "${NAME}"
    return
  fi
  # Prefer first non-oauth / non-proxy container
  printf '%s\n' ${names} | grep -Ev 'oauth|proxy|sidecar' | head -1
}

wait_running() {
  echo "Waiting up to ${WAIT_TIMEOUT}s for Notebook/${NAME} to be Running..." >&2
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  while (( SECONDS < deadline )); do
    local pod phase ready
    pod=$(oc get pods -n "${NS}" -l "notebook-name=${NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    pod="${pod##*/}"
    if [[ -n "${pod}" ]]; then
      phase=$(oc get "pod/${pod}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      ready=$(oc get "pod/${pod}" -n "${NS}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
      if [[ "${phase}" == "Running" && "${ready}" == "true" ]]; then
        echo "Workbench pod ${pod} is Ready." >&2
        # Only the pod name goes to stdout (callers capture this).
        echo "${pod}"
        return 0
      fi
      echo "  ${pod}: phase=${phase} ready=${ready}" >&2
    else
      echo "  waiting for pod (label notebook-name=${NAME})..." >&2
    fi
    sleep 5
  done
  echo "ERROR: workbench not Ready. Is it Started in the OpenShift AI UI?" >&2
  oc get notebook -n "${NS}" >&2 || true
  oc get pods -n "${NS}" >&2 || true
  exit 1
}

seed_notebooks() {
  local pod="$1"
  pod="${pod##*/}"
  # If capture accidentally included progress lines, keep the last non-empty line.
  pod=$(printf '%s\n' "${pod}" | awk 'NF{p=$0} END{print p}')
  local container
  container="$(notebook_container "${pod}")"
  if [[ -z "${container}" ]]; then
    echo "ERROR: could not find notebook container in ${pod}"
    oc get "pod/${pod}" -n "${NS}" -o jsonpath='{.spec.containers[*].name}{"\n"}'
    exit 1
  fi
  echo "Copying walkthrough into ${pod} (container ${container}):/opt/app-root/src/ ..."
  oc cp "${ROOT}/notebooks/lab_walkthrough.ipynb" "${NS}/${pod}:/opt/app-root/src/lab_walkthrough.ipynb" -c "${container}"
  oc cp "${ROOT}/notebooks/lab_walkthrough.py" "${NS}/${pod}:/opt/app-root/src/lab_walkthrough.py" -c "${container}"
  oc exec -n "${NS}" "${pod}" -c "${container}" -- \
    python3 -c 'import httpx' 2>/dev/null \
    || oc exec -n "${NS}" "${pod}" -c "${container}" -- \
      python3 -m pip install --user -q httpx
  echo "Seeded lab_walkthrough.ipynb + lab_walkthrough.py"
}

print_demo_card() {
  local dash="$1"
  local redact_route disco_route ui_route
  redact_route=$(oc get route -n redaction-agent redaction-agent-api -o jsonpath='{.spec.host}' 2>/dev/null || true)
  disco_route=$(oc get route -n discovery-agent discovery-agent-api -o jsonpath='{.spec.host}' 2>/dev/null || true)
  ui_route=$(oc get route -n redaction-agent redaction-ui -o jsonpath='{.spec.host}' 2>/dev/null || true)

  cat <<EOF

══════════════════════════════════════════════════════════════════
  Step 9 — Walkthrough notebook seeded
══════════════════════════════════════════════════════════════════

  Project:     ${NS}
  Workbench:   ${NAME}

  Open in OpenShift AI:
    https://${dash}/projects/${NS}
    then Open the workbench → lab_walkthrough.ipynb

  Notebook path in workbench:
    /opt/app-root/src/lab_walkthrough.ipynb

  In-cluster API defaults (used by the notebook if env unset):
    http://redaction-agent.redaction-agent.svc.cluster.local:8000
    http://discovery-agent.discovery-agent.svc.cluster.local:8001

  Optional laptop Routes:
    Redaction:  ${redact_route:+https://${redact_route}}
    Discovery:  ${disco_route:+https://${disco_route}}
    Streamlit:  ${ui_route:+https://${ui_route}}

  Talk track:
    1. Health checks
    2. List documents
    3. Redact (Jordan Hale / Plant B / July 2021)
    4. Discovery search ("chemical spill at Plant B")

══════════════════════════════════════════════════════════════════
EOF
}

# --- main ---
need_oc

if [[ "${LIST_ONLY}" == true ]]; then
  list_notebooks
  exit $?
fi

if ! oc get ns "${NS}" >/dev/null 2>&1; then
  echo "ERROR: namespace ${NS} not found."
  exit 1
fi

resolve_name

if ! oc get notebook -n "${NS}" "${NAME}" >/dev/null 2>&1; then
  echo "ERROR: Notebook/${NAME} not found in ${NS}."
  echo "Create the workbench in the OpenShift AI UI, then re-run with --name."
  list_notebooks || true
  exit 1
fi

POD="$(wait_running)"
seed_notebooks "${POD}"

DASH="$(dashboard_host)"
if [[ -z "${DASH}" ]]; then
  echo "Seeded OK (could not resolve dashboard Route)."
  exit 0
fi
print_demo_card "${DASH}"
