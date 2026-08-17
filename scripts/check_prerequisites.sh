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
  - OpenShift GitOps Argo CD *instance* (not only the Operator)
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
HINTS=()

ok() { echo "${GREEN}OK${NC}  $*"; }
warn() { echo "${YELLOW}WARN${NC} $*"; WARNINGS=$((WARNINGS + 1)); }
fail() { echo "${RED}FAIL${NC} $*"; ERRORS=$((ERRORS + 1)); }
hint() { HINTS+=("$*"); }

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

# ---------------------------------------------------------------------------
# GitOps: Operator vs Argo CD instance
# ---------------------------------------------------------------------------
GITOPS_OPERATOR_NS=""
for ns in openshift-gitops-operator openshift-operators; do
  if oc get pods -n "${ns}" --no-headers 2>/dev/null | grep -qiE 'gitops-operator.*Running'; then
    GITOPS_OPERATOR_NS="${ns}"
    break
  fi
done

if [[ -n "${GITOPS_OPERATOR_NS}" ]]; then
  ok "OpenShift GitOps Operator pod Running in ${GITOPS_OPERATOR_NS}"
else
  warn "GitOps Operator controller pod not clearly detected (may still be installing)"
fi

# Application CRD
if oc api-resources 2>/dev/null | grep -q 'applications.argoproj.io'; then
  ok "Argo CD Application CRD available"
  CRD_OK=true
else
  fail "Argo CD Application CRD missing — GitOps instance not fully provisioned yet"
  CRD_OK=false
  hint "GitOps Operator ≠ Argo CD ready. Create/wait for the default ArgoCD instance:"
  hint "  oc get argocd -A"
  hint "  oc get pods -n openshift-gitops"
  hint "  # If namespace/instance missing, in OperatorHub open OpenShift GitOps → create default instance,"
  hint "  # or: oc apply an ArgoCD CR named openshift-gitops in namespace openshift-gitops"
fi

# Instance namespace + pods
if oc get ns openshift-gitops >/dev/null 2>&1; then
  RUNNING=$(oc get pods -n openshift-gitops --no-headers 2>/dev/null | grep -c ' Running' || true)
  TOTAL=$(oc get pods -n openshift-gitops --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${RUNNING}" -ge 1 ]]; then
    ok "openshift-gitops instance has ${RUNNING}/${TOTAL} Running pod(s)"
  else
    fail "openshift-gitops namespace exists but no Running pods (${TOTAL} listed)"
    hint "Inspect GitOps instance:"
    hint "  oc get pods -n openshift-gitops"
    hint "  oc get argocd -n openshift-gitops -o yaml | head -80"
    hint "  oc get events -n openshift-gitops --sort-by=.lastTimestamp | tail -20"
  fi
else
  fail "Namespace openshift-gitops missing (Argo CD instance not created)"
  hint "Operator is installed under openshift-gitops-operator, but the Argo CD *instance* was not created."
  hint "Create the default instance from the OpenShift console:"
  hint "  Operators → Installed Operators → OpenShift GitOps → Argo CD → Create ArgoCD"
  hint "  Name: openshift-gitops  Namespace: openshift-gitops (create namespace if needed)"
fi

# ---------------------------------------------------------------------------
# OpenShift AI
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# GPU
# ---------------------------------------------------------------------------
ALLOC=$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null || true)
if echo "${ALLOC}" | grep -qE '^[1-9]'; then
  ok "Nodes with allocatable nvidia.com/gpu found"
  if oc get nodes -o json 2>/dev/null | grep -qiE 'NVIDIA-L4|Tesla-L4|L4'; then
    ok "L4-class GPU labels detected (good for g6.xlarge lab sizing)"
  else
    warn "No explicit L4 product label found. Lab assumes 3× g6.xlarge (L4). Verify hardware profiles."
  fi
else
  fail "No allocatable GPUs on nodes (nvidia.com/gpu)"
  hint "Check GPU Operator / machine pool:"
  hint "  oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu"
  hint "  oc get csv -A | grep -i gpu"
  hint "  oc get pods -n nvidia-gpu-operator 2>/dev/null || oc get pods -A | grep -i nvidia | head"
  hint "  # On OpenShift AI / ROSA GPU workshops, wait until GPU MachineSet nodes are Ready"
fi

# ---------------------------------------------------------------------------
# NFD
# ---------------------------------------------------------------------------
if oc get pods -A 2>/dev/null | grep -qiE 'nfd|node-feature-discovery'; then
  ok "Node Feature Discovery appears installed"
elif [[ "${NON_CLOUD}" == true ]]; then
  fail "NFD required for --non-cloud labs. Install Node Feature Discovery Operator."
else
  warn "NFD not detected (acceptable on many managed cloud clusters)"
fi

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------
OBS_OK=false
if oc get csv -A 2>/dev/null | grep -qiE 'cluster-observability|observability-operator|tempo-operator|opentelemetry'; then
  OBS_OK=true
fi
if oc get pods -A 2>/dev/null | grep -qiE 'opentelemetry-operator|tempo-operator|observability-operator|coo-'; then
  OBS_OK=true
fi
if oc api-resources 2>/dev/null | grep -qiE 'opentelemetrycollectors|tempostacks'; then
  OBS_OK=true
fi
if [[ "${OBS_OK}" == true ]]; then
  ok "Observability / OpenTelemetry / Tempo related operators or CRDs detected"
else
  if [[ "${STRICT_OBS}" == true ]]; then
    fail "Observability Operator not detected"
    hint "Install from OperatorHub before deploy_lab.sh:"
    hint "  - Cluster Observability Operator / Red Hat OpenShift Observability"
    hint "  - Tempo Operator and/or OpenTelemetry Operator (as required by your OCP version)"
    hint "Temporary bypass (not for full lab): ./scripts/check_prerequisites.sh --skip-observability"
  else
    warn "Observability Operator not detected (--skip-observability)"
  fi
fi

echo
if [[ "${#HINTS[@]}" -gt 0 ]]; then
  echo "--- Next steps ---"
  for h in "${HINTS[@]}"; do
    echo "$h"
  done
  echo
fi

if [[ "${ERRORS}" -gt 0 ]]; then
  echo "${RED}${ERRORS} error(s), ${WARNINGS} warning(s). Fix errors before deploying.${NC}"
  exit 1
fi
echo "${GREEN}Prerequisites OK${NC} (${WARNINGS} warning(s)). You may continue with secrets + GitOps deploy."
exit 0
