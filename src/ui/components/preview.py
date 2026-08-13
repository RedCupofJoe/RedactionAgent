"""Side-by-side original vs redacted PDF preview."""

from __future__ import annotations

from typing import Any

import httpx
import streamlit as st


def _fetch_pdf(api_url: str, bucket: str, key: str) -> bytes | None:
    url = f"{api_url}/documents/{bucket}/{key}/bytes"
    try:
        with httpx.Client(timeout=60.0) as client:
            resp = client.get(url)
            resp.raise_for_status()
            return resp.content
    except Exception as exc:  # noqa: BLE001
        st.warning(f"Could not load {bucket}/{key}: {exc}")
        return None


def render_side_by_side_preview(
    *,
    api_url: str,
    raw_bucket: str,
    redacted_bucket: str,
    result: dict[str, Any],
) -> None:
    st.subheader("Visual preview")
    st.caption("Original vs permanently redacted PDF (first selected successful result).")

    source_key = result.get("source_key")
    output_key = result.get("output_key")
    if not source_key or not output_key:
        return

    left, right = st.columns(2)
    with left:
        st.markdown("**Original**")
        original = _fetch_pdf(api_url, raw_bucket, source_key)
        if original:
            st.download_button(
                "Download original",
                data=original,
                file_name=str(source_key).split("/")[-1],
                mime="application/pdf",
                use_container_width=True,
            )
            # Streamlit cannot natively render PDF; offer page images if PyMuPDF available
            _render_first_page(original)

    with right:
        st.markdown("**Redacted**")
        redacted = _fetch_pdf(api_url, redacted_bucket, output_key)
        if redacted:
            st.download_button(
                "Download redacted",
                data=redacted,
                file_name=str(output_key).split("/")[-1],
                mime="application/pdf",
                use_container_width=True,
            )
            _render_first_page(redacted)


def _render_first_page(pdf_bytes: bytes) -> None:
    try:
        import fitz

        doc = fitz.open(stream=pdf_bytes, filetype="pdf")
        try:
            page = doc[0]
            pix = page.get_pixmap(matrix=fitz.Matrix(1.5, 1.5), alpha=False)
            st.image(pix.tobytes("png"), use_container_width=True)
        finally:
            doc.close()
    except Exception:  # noqa: BLE001
        st.info("PDF loaded. Install/use PyMuPDF in the UI image for inline page preview.")
