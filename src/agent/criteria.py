"""Redaction criteria models shared by API, UI, and agent."""

from __future__ import annotations

import re
from dataclasses import dataclass, field


@dataclass
class RedactionCriteria:
    persons: list[str] = field(default_factory=list)
    places: list[str] = field(default_factory=list)
    times: list[str] = field(default_factory=list)
    events: str = ""
    custom: str = ""  # free text / regex lines

    @classmethod
    def from_form(
        cls,
        person: str = "",
        place: str = "",
        time: str = "",
        events: str = "",
        custom: str = "",
    ) -> RedactionCriteria:
        def split_csv(value: str) -> list[str]:
            parts = re.split(r"[,;\n]+", value or "")
            return [p.strip() for p in parts if p.strip()]

        return cls(
            persons=split_csv(person),
            places=split_csv(place),
            times=split_csv(time),
            events=(events or "").strip(),
            custom=(custom or "").strip(),
        )
