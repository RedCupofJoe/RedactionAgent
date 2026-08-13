#!/usr/bin/env python3
"""Download sample public-record PDFs and upload them to MinIO raw-documents.

Preferred source: Hugging Face datasets / public FOIA-style samples.
Falls back to generating synthetic government-style PDFs with PyMuPDF when
network datasets are unavailable.
"""

from __future__ import annotations

import argparse
import io
import logging
import sys
from pathlib import Path

import fitz

# Allow running from repo root without install
ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from src.services.s3_client import S3Client  # noqa: E402
from src.services.settings import get_settings  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
logger = logging.getLogger("seed_dataset")

SAMPLE_DOCS = [
    {
        "key": "foia/plant-b-incident-memo.pdf",
        "title": "INTERNAL MEMORANDUM — Plant B Incident Review",
        "body": (
            "U.S. Department of Energy — FOIA Release (Synthetic)\n\n"
            "Date: 15 July 2021\n"
            "From: Jordan Hale, Site Safety Officer\n"
            "To: Regional Compliance Desk\n\n"
            "Subject: Chemical spill at Plant B in July 2021\n\n"
            "On 12 July 2021 at approximately 14:20 local time, a containment valve "
            "failure at Plant B (Oak Ridge vicinity) released an estimated 40 liters "
            "of industrial solvent into the secondary containment trench. "
            "Responder Alexandra Nguyen coordinated evacuation of Building 12. "
            "The City of Oakridge fire liaison was notified at 14:41.\n\n"
            "No off-site exposure was confirmed. Remediation contractor Meridian "
            "Environmental began soil sampling on 13 July 2021. Contact for follow-up: "
            "jhale@example.agency.gov / +1-555-014-2099.\n"
        ),
    },
    {
        "key": "foia/personnel-roster-excerpt.pdf",
        "title": "PUBLIC RECORDS — Contractor Roster Excerpt",
        "body": (
            "Agency Public Records Unit — Synthetic FOIA Packet\n\n"
            "Reporting period: CY2021\n\n"
            "1. Michael Torres — Facility Access Badge #A-4412 — assigned Plant B\n"
            "2. Priya Desai — Records Analyst — HQ Annex, Washington, DC\n"
            "3. Samuel Okonkwo — Night Shift Supervisor — Building 7, Denver, CO\n\n"
            "Travel authorizations referencing 3–5 March 2021 include overnight stays "
            "near the Denver Federal Center. Redact personal phone numbers before release.\n"
        ),
    },
    {
        "key": "court/synthetic-hearing-minutes.pdf",
        "title": "Hearing Minutes (Synthetic Public Docket)",
        "body": (
            "IN THE MATTER OF PUBLIC SAFETY REVIEW — Docket PS-2021-088\n\n"
            "Hearing date: 28 August 2021\n"
            "Location: Federal Building, Room 4B, Atlanta, GA\n\n"
            "Witnesses discussed the chemical spill at Plant B in July 2021 and "
            "subsequent contractor invoices submitted by Meridian Environmental. "
            "Judge Elena Vasquez directed parties to produce non-privileged maps of "
            "Plant B secondary containment by 10 September 2021.\n"
        ),
    },
]


def render_pdf(title: str, body: str) -> bytes:
    doc = fitz.open()
    page = doc.new_page(width=612, height=792)
    margin = 54
    page.insert_textbox(
        fitz.Rect(margin, margin, 612 - margin, margin + 60),
        title,
        fontsize=14,
        fontname="helv",
        align=0,
    )
    page.insert_textbox(
        fitz.Rect(margin, margin + 70, 612 - margin, 792 - margin),
        body,
        fontsize=11,
        fontname="helv",
        align=0,
    )
    data = doc.tobytes(deflate=True)
    doc.close()
    return data


def try_download_hf_samples(limit: int = 3) -> list[tuple[str, bytes]]:
    """Best-effort download of public PDF-like samples from Hugging Face Hub."""
    samples: list[tuple[str, bytes]] = []
    try:
        from huggingface_hub import list_repo_files, hf_hub_download

        # Use a small public repo with document-like assets when available.
        # If unavailable, caller falls back to synthetic PDFs.
        repo_id = "hf-internal-testing/fixtures_pdf"
        files = [f for f in list_repo_files(repo_id) if f.lower().endswith(".pdf")]
        for rel in files[:limit]:
            path = hf_hub_download(repo_id=repo_id, filename=rel)
            data = Path(path).read_bytes()
            key = f"hf/{Path(rel).name}"
            samples.append((key, data))
            logger.info("Downloaded HF sample: %s", key)
    except Exception as exc:  # noqa: BLE001
        logger.warning("Hugging Face download skipped: %s", exc)
    return samples


def main() -> None:
    parser = argparse.ArgumentParser(description="Seed MinIO raw-documents with sample PDFs")
    parser.add_argument("--synthetic-only", action="store_true", help="Skip Hugging Face downloads")
    parser.add_argument("--limit", type=int, default=5, help="Max remote samples to fetch")
    args = parser.parse_args()

    settings = get_settings()
    s3 = S3Client(settings)
    s3.ensure_buckets()

    uploaded = 0
    if not args.synthetic_only:
        for key, data in try_download_hf_samples(limit=args.limit):
            s3.upload_bytes(settings.s3_raw_bucket, key, data)
            uploaded += 1

    for sample in SAMPLE_DOCS:
        pdf = render_pdf(sample["title"], sample["body"])
        uri = s3.upload_bytes(settings.s3_raw_bucket, sample["key"], pdf)
        logger.info("Uploaded synthetic sample: %s", uri)
        uploaded += 1

    # Also write a local copy for offline demos
    out_dir = ROOT / "data" / "samples"
    out_dir.mkdir(parents=True, exist_ok=True)
    for sample in SAMPLE_DOCS:
        path = out_dir / Path(sample["key"]).name
        path.write_bytes(render_pdf(sample["title"], sample["body"]))

    logger.info("Seed complete. Uploaded %d objects to %s", uploaded, settings.s3_raw_bucket)


if __name__ == "__main__":
    main()
