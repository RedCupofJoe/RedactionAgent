"""Redaction criteria input form."""

from __future__ import annotations

import streamlit as st


def render_redaction_form() -> dict[str, str]:
    st.subheader("Redaction criteria")
    st.caption("Provide entities and/or a situational event description to redact.")

    c1, c2 = st.columns(2)
    with c1:
        person = st.text_input(
            "Person",
            placeholder="Names, aliases — comma separated",
            help="Literal person names and aliases to locate and redact.",
        )
        place = st.text_input(
            "Place",
            placeholder="Addresses, cities, facilities",
            help="Physical places and facility names.",
        )
    with c2:
        time = st.text_input(
            "Time",
            placeholder="Dates, ranges, years",
            help="Dates, time ranges, or specific years.",
        )

    events = st.text_area(
        "Events",
        placeholder='e.g. "The chemical spill at Plant B in July 2021"',
        height=100,
        help="Complex situational descriptions used for semantic search + SLM confirmation.",
    )
    custom = st.text_area(
        "Custom",
        placeholder="Arbitrary terms, one per line. Prefix with re: for regex.",
        height=90,
        help="Custom entity strings or regex rules (lines starting with re:).",
    )

    return {
        "person": person or "",
        "place": place or "",
        "time": time or "",
        "events": events or "",
        "custom": custom or "",
    }
