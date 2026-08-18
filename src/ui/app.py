"""Streamlit dual-tab lab UI: Redaction Agent + Document Discovery Agent."""

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
DISCOVERY_URL = os.getenv("DISCOVERY_API_URL", "http://localhost:8001")
RAW_BUCKET = os.getenv("S3_RAW_BUCKET", "raw-documents")
REDACTED_BUCKET = os.getenv("S3_REDACTED_BUCKET", "redacted-documents")

st.set_page_config(
    page_title="OpenShift AI Lab Agents",
    page_icon="⬛",
    layout="wide",
    initial_sidebar_state="expanded",
)


def _inject_styles() -> None:
    st.markdown(
        """
        <style>
        @import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500&display=swap');
        /* Prefer light chrome so Streamlit does not paint white text on our light page. */
        html { color-scheme: light !important; }
        html, body, [class*="css"] { font-family: 'IBM Plex Sans', sans-serif; }
        .stApp {
          color: #1b1f24;
          background:
            radial-gradient(1200px 600px at 10% -10%, rgba(196,0,0,0.08), transparent 55%),
            linear-gradient(180deg, #f7f8fa 0%, #eef1f4 100%);
        }
        /* Main content: force readable dark text (overrides OS/browser dark theme). */
        section.main,
        section.main p,
        section.main span,
        section.main label,
        section.main li,
        section.main h1,
        section.main h2,
        section.main h3,
        section.main h4,
        section.main .stMarkdown,
        section.main [data-testid="stMarkdownContainer"],
        section.main [data-testid="stWidgetLabel"],
        section.main [data-testid="stCaptionContainer"],
        section.main [data-baseweb="tab"],
        section.main [data-baseweb="tab"] * {
          color: #1b1f24 !important;
        }
        section.main input,
        section.main textarea,
        section.main select {
          color: #1b1f24 !important;
          background-color: #ffffff !important;
        }
        section.main .stCodeBlock,
        section.main code,
        section.main pre {
          color: #1b1f24 !important;
        }
        .ra-brand { font-size: 2rem; font-weight: 700; color: #1b1f24 !important; margin: 0; }
        .ra-brand span { color: #c40000 !important; }
        .ra-sub { color: #5c6670 !important; font-size: 1.02rem; max-width: 52rem; }
        .ra-badge {
          display: inline-block; margin-top: 0.75rem;
          font-family: 'IBM Plex Mono', monospace; font-size: 0.78rem; color: #8f0000 !important;
          border-left: 3px solid #c40000; padding-left: 0.55rem;
        }
        div[data-testid="stSidebar"] { background: #1b1f24; }
        div[data-testid="stSidebar"],
        div[data-testid="stSidebar"] p,
        div[data-testid="stSidebar"] span,
        div[data-testid="stSidebar"] label,
        div[data-testid="stSidebar"] * {
          color: #f2f4f6 !important;
        }
        </style>
        """,
        unsafe_allow_html=True,
    )


def fetch_documents() -> list[dict[str, Any]]:
    try:
        with httpx.Client(timeout=30.0, verify=False) as client:
            resp = client.get(f"{API_URL}/documents", params={"bucket": RAW_BUCKET})
            resp.raise_for_status()
            return resp.json()
    except Exception as exc:  # noqa: BLE001
        st.error(f"Unable to list documents from {API_URL}: {exc}")
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
        with httpx.Client(timeout=600.0, verify=False) as client:
            resp = client.post(f"{API_URL}/redact", json=payload)
            resp.raise_for_status()
            return resp.json()
    except Exception as exc:  # noqa: BLE001
        st.error(f"Redaction job failed: {exc}")
        return None


def run_discovery(query: str, reindex: bool) -> dict[str, Any] | None:
    try:
        with httpx.Client(timeout=600.0, verify=False) as client:
            if reindex:
                client.post(f"{DISCOVERY_URL}/index", json={})
            resp = client.post(
                f"{DISCOVERY_URL}/search",
                json={"query": query, "top_k": 5, "summarize": True, "reindex": False},
            )
            resp.raise_for_status()
            return resp.json()
    except Exception as exc:  # noqa: BLE001
        st.error(f"Discovery failed: {exc}")
        return None


def main() -> None:
    _inject_styles()

    with st.sidebar:
        st.markdown("### OpenShift AI Lab")
        st.caption("RHOAI · GitOps · L40S GPUs · Observability")
        st.text_input("Redaction API", value=API_URL, disabled=True)
        st.text_input("Discovery API", value=DISCOVERY_URL, disabled=True)
        st.text_input("Raw bucket", value=RAW_BUCKET, disabled=True)
        if st.button("Refresh documents", use_container_width=True):
            st.session_state.pop("documents", None)

    st.markdown(
        """
        <h1 class="ra-brand">Lab <span>Agents</span></h1>
        <p class="ra-sub">
          Redact sensitive content from public-record PDFs, or discover related passages across
          the same MinIO corpus — both powered by OpenShift AI catalog models.
        </p>
        <div class="ra-badge">MinIO · Catalog SLM/Embed · GitOps · OpenTelemetry</div>
        """,
        unsafe_allow_html=True,
    )

    if "documents" not in st.session_state:
        st.session_state.documents = fetch_documents()

    tab_redact, tab_discover = st.tabs(["Redaction Agent", "Document Discovery Agent"])

    with tab_redact:
        st.markdown("#### Step 1 — Select documents")
        selected = render_document_picker(st.session_state.documents)
        st.markdown("#### Step 2 — What should be redacted?")
        form = render_redaction_form()
        if st.button("Run redaction", type="primary", disabled=not selected):
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
            succeeded = [
                r
                for r in (job.get("results") or [])
                if r.get("status") == "succeeded" and r.get("output_key")
            ]
            if succeeded:
                render_side_by_side_preview(
                    api_url=API_URL,
                    raw_bucket=RAW_BUCKET,
                    redacted_bucket=REDACTED_BUCKET,
                    result=succeeded[0],
                )

    with tab_discover:
        st.markdown("#### Ask what you want to find in the corpus")
        st.caption(
            "Indexes PDFs from MinIO `raw-documents`, searches with catalog embeddings, "
            "and summarizes hits with the catalog SLM."
        )
        query = st.text_input(
            "Discovery query",
            placeholder='e.g. "chemical spill at Plant B"',
        )
        reindex = st.checkbox("Re-index documents before search", value=False)
        if st.button("Search documents", type="primary", disabled=not (query or "").strip()):
            with st.spinner("Running discovery agent…"):
                result = run_discovery(query.strip(), reindex=reindex)
            if result:
                st.session_state.last_discovery = result
        if "last_discovery" in st.session_state:
            disco = st.session_state.last_discovery
            st.write(f"Status: **{disco.get('status')}**")
            if disco.get("error"):
                st.error(disco["error"])
            for hit in disco.get("hits") or []:
                st.markdown(
                    f"**`{hit.get('key')}`** (page {hit.get('page')}, score {hit.get('score', 0):.3f})"
                )
                if hit.get("summary"):
                    st.write(hit["summary"])
                with st.expander("Snippet"):
                    st.code(hit.get("snippet") or "", language="text")


if __name__ == "__main__":
    main()
