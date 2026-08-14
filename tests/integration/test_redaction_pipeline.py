"""Integration-style test: end-to-end redaction without external LLM."""

from __future__ import annotations

import fitz

from src.services.pdf_redactor import PDFRedactor


def test_person_and_place_redaction_pipeline():
    doc = fitz.open()
    page = doc.new_page()
    page.insert_text((72, 100), "Report by Jordan Hale regarding Plant B.", fontsize=12)
    page.insert_text((72, 140), "Location: Oak Ridge facility vicinity.", fontsize=12)
    pdf = doc.tobytes()
    doc.close()

    redactor = PDFRedactor()
    targets = redactor.find_text_bboxes(pdf, ["Jordan Hale", "Oak Ridge", "Plant B"])
    assert len(targets) >= 2

    redacted = redactor.apply_redactions(pdf, targets)
    text = redactor.extract_layout_and_text(redacted)["pages"][0]["text"]
    assert "Jordan Hale" not in text
    assert "Oak Ridge" not in text
