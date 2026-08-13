"""Multi-select document picker for raw-documents bucket."""

from __future__ import annotations

from typing import Any

import pandas as pd
import streamlit as st


def render_document_picker(documents: list[dict[str, Any]]) -> list[str]:
    st.subheader("Document picker")
    st.caption("Files currently available in the MinIO `raw-documents` bucket.")

    if not documents:
        st.warning("No documents found. Run `scripts/seed_dataset.py` to populate the bucket.")
        return []

    df = pd.DataFrame(documents)
    if "key" not in df.columns:
        st.error("Unexpected document listing payload.")
        return []

    display = df.copy()
    display["size_kb"] = (display["size"].astype(float) / 1024).round(1)
    display = display[["key", "size_kb", "last_modified"]]
    display.columns = ["File", "Size (KB)", "Last modified"]

    select_all = st.toggle("Select all", value=False, key="select_all_docs")
    event = st.dataframe(
        display,
        use_container_width=True,
        hide_index=True,
        on_select="rerun",
        selection_mode="multi-row",
        key="doc_table",
    )

    if select_all:
        return [str(k) for k in df["key"].tolist()]

    rows = []
    if event and getattr(event, "selection", None):
        rows = list(event.selection.rows or [])
    return [str(df.iloc[i]["key"]) for i in rows]
