#!/usr/bin/env python3
"""Generate synthetic public-record PDFs and upload them to MinIO raw-documents.

Platform-first: no Hugging Face / external dataset downloads. Lab data is
synthetic FOIA-style PDFs written locally and stored in MinIO (allowed).
"""

from __future__ import annotations

import argparse
import logging
import subprocess
import sys
from pathlib import Path

try:
    import fitz
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "pymupdf"])
    import fitz

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

try:
    import boto3  # noqa: F401
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "boto3", "pydantic-settings", "pyyaml"])

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


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Seed MinIO raw-documents with synthetic public-record PDFs"
    )
    parser.add_argument(
        "--local-only",
        action="store_true",
        help="Write samples under data/samples/ without uploading to MinIO",
    )
    args = parser.parse_args()

    out_dir = ROOT / "data" / "samples"
    out_dir.mkdir(parents=True, exist_ok=True)

    settings = get_settings()
    s3 = None if args.local_only else S3Client(settings)
    if s3:
        s3.ensure_buckets()

    uploaded = 0
    for sample in SAMPLE_DOCS:
        pdf = render_pdf(sample["title"], sample["body"])
        path = out_dir / Path(sample["key"]).name
        path.write_bytes(pdf)
        if s3:
            uri = s3.upload_bytes(settings.s3_raw_bucket, sample["key"], pdf)
            logger.info("Uploaded synthetic sample: %s", uri)
            uploaded += 1
        else:
            logger.info("Wrote local sample: %s", path)

    if s3:
        logger.info("Seed complete. Uploaded %d objects to %s", uploaded, settings.s3_raw_bucket)
    else:
        logger.info("Local seed complete under %s", out_dir)


if __name__ == "__main__":
    main()
