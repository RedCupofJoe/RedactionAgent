#!/usr/bin/env bash
# Fail-fast prerequisite checker for the Auto Redaction / Discovery lab.
# Operators are assumed installed by the cluster admin; this script only verifies.
set -euo pipefail

NON_CLOUD=false
STRICT_OBS=true

usage() {
  cat <<'EOF'
Usage: scripts/check_prerequisites.sh [--non-cloud] [--skip-observability]

Checks (must pass unless noted):
  - oc login / cluster reachability
  - OpenShift GitOps (Argo CD)
  - Red Hat OpenShift AI (DataScienceCluster)
  - NVIDIA GPU Operator / allocatable GPUs (prefer L4 / g6.xlarge)
  - OpenShift Observability Operator (required for demo traces)
  - NFD + StorageClass: required with --non-cloud; warn-only on cloud

Exit code 0 = ready to deploy; non-zero = fix listed errors first.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-cloud) NON_CLOUD=true; shift ;;
    --skip-observability) STRICT_OBS=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

RED=$'\033[31m';GREEN=$'\033[32m';YELLOW=$'\033[33m';NC=$'\033[0m'
ERRORS=0
WARNINGS=0

ok() { echo "${GREEN}OK${NC}  $*"; }
warn() { echo "${YELLOW}WARN${NC} $*"; WARNINGS=$((WARNINGS + 1)); }
fail() { echo "${RED}FAIL${NC} $*"; ERRORS=$((ERRORS + 1)); }

echo "=== Lab prerequisite check ==="
echo

if ! command -v oc >/dev/null 2>&1; then
  fail "oc CLI not found. Install OpenShift CLI and retry."
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  fail "Not logged in. Run: oc login <api-url>"
  exit 1
fi
ok "Logged in as $(oc whoami) on $(oc whoami --show-server 2>/dev/null || echo cluster)"

# GitOps
if oc get ns openshift-gitops >/dev/null 2>&1; then
  if oc get pods -n openshift-gitops --no-headers 2>/dev/null | grep -qiE 'Running|Completed'; then
    ok "OpenShift GitOps namespace present with running pods"
  else
    fail "openshift-gitops exists but pods are not healthy"
  fi
  if ! oc api-resources | grep -q applications.argoproj.io; then
    fail "Argo CD Application CRD missing (GitOps not fully installed)"
  else
    ok "Argo CD Application CRD available"
  fi
else
  fail "OpenShift GitOps not found. Install the OpenShift GitOps Operator first."
fi

# OpenShift AI
if oc get datasciencecluster -A >/dev/null 2>&1; then
  DSC_COUNT=$(oc get datasciencecluster -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${DSC_COUNT}" -ge 1 ]]; then
    ok "OpenShift AI DataScienceCluster found (${DSC_COUNT})"
  else
    fail "No DataScienceCluster. Install/configure Red Hat OpenShift AI."
  fi
else
  fail "Cannot query DataScienceCluster. Is OpenShift AI installed?"
fi

# GPU
GPU_NODES=$(oc get nodes -o json 2>/dev/null | grep -c 'nvidia.com/gpu' || true)
if oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | grep -qE '^[1-9]'; then
  ok "Nodes with allocatable nvidia.com/gpu found"
  if oc get nodes -o json 2>/dev/null | grep -qiE 'NVIDIA-L4|Tesla-L4|L4'; then
    ok "L4-class GPU labels detected (good for g6.xlarge lab sizing)"
  else
    warn "No explicit L4 product label found. Lab assumes 3× g6.xlarge (L4). Verify hardware profiles."
  fi
else
  fail "No allocatable GPUs. Install NVIDIA GPU Operator and ensure GPU nodes are Ready."
fi

# NFD
if oc get pods -A 2>/dev/null | grep -qiE 'nfd|node-feature-discovery'; then
  ok "Node Feature Discovery appears installed"
elif [[ "${NON_CLOUD}" == true ]]; then
  fail "NFD required for --non-cloud labs. Install Node Feature Discovery Operator."
else
  warn "NFD not detected (acceptable on many managed cloud clusters)"
fi

# Storage
if oc get storageclass >/dev/null 2>&1; then
  if oc get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -q .; then
    ok "StorageClass(es) present: $(oc get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')"
  elif [[ "${NON_CLOUD}" == true ]]; then
    fail "No StorageClass. Install a Storage Operator / CSI for --non-cloud."
  else
    warn "No StorageClass listed"
  fi
else
  fail "Cannot list StorageClass"
fi

# Observability
OBS_OK=false
if oc get csv -A 2>/dev/null | grep -qiE 'cluster-observability|observability-operator|tempo-operator|opentelemetry'; then
  OBS_OK=true
fi
if oc get ns openshift-operators 2>/dev/null | grep -q .; then
  if oc get pods -A 2>/dev/null | grep -qiE 'opentelemetry-operator|tempo-operator|observability-operator'; then
    OBS_OK=true
  fi
fi
if [[ "${OBS_OK}" == true ]]; then
  ok "Observability / OpenTelemetry / Tempo related operators detected"
else
  if [[ "${STRICT_OBS}" == true ]]; then
    fail "Observability Operator not detected. Install Red Hat OpenShift Observability (and Tempo/OpenTelemetry as required) BEFORE deploy_lab.sh."
  else
    warn "Observability Operator not detected (--skip-observability)"
  fi
fi

echo
if [[ "${ERRORS}" -gt 0 ]]; then
  echo "${RED}${ERRORS} error(s), ${WARNINGS} warning(s). Fix errors before deploying.${NC}"
  exit 1
fi
echo "${GREEN}Prerequisites OK${NC} (${WARNINGS} warning(s)). You may continue with secrets + GitOps deploy."
exit 0
