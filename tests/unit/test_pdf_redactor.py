"""Unit tests for PDF redaction with PyMuPDF."""

from __future__ import annotations

import fitz

from src.services.pdf_redactor import PDFRedactor, RedactionTarget


def _sample_pdf(text: str = "Alice met Bob in Denver on July 2021.") -> bytes:
    doc = fitz.open()
    page = doc.new_page()
    page.insert_text((72, 72), text, fontsize=12)
    data = doc.tobytes()
    doc.close()
    return data


def test_extract_layout_and_text():
    redactor = PDFRedactor()
    layout = redactor.extract_layout_and_text(_sample_pdf(), doc_id="demo")
    assert layout["page_count"] == 1
    assert "Alice" in layout["pages"][0]["text"]
    assert layout["spans"]


def test_find_literal_bboxes():
    redactor = PDFRedactor()
    pdf = _sample_pdf()
    targets = redactor.find_text_bboxes(pdf, ["Alice", "Denver"])
    assert len(targets) >= 2
    assert all(isinstance(t, RedactionTarget) for t in targets)


def test_apply_redactions_burns_text():
    redactor = PDFRedactor()
    pdf = _sample_pdf("SECRET-TOKEN-XYZ should vanish")
    targets = redactor.find_text_bboxes(pdf, ["SECRET-TOKEN-XYZ"])
    assert targets
    redacted = redactor.apply_redactions(pdf, targets, burn_in=True)
    layout = redactor.extract_layout_and_text(redacted, doc_id="out")
    assert "SECRET-TOKEN-XYZ" not in layout["pages"][0]["text"]


def test_chunk_pages():
    redactor = PDFRedactor()
    # Force multi-chunk layout by injecting long page text directly
    layout = {
        "doc_id": "c",
        "pages": [{"page": 0, "text": ("alpha beta gamma " * 40), "spans": []}],
    }
    chunks = redactor.chunk_pages(layout, chunk_size=100, chunk_overlap=20)
    assert len(chunks) > 1
    assert chunks[0].doc_id == "c"
