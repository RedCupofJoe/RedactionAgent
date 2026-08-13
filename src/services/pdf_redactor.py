"""PDF layout extraction and permanent redaction using PyMuPDF (fitz)."""

from __future__ import annotations

import logging
import re
from dataclasses import asdict, dataclass, field
from typing import Any

import fitz

logger = logging.getLogger(__name__)


@dataclass
class TextSpan:
    text: str
    page: int
    bbox: tuple[float, float, float, float]  # x0, y0, x1, y1
    block_no: int = 0
    line_no: int = 0


@dataclass
class PageChunk:
    doc_id: str
    page: int
    chunk_id: str
    text: str
    spans: list[TextSpan] = field(default_factory=list)


@dataclass
class RedactionTarget:
    page: int
    bbox: tuple[float, float, float, float]
    reason: str = ""
    matched_text: str = ""


class PDFRedactor:
    """Extract layout-aware text and burn solid black redaction rectangles into PDFs."""

    def extract_layout_and_text(self, pdf_bytes: bytes, doc_id: str = "doc") -> dict[str, Any]:
        document = fitz.open(stream=pdf_bytes, filetype="pdf")
        pages: list[dict[str, Any]] = []
        all_spans: list[TextSpan] = []

        try:
            for page_index in range(len(document)):
                page = document[page_index]
                page_dict = page.get_text("dict")
                page_spans: list[TextSpan] = []
                page_text_parts: list[str] = []

                for block in page_dict.get("blocks", []):
                    if block.get("type") != 0:
                        continue
                    for line in block.get("lines", []):
                        line_text = "".join(span.get("text", "") for span in line.get("spans", []))
                        if line_text.strip():
                            page_text_parts.append(line_text)
                        for span in line.get("spans", []):
                            text = span.get("text", "")
                            if not text.strip():
                                continue
                            bbox = tuple(float(v) for v in span["bbox"])  # type: ignore[misc]
                            ts = TextSpan(
                                text=text,
                                page=page_index,
                                bbox=(bbox[0], bbox[1], bbox[2], bbox[3]),
                                block_no=int(block.get("number", 0)),
                                line_no=int(line.get("wmode", 0)),
                            )
                            page_spans.append(ts)
                            all_spans.append(ts)

                pages.append(
                    {
                        "page": page_index,
                        "width": float(page.rect.width),
                        "height": float(page.rect.height),
                        "text": "\n".join(page_text_parts),
                        "spans": [asdict(s) for s in page_spans],
                    }
                )
        finally:
            document.close()

        return {
            "doc_id": doc_id,
            "page_count": len(pages),
            "pages": pages,
            "spans": [asdict(s) for s in all_spans],
        }

    def find_text_bboxes(
        self,
        pdf_bytes: bytes,
        patterns: list[str],
        *,
        use_regex: bool = False,
        case_insensitive: bool = True,
    ) -> list[RedactionTarget]:
        """Locate bounding boxes for literal strings or regex patterns."""
        document = fitz.open(stream=pdf_bytes, filetype="pdf")
        flags = fitz.TEXT_DEHYPHENATE
        targets: list[RedactionTarget] = []

        try:
            for page_index in range(len(document)):
                page = document[page_index]
                for pattern in patterns:
                    if not pattern or not pattern.strip():
                        continue
                    if use_regex:
                        compiled = re.compile(
                            pattern,
                            re.IGNORECASE if case_insensitive else 0,
                        )
                        words = page.get_text("words")
                        # words: x0, y0, x1, y1, word, block, line, word_no
                        page_text = page.get_text("text")
                        for match in compiled.finditer(page_text):
                            # Approximate: search matched string as literal quads
                            matched = match.group(0)
                            for rect in page.search_for(matched, flags=flags):
                                targets.append(
                                    RedactionTarget(
                                        page=page_index,
                                        bbox=(rect.x0, rect.y0, rect.x1, rect.y1),
                                        reason="regex",
                                        matched_text=matched,
                                    )
                                )
                        # Fallback word-level scan if search_for missed
                        if not any(t.page == page_index and t.reason == "regex" for t in targets):
                            for w in words:
                                word = str(w[4])
                                if compiled.search(word):
                                    targets.append(
                                        RedactionTarget(
                                            page=page_index,
                                            bbox=(float(w[0]), float(w[1]), float(w[2]), float(w[3])),
                                            reason="regex-word",
                                            matched_text=word,
                                        )
                                    )
                    else:
                        needle = pattern if not case_insensitive else pattern
                        rects = page.search_for(
                            needle,
                            flags=flags,
                            quads=False,
                        )
                        # PyMuPDF search is case-sensitive; do a secondary lower pass
                        if case_insensitive and not rects:
                            # Search page text case-insensitively via words join
                            hay = page.get_text("text")
                            idx = hay.lower().find(pattern.lower())
                            if idx >= 0:
                                rects = page.search_for(hay[idx : idx + len(pattern)], flags=flags)
                        for rect in rects:
                            targets.append(
                                RedactionTarget(
                                    page=page_index,
                                    bbox=(rect.x0, rect.y0, rect.x1, rect.y1),
                                    reason="literal",
                                    matched_text=pattern,
                                )
                            )
        finally:
            document.close()

        return self._dedupe_targets(targets)

    def apply_redactions(
        self,
        pdf_bytes: bytes,
        redaction_targets: list[RedactionTarget | dict[str, Any]],
        *,
        fill_color: tuple[float, float, float] = (0, 0, 0),
        burn_in: bool = True,
    ) -> bytes:
        """Draw opaque redaction rectangles and optionally permanently apply them."""
        document = fitz.open(stream=pdf_bytes, filetype="pdf")
        applied = 0

        try:
            for raw in redaction_targets:
                target = (
                    raw
                    if isinstance(raw, RedactionTarget)
                    else RedactionTarget(
                        page=int(raw["page"]),
                        bbox=tuple(raw["bbox"]),  # type: ignore[arg-type]
                        reason=str(raw.get("reason", "")),
                        matched_text=str(raw.get("matched_text", "")),
                    )
                )
                if target.page < 0 or target.page >= len(document):
                    logger.warning("Skipping out-of-range page %s", target.page)
                    continue
                page = document[target.page]
                rect = fitz.Rect(*target.bbox)
                # Slight padding so glyphs are fully covered
                rect = rect + (-1, -1, 1, 1)
                page.add_redact_annot(rect, fill=fill_color)
                applied += 1

            if burn_in:
                for page in document:
                    page.apply_redactions(images=fitz.PDF_REDACT_IMAGE_NONE)

            output = document.tobytes(deflate=True, garbage=3)
            logger.info("Applied %d redaction annotations (burn_in=%s)", applied, burn_in)
            return output
        finally:
            document.close()

    def chunk_pages(
        self,
        layout: dict[str, Any],
        *,
        chunk_size: int = 800,
        chunk_overlap: int = 120,
    ) -> list[PageChunk]:
        """Split extracted page text into overlapping chunks with page metadata."""
        doc_id = layout.get("doc_id", "doc")
        chunks: list[PageChunk] = []
        for page in layout.get("pages", []):
            text = page.get("text", "") or ""
            page_no = int(page["page"])
            spans = [TextSpan(**s) if isinstance(s, dict) else s for s in page.get("spans", [])]
            if not text.strip():
                continue
            start = 0
            chunk_idx = 0
            while start < len(text):
                end = min(len(text), start + chunk_size)
                piece = text[start:end]
                chunks.append(
                    PageChunk(
                        doc_id=doc_id,
                        page=page_no,
                        chunk_id=f"{doc_id}:p{page_no}:c{chunk_idx}",
                        text=piece,
                        spans=spans,
                    )
                )
                if end >= len(text):
                    break
                start = max(0, end - chunk_overlap)
                chunk_idx += 1
        return chunks

    @staticmethod
    def _dedupe_targets(targets: list[RedactionTarget]) -> list[RedactionTarget]:
        seen: set[tuple[int, float, float, float, float]] = set()
        unique: list[RedactionTarget] = []
        for t in targets:
            key = (
                t.page,
                round(t.bbox[0], 1),
                round(t.bbox[1], 1),
                round(t.bbox[2], 1),
                round(t.bbox[3], 1),
            )
            if key in seen:
                continue
            seen.add(key)
            unique.append(t)
        return unique
