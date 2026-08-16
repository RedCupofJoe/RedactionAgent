#!/usr/bin/env bash
# Rewrite Argo CD Application repoURL values to your Git remote.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_URL="${1:-}"
REVISION="${2:-main}"

if [[ -z "${REPO_URL}" ]]; then
  echo "Usage: scripts/configure_gitops_repo.sh <git-repo-url> [revision]"
  echo "Example: scripts/configure_gitops_repo.sh https://github.com/myorg/RedactionAgent.git main"
  exit 1
fi

PLACEHOLDER="https://github.com/EXAMPLE/RedactionAgent.git"
count=0
while IFS= read -r -d '' file; do
  if grep -q "${PLACEHOLDER}" "${file}" || grep -q "repoURL:" "${file}"; then
    sed -i.bak "s|repoURL:.*|repoURL: ${REPO_URL}|g" "${file}"
    sed -i.bak "s|targetRevision:.*|targetRevision: ${REVISION}|g" "${file}"
    rm -f "${file}.bak"
    count=$((count + 1))
    echo "Updated ${file}"
  fi
done < <(find "${ROOT}/.argocd" -name '*.yaml' -print0)

echo
echo "Updated ${count} Argo manifests."
echo "Next: git add/commit/push, then run scripts/deploy_lab.sh"
