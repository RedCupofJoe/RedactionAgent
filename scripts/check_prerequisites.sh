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
  - Node Feature Discovery (NFD) Operator + instance (required for NVIDIA GPU Operator)
  - NVIDIA GPU Operator / allocatable GPUs (prefer L40S / g6e.4xlarge)
  - OpenShift Observability Operator (required for demo traces)
  - StorageClass: required with --non-cloud; warn-only on cloud if missing

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

# Application CRD (direct CRD lookup — avoid api-resources|grep -q pipefail false negatives)
if oc get crd applications.argoproj.io >/dev/null 2>&1; then
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
# NFD (required — NVIDIA GPU Operator ClusterPolicy waits on NFD labels)
# ---------------------------------------------------------------------------
NFD_OK=false
NFD_LABELS=false

# OpenShift NFD CR (nfd.openshift.io)
if oc get nodefeaturediscovery -A --no-headers 2>/dev/null | grep -q .; then
  NFD_OK=true
fi
if oc get csv -A 2>/dev/null | grep -qiE 'nfd|node-feature-discovery'; then
  NFD_OK=true
fi
if oc get ns openshift-nfd >/dev/null 2>&1; then
  if oc get pods -n openshift-nfd --no-headers 2>/dev/null | grep -qiE 'Running'; then
    NFD_OK=true
  fi
fi
if oc get pods -A 2>/dev/null | grep -qiE 'nfd-controller|nfd-master|nfd-worker|node-feature-discovery'; then
  NFD_OK=true
fi
if oc api-resources 2>/dev/null | grep -qiE 'nodefeaturediscoveries|nodefeatures'; then
  NFD_OK=true
fi

# NVIDIA-related NFD labels (formats vary by NFD version / workerConfig)
NODE_JSON=$(oc get nodes -o json 2>/dev/null || echo '{}')
if echo "${NODE_JSON}" | grep -qE 'feature\.node\.kubernetes\.io/pci-10de\.present|feature\.node\.kubernetes\.io/pci-0300_10de|pci-10de|vendor.?10de'; then
  NFD_LABELS=true
elif echo "${NODE_JSON}" | grep -qiE 'feature\.node\.kubernetes\.io/.*10de'; then
  NFD_LABELS=true
elif echo "${NODE_JSON}" | grep -q 'feature.node.kubernetes.io/pci-'; then
  # Generic PCI labels present (may still satisfy newer GPU Operator)
  NFD_LABELS=true
fi

if [[ "${NFD_LABELS}" == true ]]; then
  ok "NFD PCI / NVIDIA feature labels present on nodes"
elif [[ "${NFD_OK}" == true ]]; then
  ok "Node Feature Discovery installed (NodeFeatureDiscovery / openshift-nfd)"
  warn "NVIDIA-specific NFD labels not matched yet — GPU Operator may still be waiting"
  hint "Verify NFD is labeling GPU workers:"
  hint "  oc get pods -n openshift-nfd"
  hint "  oc get nodefeaturediscovery -A"
  hint "  oc get nodes -o json | grep -E 'pci-10de|0300_10de|feature.node.kubernetes.io/pci' | head"
  hint "If labels appear but ClusterPolicy still says NFDLabelsMissing, restart GPU operator:"
  hint "  oc delete pod -n nvidia-gpu-operator -l app=gpu-operator"
else
  fail "Node Feature Discovery (NFD) not detected"
  hint "NFD is required for this lab. NVIDIA GPU Operator ClusterPolicy stays blocked with 'No NFD labels found' without it."
  hint "Install from OperatorHub:"
  hint "  1) Operators → OperatorHub → Node Feature Discovery → Install"
  hint "  2) Installed Operators → NFD → NodeFeatureDiscovery → Create (defaults OK)"
  hint "  3) Wait for nfd-worker pods on GPU nodes, then re-check ClusterPolicy / allocatable GPUs"
fi

# ---------------------------------------------------------------------------
# GPU
# ---------------------------------------------------------------------------
ALLOC=$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null || true)
if echo "${ALLOC}" | grep -qE '^[1-9]'; then
  ok "Nodes with allocatable nvidia.com/gpu found"
  if oc get nodes -o json 2>/dev/null | grep -qiE 'NVIDIA-L40S|L40S|g6e\.4xlarge|g6e'; then
    ok "GPU worker labels / instance types look present (L40S / g6e.4xlarge preferred)"
  else
    warn "No explicit L40S / g6e.4xlarge label found. Lab assumes 1× NVIDIA L40S per g6e.4xlarge worker. Verify hardware profiles."
  fi
else
  fail "No allocatable GPUs on nodes (nvidia.com/gpu)"
  hint "NFD can be Available while GPUs are still missing — finish this sequence:"
  hint "  1) Confirm NFD labels on GPU workers:"
  hint "       oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true"
  hint "       oc get nodes -o json | grep -E 'pci-10de|0300_10de|feature.node.kubernetes.io/pci' | head"
  hint "  2) Confirm ClusterPolicy left NFDLabelsMissing:"
  hint "       oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.conditions}' ; echo"
  hint "  3) If labels exist but ClusterPolicy is stuck, bounce the GPU Operator:"
  hint "       oc delete pod -n nvidia-gpu-operator -l app=gpu-operator"
  hint "  4) Wait for driver + device-plugin DaemonSets, then:"
  hint "       oc get pods -n nvidia-gpu-operator"
  hint "       oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu"
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
# Prefer CRDs + install namespaces. Avoid `oc get csv -A | grep -q` under pipefail:
# cluster-wide CSV listings are huge; grep -q exits early → oc gets SIGPIPE → false FAIL.
OBS_OK=false
if oc get crd opentelemetrycollectors.opentelemetry.io >/dev/null 2>&1; then
  OBS_OK=true
fi
if oc get crd tempostacks.tempo.grafana.com >/dev/null 2>&1; then
  OBS_OK=true
fi
if oc get crd uiplugins.observability.openshift.io >/dev/null 2>&1; then
  OBS_OK=true
fi
for ns in openshift-cluster-observability-operator openshift-opentelemetry-operator \
          openshift-tempo-operator node-observability-operator openshift-operators; do
  names=$(oc get csv -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  if echo "${names}" | grep -qiE 'cluster-observability|opentelemetry|tempo-operator|node-observability'; then
    OBS_OK=true
    break
  fi
done
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
