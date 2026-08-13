"""Streamlit dashboard for the Auto Redaction Agent."""

from __future__ import annotations

import os
from typing import Any

import httpx
import streamlit as st

from src.ui.components.document_picker import render_document_picker
from src.ui.components.preview import render_side_by_side_preview
from src.ui.components.redaction_form import render_redaction_form
from src.ui.components.status_monitor import render_status_monitor

API_URL = os.getenv("AGENT_API_URL", "http://localhost:8000")
RAW_BUCKET = os.getenv("S3_RAW_BUCKET", "raw-documents")
REDACTED_BUCKET = os.getenv("S3_REDACTED_BUCKET", "redacted-documents")


st.set_page_config(
    page_title="Auto Redaction Agent",
    page_icon="⬛",
    layout="wide",
    initial_sidebar_state="expanded",
)


def _inject_styles() -> None:
    st.markdown(
        """
        <style>
        @import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500&display=swap');

        :root {
          --ra-ink: #1b1f24;
          --ra-muted: #5c6670;
          --ra-surface: #f2f4f6;
          --ra-accent: #c40000;
          --ra-accent-dark: #8f0000;
          --ra-line: #d5d9de;
        }

        html, body, [class*="css"] {
          font-family: 'IBM Plex Sans', sans-serif;
        }

        .stApp {
          background:
            radial-gradient(1200px 600px at 10% -10%, rgba(196,0,0,0.08), transparent 55%),
            radial-gradient(900px 500px at 100% 0%, rgba(27,31,36,0.06), transparent 50%),
            linear-gradient(180deg, #f7f8fa 0%, #eef1f4 100%);
        }

        .ra-hero {
          padding: 1.25rem 1.5rem 0.5rem 0;
          margin-bottom: 0.75rem;
        }
        .ra-brand {
          font-size: 2.1rem;
          font-weight: 700;
          letter-spacing: -0.02em;
          color: var(--ra-ink);
          margin: 0;
        }
        .ra-brand span { color: var(--ra-accent); }
        .ra-sub {
          color: var(--ra-muted);
          font-size: 1.02rem;
          margin-top: 0.35rem;
          max-width: 52rem;
        }
        .ra-badge {
          display: inline-block;
          margin-top: 0.75rem;
          font-family: 'IBM Plex Mono', monospace;
          font-size: 0.78rem;
          color: var(--ra-accent-dark);
          border-left: 3px solid var(--ra-accent);
          padding-left: 0.55rem;
        }
        div[data-testid="stSidebar"] {
          background: #1b1f24;
        }
        div[data-testid="stSidebar"] * {
          color: #f2f4f6 !important;
        }
        </style>
        """,
        unsafe_allow_html=True,
    )


def fetch_documents() -> list[dict[str, Any]]:
    try:
        with httpx.Client(timeout=30.0) as client:
            resp = client.get(f"{API_URL}/documents", params={"bucket": RAW_BUCKET})
            resp.raise_for_status()
            return resp.json()
    except Exception as exc:  # noqa: BLE001
        st.error(f"Unable to list documents from API ({API_URL}): {exc}")
        return []


def run_redaction(documents: list[str], form: dict[str, str]) -> dict[str, Any] | None:
    payload = {
        "documents": documents,
        "person": form.get("person", ""),
        "place": form.get("place", ""),
        "time": form.get("time", ""),
        "events": form.get("events", ""),
        "custom": form.get("custom", ""),
    }
    try:
        with httpx.Client(timeout=600.0) as client:
            resp = client.post(f"{API_URL}/redact", json=payload)
            resp.raise_for_status()
            return resp.json()
    except Exception as exc:  # noqa: BLE001
        st.error(f"Redaction job failed: {exc}")
        return None


def main() -> None:
    _inject_styles()

    with st.sidebar:
        st.markdown("### OpenShift AI")
        st.caption("RHOAI 3.5 · vLLM · A100")
        st.text_input("Agent API", value=API_URL, disabled=True)
        st.text_input("Raw bucket", value=RAW_BUCKET, disabled=True)
        st.text_input("Redacted bucket", value=REDACTED_BUCKET, disabled=True)
        if st.button("Refresh documents", use_container_width=True):
            st.session_state.pop("documents", None)

    st.markdown(
        """
        <div class="ra-hero">
          <h1 class="ra-brand">Auto <span>Redaction</span> Agent</h1>
          <p class="ra-sub">
            Select public records, define sensitive persons, places, times, and events,
            then produce permanently redacted PDFs on Red Hat OpenShift AI.
          </p>
          <div class="ra-badge">GitOps · MinIO · Qdrant · Granite / Llama SLM · MCP Gateway</div>
        </div>
        """,
        unsafe_allow_html=True,
    )

    if "documents" not in st.session_state:
        st.session_state.documents = fetch_documents()

    selected = render_document_picker(st.session_state.documents)
    form = render_redaction_form()

    col_run, col_hint = st.columns([1, 3])
    with col_run:
        run_clicked = st.button(
            "Run redaction",
            type="primary",
            use_container_width=True,
            disabled=not selected,
        )
    with col_hint:
        if not selected:
            st.info("Select one or more documents to enable redaction.")
        else:
            st.caption(f"{len(selected)} document(s) selected.")

    if run_clicked:
        if not any(form.values()):
            st.warning("Enter at least one redaction criterion.")
        else:
            with st.spinner("Running redaction agent…"):
                result = run_redaction(selected, form)
            if result:
                st.session_state.last_job = result

    if "last_job" in st.session_state:
        job = st.session_state.last_job
        render_status_monitor(job)
        results = job.get("results") or []
        succeeded = [r for r in results if r.get("status") == "succeeded" and r.get("output_key")]
        if succeeded:
            render_side_by_side_preview(
                api_url=API_URL,
                raw_bucket=RAW_BUCKET,
                redacted_bucket=REDACTED_BUCKET,
                result=succeeded[0],
            )


if __name__ == "__main__":
    main()
