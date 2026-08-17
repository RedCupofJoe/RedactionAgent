#!/usr/bin/env bash
# Download sample PDFs into scratch/datasets/ (gitignored).
# Default: DocLayNet-v1.2 (page PDFs via Hugging Face datasets streaming).
# Fallbacks: other HF dataset repos with .pdf files → public URLs → synthetic FOIA PDFs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/scratch/datasets"
# DocLayNet (base) has no PDF blobs on the Hub; v1.2 embeds single-page PDFs in a `pdf` column.
REPO_ID="${HF_DATASET_REPO:-docling-project/DocLayNet-v1.2}"
LIMIT="${HF_DATASET_LIMIT:-500}"
SPLIT="${HF_DATASET_SPLIT:-test}"

mkdir -p "${OUT}"

echo "Output: ${OUT}"
echo "Dataset: ${REPO_ID} (limit=${LIMIT} page PDFs, split=${SPLIT})"

python3 - <<PY
import os
import sys
import urllib.request
from pathlib import Path

out = Path("${OUT}")
out.mkdir(parents=True, exist_ok=True)
repo_id = "${REPO_ID}".strip()
# Map base DocLayNet → v1.2 (has embedded PDF bytes for a small demo)
if repo_id in {"docling-project/DocLayNet", "ds4sd/DocLayNet"}:
    print(f"Note: {repo_id} does not host PDF files on the Hub (PNG/COCO only).")
    print("Using docling-project/DocLayNet-v1.2 which embeds page PDFs in a 'pdf' column.")
    repo_id = "docling-project/DocLayNet-v1.2"
limit = int("${LIMIT}")
split = "${SPLIT}".strip() or "test"
saved = 0

def save_bytes(name: str, data: bytes) -> None:
    global saved
    dest = out / name
    dest.write_bytes(data)
    print(f"Saved {dest} ({len(data)} bytes)")
    saved += 1

def fetch_doclaynet_v12() -> int:
    try:
        import datasets
    except ImportError:
        import subprocess
        subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "datasets"])
        import datasets

    print(f"Streaming {repo_id} split={split} (first {limit} pages with PDF bytes)...")
    ds = datasets.load_dataset(repo_id, split=split, streaming=True)
    count = 0
    for row in ds:
        pdf = row.get("pdf")
        if not isinstance(pdf, (bytes, bytearray)) or len(pdf) < 100:
            continue
        meta = row.get("metadata") or {}
        if not isinstance(meta, dict):
            meta = {}
        doc_name = Path(str(meta.get("original_filename") or "doc")).stem
        page_no = meta.get("page_no", count)
        page_hash = str(meta.get("page_hash") or count)[:12]
        category = str(meta.get("doc_category") or "doc")
        name = f"doclaynet_{category}_{doc_name}_p{page_no}_{page_hash}.pdf"
        # sanitize filename
        name = "".join(c if c.isalnum() or c in "._-" else "_" for c in name)
        save_bytes(name, bytes(pdf))
        count += 1
        if count % 25 == 0 or count >= limit:
            print(f"  … {count}/{limit}")
        if count >= limit:
            break
    return count

def fetch_hf_pdf_files() -> int:
    try:
        from huggingface_hub import list_repo_files, hf_hub_download
    except ImportError:
        import subprocess
        subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "huggingface-hub"])
        from huggingface_hub import list_repo_files, hf_hub_download

    files = [
        f
        for f in list_repo_files(repo_id, repo_type="dataset")
        if f.lower().endswith(".pdf")
    ]
    if not files:
        return 0
    for rel in files[:limit]:
        path = hf_hub_download(repo_id=repo_id, filename=rel, repo_type="dataset")
        save_bytes(Path(rel).name, Path(path).read_bytes())
    return len(files[:limit])

# 1) DocLayNet-v1.2 (or alias) via datasets streaming
if "doclaynet" in repo_id.lower() and "v1.2" in repo_id.lower():
    try:
        fetch_doclaynet_v12()
    except Exception as exc:
        print(f"DocLayNet-v1.2 stream failed ({type(exc).__name__}): {exc}")

# 2) Generic HF dataset with raw .pdf files in the repo tree
if saved == 0 and repo_id:
    print(f"Trying Hugging Face dataset file listing: {repo_id}")
    try:
        fetch_hf_pdf_files()
    except Exception as exc:
        print(f"HF file listing failed ({type(exc).__name__}): {exc}")

# 3) Public sample PDFs
if saved == 0:
    samples = [
        ("w3c-dummy.pdf", "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf"),
        ("mozilla-helloworld.pdf", "https://raw.githubusercontent.com/mozilla/pdf.js-sample-files/master/helloworld.pdf"),
    ]
    print("Downloading public sample PDFs...")
    for name, url in samples[:limit]:
        try:
            with urllib.request.urlopen(url, timeout=60) as resp:
                save_bytes(name, resp.read())
        except Exception as exc:
            print(f"Skip {name}: {exc}")

# 4) Synthetic FOIA-style PDFs
if saved == 0:
    print("Generating synthetic FOIA-style PDFs with PyMuPDF...")
    try:
        import fitz
    except ImportError:
        import subprocess
        subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "pymupdf"])
        import fitz

    docs = [
        (
            "plant-b-incident-memo.pdf",
            "INTERNAL MEMORANDUM — Plant B Incident Review",
            "Subject: Chemical spill at Plant B in July 2021",
        ),
        (
            "personnel-roster-excerpt.pdf",
            "PUBLIC RECORDS — Contractor Roster Excerpt",
            "1. Michael Torres — Facility Access Badge #A-4412",
        ),
        (
            "synthetic-hearing-minutes.pdf",
            "Hearing Minutes (Synthetic Public Docket)",
            "Witnesses discussed the chemical spill at Plant B in July 2021.",
        ),
    ]
    for name, title, body in docs[:limit]:
        doc = fitz.open()
        page = doc.new_page(width=612, height=792)
        page.insert_textbox(__import__("fitz").Rect(54, 54, 558, 120), title, fontsize=14, fontname="helv")
        page.insert_textbox(__import__("fitz").Rect(54, 140, 558, 740), body, fontsize=11, fontname="helv")
        save_bytes(name, doc.tobytes())
        doc.close()

print(f"Done. {saved} file(s) in {out}")
if saved == 0:
    sys.exit("No PDFs could be fetched or generated.")
PY

echo
echo "Next: scripts/seed_minio.sh   # uploads scratch + synthetic samples to MinIO"
