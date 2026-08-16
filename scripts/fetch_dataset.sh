#!/usr/bin/env bash
# Download a public Hugging Face document dataset into scratch/datasets/ (gitignored).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/scratch/datasets"
REPO_ID="${HF_DATASET_REPO:-hf-internal-testing/fixtures_pdf}"
LIMIT="${HF_DATASET_LIMIT:-10}"

mkdir -p "${OUT}"

echo "Fetching up to ${LIMIT} PDFs from Hugging Face repo: ${REPO_ID}"
echo "Output: ${OUT}"

python3 - <<PY
import os
import sys
from pathlib import Path

out = Path("${OUT}")
out.mkdir(parents=True, exist_ok=True)
repo_id = "${REPO_ID}"
limit = int("${LIMIT}")

try:
    from huggingface_hub import list_repo_files, hf_hub_download
except ImportError:
    print("Installing huggingface-hub into the active environment...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "huggingface-hub"])
    from huggingface_hub import list_repo_files, hf_hub_download

files = [f for f in list_repo_files(repo_id) if f.lower().endswith(".pdf")]
if not files:
    print(f"No PDFs found in {repo_id}; writing a note and exiting 0 so synthetic seed still works.")
    (out / "README.txt").write_text(f"No PDFs in {repo_id}. Use scripts/seed_dataset.py for synthetic samples.\\n")
    sys.exit(0)

saved = 0
for rel in files[:limit]:
    path = hf_hub_download(repo_id=repo_id, filename=rel)
    dest = out / Path(rel).name
    dest.write_bytes(Path(path).read_bytes())
    print(f"Saved {dest}")
    saved += 1
print(f"Done. {saved} file(s) in {out}")
PY

echo
echo "Next: scripts/seed_minio.sh   # uploads scratch + synthetic samples to MinIO"
