#!/usr/bin/env bash
# Run Locust load test against the redaction (and discovery) APIs from your laptop.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USERS="${USERS:-5}"
SPAWN="${SPAWN_RATE:-1}"
TIME="${RUN_TIME:-2m}"

REDACT_URL="${REDACT_API_URL:-}"
if [[ -z "${REDACT_URL}" ]]; then
  HOST=$(oc -n redaction-agent get route redaction-agent-api -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [[ -n "${HOST}" ]] || { echo "Set REDACT_API_URL"; exit 1; }
  REDACT_URL="https://${HOST}"
fi

export DISCOVERY_API_URL="${DISCOVERY_API_URL:-}"
if [[ -z "${DISCOVERY_API_URL}" ]]; then
  HOST=$(oc -n discovery-agent get route discovery-agent-api -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [[ -n "${HOST}" ]] && export DISCOVERY_API_URL="https://${HOST}" || true
fi

cd "${ROOT}"
python3 -m pip install -q locust >/dev/null
echo "Load test → ${REDACT_URL} users=${USERS} time=${TIME}"
echo "On 3× L4 expect GPU/API saturation under higher concurrency."
locust -f tests/load/locustfile.py --host "${REDACT_URL}" --users "${USERS}" --spawn-rate "${SPAWN}" --run-time "${TIME}" --headless
