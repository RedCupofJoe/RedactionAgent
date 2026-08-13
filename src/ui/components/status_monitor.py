"""Job status monitor with progress and logs."""

from __future__ import annotations

from typing import Any

import streamlit as st


def render_status_monitor(job: dict[str, Any]) -> None:
    st.subheader("Status monitor")
    status = str(job.get("status", "unknown"))
    progress = float(job.get("progress") or 0.0)
    message = str(job.get("message") or "")

    st.progress(min(max(progress, 0.0), 1.0), text=f"{status} — {message}")

    logs = job.get("logs") or []
    with st.expander("Execution logs", expanded=True):
        if logs:
            st.code("\n".join(str(line) for line in logs), language="text")
        else:
            st.caption("No logs yet.")

    results = job.get("results") or []
    if results:
        st.markdown("#### Per-document results")
        for r in results:
            icon = "✅" if r.get("status") == "succeeded" else "❌"
            st.write(
                f"{icon} `{r.get('source_key')}` → `{r.get('output_key')}` "
                f"({r.get('target_count', 0)} redactions)"
            )
            if r.get("error"):
                st.error(r["error"])
