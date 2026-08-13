"""Unit tests for redaction criteria parsing and agent helpers."""

from __future__ import annotations

from src.agent.criteria import RedactionCriteria


def test_criteria_from_form_splits_csv():
    criteria = RedactionCriteria.from_form(
        person="Alice, Bob; Carol",
        place="Denver\nOak Ridge",
        time="2021",
        events="chemical spill at Plant B",
        custom="re:\\d{3}-\\d{4}\nbadge",
    )
    assert criteria.persons == ["Alice", "Bob", "Carol"]
    assert criteria.places == ["Denver", "Oak Ridge"]
    assert criteria.times == ["2021"]
    assert "Plant B" in criteria.events
    assert "re:" in criteria.custom
