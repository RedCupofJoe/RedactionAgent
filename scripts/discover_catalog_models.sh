#!/usr/bin/env bash
# Discover OpenShift AI catalog InferenceService URLs + /v1/models ids for the lab.
# Prints LLM_* / EMBEDDING_* values and optionally writes local ConfigMaps or applies live.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${MODELS_NAMESPACE:-rhoai-models}"
SLM_NAME="${SLM_NAME:-lab-slm}"
EMBED_NAME="${EMBED_NAME:-lab-embed}"
WRITE=false
APPLY=false
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.11.1}"

usage() {
  cat <<'EOF'
Usage: scripts/discover_catalog_models.sh [--write] [--apply] [--namespace NS]

Queries lab-slm / lab-embed predictors in-cluster for OpenAI-compatible /v1/models ids.
Embedding OR check: lab-embed, then redhataigranite-embedding-engl (catalog default name).

Options:
  --write       Update local manifests/*/configmap.yaml with discovered values
  --apply       Patch live ConfigMaps in redaction-agent, discovery-agent, mcp-gateway
  --namespace   Models project (default: rhoai-models)
  --slm NAME    Prefer this InferenceService name (default: lab-slm)
  --embed NAME  Prefer this embedding InferenceService name (default: lab-embed)

Env overrides: MODELS_NAMESPACE, SLM_NAME, EMBED_NAME, CURL_IMAGE

Examples:
  ./scripts/discover_catalog_models.sh
  ./scripts/discover_catalog_models.sh --write
  ./scripts/discover_catalog_models.sh --write --apply
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --write) WRITE=true; shift ;;
    --apply) APPLY=true; shift ;;
    --namespace) NS="$2"; shift 2 ;;
    --slm) SLM_NAME="$2"; shift 2 ;;
    --embed) EMBED_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need oc
need python3

if ! oc whoami >/dev/null 2>&1; then
  echo "Not logged in to a cluster (oc whoami failed)." >&2
  exit 1
fi

resolve_predictor_svc() {
  local name="$1"
  local svc=""
  for candidate in "${name}-predictor" "${name}-predictor-default" "${name}"; do
    if oc get svc -n "${NS}" "${candidate}" >/dev/null 2>&1; then
      svc="${candidate}"
      break
    fi
  done
  printf '%s' "${svc}"
}

# First Ready InferenceService from an OR list of names (stops at first hit).
first_ready_isvc() {
  local role="$1"
  shift
  local name
  for name in "$@"; do
    [[ -n "${name}" ]] || continue
    if oc get inferenceservice -n "${NS}" "${name}" >/dev/null 2>&1; then
      local ready
      ready=$(oc get inferenceservice -n "${NS}" "${name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
      if [[ "${ready}" == "True" ]]; then
        printf '%s' "${name}"
        return 0
      fi
      echo "WARN: InferenceService '${name}' exists but Ready=${ready:-unknown}" >&2
    fi
  done
  echo "ERROR: No Ready ${role} InferenceService among: $*" >&2
  echo "  oc get inferenceservice,svc -n ${NS}" >&2
  oc get inferenceservice -n "${NS}" >&2 || true
  exit 1
}

fetch_models_json() {
  local host="$1"
  local url="http://${host}.${NS}.svc.cluster.local:80/v1/models"
  local pod="catalog-models-probe-${RANDOM}"
  # Run curl in-cluster so we do not need port-forward.
  oc delete pod -n "${NS}" "${pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  oc run "${pod}" -n "${NS}" --restart=Never --image="${CURL_IMAGE}" \
    --labels="app.kubernetes.io/name=catalog-models-probe" \
    --command -- sleep 120 >/dev/null
  if ! oc wait --for=condition=Ready "pod/${pod}" -n "${NS}" --timeout=120s >/dev/null 2>&1; then
    oc logs -n "${NS}" "${pod}" >&2 || true
    oc delete pod -n "${NS}" "${pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    echo "ERROR: Probe pod failed to start (image pull / scheduling)." >&2
    exit 1
  fi
  local body=""
  if ! body=$(oc exec -n "${NS}" "${pod}" -- curl -sf --max-time 90 "${url}" 2>/dev/null); then
    oc delete pod -n "${NS}" "${pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    echo "ERROR: GET ${url} failed. Is the InferenceService Ready?" >&2
    echo "  oc get inferenceservice,pods -n ${NS}" >&2
    exit 1
  fi
  oc delete pod -n "${NS}" "${pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  printf '%s' "${body}"
}

first_model_id() {
  python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit("empty /v1/models response")
data = json.loads(raw)
models = data.get("data") or data.get("models") or []
if isinstance(data, list):
    models = data
if not models:
    sys.exit("no models in /v1/models response: " + raw[:200])
m0 = models[0]
mid = m0.get("id") or m0.get("model") or m0.get("name")
if not mid:
    sys.exit("model entry missing id: " + json.dumps(m0)[:200])
print(mid)
'
}

echo "=== Discover catalog models in ${NS} ==="
# Prefer lab names; OR common catalog default names if the preferred deploy name differs.
SLM_NAME=$(first_ready_isvc SLM \
  "${SLM_NAME}" \
  lab-slm)
EMBED_NAME=$(first_ready_isvc embedding \
  "${EMBED_NAME}" \
  lab-embed \
  redhataigranite-embedding-engl)
echo "SLM InferenceService:       ${SLM_NAME}"
echo "Embedding InferenceService: ${EMBED_NAME}"

SLM_SVC=$(resolve_predictor_svc "${SLM_NAME}")
EMBED_SVC=$(resolve_predictor_svc "${EMBED_NAME}")
if [[ -z "${SLM_SVC}" || -z "${EMBED_SVC}" ]]; then
  echo "ERROR: Predictor Service missing for SLM='${SLM_NAME}' (svc='${SLM_SVC}') or embed='${EMBED_NAME}' (svc='${EMBED_SVC}')." >&2
  oc get svc -n "${NS}" >&2 || true
  exit 1
fi
echo "SLM service:        ${SLM_SVC}"
echo "Embedding service:  ${EMBED_SVC}"

LLM_BASE_URL="http://${SLM_SVC}.${NS}.svc.cluster.local:80/v1"
EMBEDDING_BASE_URL="http://${EMBED_SVC}.${NS}.svc.cluster.local:80/v1"

echo "Fetching ${LLM_BASE_URL}/models ..."
LLM_MODEL=$(fetch_models_json "${SLM_SVC}" | first_model_id)
echo "Fetching ${EMBEDDING_BASE_URL}/models ..."
EMBEDDING_MODEL=$(fetch_models_json "${EMBED_SVC}" | first_model_id)

echo
echo "--- Discovered values ---"
cat <<EOF
LLM_BASE_URL=${LLM_BASE_URL}
LLM_MODEL=${LLM_MODEL}
EMBEDDING_BASE_URL=${EMBEDDING_BASE_URL}
EMBEDDING_MODEL=${EMBEDDING_MODEL}
EOF
echo

update_file() {
  local file="$1"
  python3 - "${file}" "${LLM_BASE_URL}" "${LLM_MODEL}" "${EMBEDDING_BASE_URL}" "${EMBEDDING_MODEL}" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
llm_url, llm_model, emb_url, emb_model = sys.argv[2:6]
text = path.read_text()
repl = {
    "LLM_BASE_URL": llm_url,
    "LLM_MODEL": llm_model,
    "EMBEDDING_BASE_URL": emb_url,
    "EMBEDDING_MODEL": emb_model,
}
for key, val in repl.items():
    pattern = rf'(?m)^(\s*{re.escape(key)}:\s*")[^"]*(")'
    text2, n = re.subn(pattern, rf'\g<1>{val}\2', text, count=1)
    if n == 0:
        sys.exit(f"{path}: key {key} not found")
    text = text2
path.write_text(text)
print(f"Updated {path}")
PY
}

if [[ "${WRITE}" == true ]]; then
  update_file "${ROOT}/manifests/agent/configmap.yaml"
  update_file "${ROOT}/manifests/discovery/configmap.yaml"
  update_file "${ROOT}/manifests/mcp-gateway/configmap.yaml"
  echo "Local ConfigMaps updated. Commit + push (or Argo sync) when ready."
fi

if [[ "${APPLY}" == true ]]; then
  patch_cm() {
    local ns="$1" name="$2"
    oc -n "${ns}" patch configmap "${name}" --type merge -p "$(python3 - <<PY
import json
print(json.dumps({
  "data": {
    "LLM_BASE_URL": "${LLM_BASE_URL}",
    "LLM_MODEL": "${LLM_MODEL}",
    "EMBEDDING_BASE_URL": "${EMBEDDING_BASE_URL}",
    "EMBEDDING_MODEL": "${EMBEDDING_MODEL}",
  }
}))
PY
)"
    echo "Patched ${ns}/${name}"
  }
  patch_cm redaction-agent redaction-agent-config
  patch_cm discovery-agent discovery-agent-config
  patch_cm mcp-gateway mcp-gateway-config
  echo "Restarting deployments so pods reload ConfigMaps..."
  oc -n redaction-agent rollout restart deploy/redaction-agent deploy/redaction-ui 2>/dev/null || true
  oc -n discovery-agent rollout restart deploy/discovery-agent 2>/dev/null || true
  oc -n mcp-gateway rollout restart deploy/mcp-gateway 2>/dev/null || true
fi

if [[ "${WRITE}" != true && "${APPLY}" != true ]]; then
  echo "Tip: ./scripts/discover_catalog_models.sh --write          # update Git manifests"
  echo "     ./scripts/discover_catalog_models.sh --write --apply  # manifests + live cluster"
fi
