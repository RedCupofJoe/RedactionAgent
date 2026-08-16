#!/usr/bin/env bash
# Smoke test: health + list documents + optional discovery health.
set -euo pipefail

REDACT_URL="${REDACT_API_URL:-}"
DISCOVERY_URL="${DISCOVERY_API_URL:-}"

if [[ -z "${REDACT_URL}" ]]; then
  HOST=$(oc -n redaction-agent get route redaction-agent-api -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [[ -n "${HOST}" ]] || { echo "Set REDACT_API_URL or deploy redaction-agent route"; exit 1; }
  REDACT_URL="https://${HOST}"
fi

if [[ -z "${DISCOVERY_URL}" ]]; then
  HOST=$(oc -n discovery-agent get route discovery-agent-api -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [[ -n "${HOST}" ]] && DISCOVERY_URL="https://${HOST}" || true
fi

echo "Redaction API: ${REDACT_URL}"
curl -skf "${REDACT_URL}/healthz" | tee /dev/stderr
echo
curl -skf "${REDACT_URL}/documents" | head -c 500
echo

if [[ -n "${DISCOVERY_URL}" ]]; then
  echo "Discovery API: ${DISCOVERY_URL}"
  curl -skf "${DISCOVERY_URL}/healthz" | tee /dev/stderr
  echo
  curl -skf "${DISCOVERY_URL}/search?q=plant" | head -c 500 || true
  echo
fi

echo "Smoke test completed."
