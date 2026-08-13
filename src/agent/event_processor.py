"""SLM-assisted event confirmation and passage-to-bbox mapping."""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from typing import Any

from openai import OpenAI

from src.services.pdf_redactor import PDFRedactor, RedactionTarget
from src.services.settings import Settings, get_settings
from src.services.vector_store import EventHit, VectorStore

logger = logging.getLogger(__name__)

CONFIRM_SYSTEM = """You are a careful legal redaction analyst.
Decide whether a retrieved document passage refers to the TARGET EVENT.
Reply with JSON only: {"relevant": true|false, "confidence": 0.0-1.0, "excerpt": "shortest confirming quote"}
If not relevant, set relevant=false and excerpt="".
"""


@dataclass
class ConfirmedPassage:
    page: int
    text: str
    excerpt: str
    confidence: float
    score: float


class EventProcessor:
    """Semantic event search + SLM confirmation + redaction target generation."""

    def __init__(
        self,
        vector_store: VectorStore | None = None,
        redactor: PDFRedactor | None = None,
        settings: Settings | None = None,
    ) -> None:
        self.settings = settings or get_settings()
        self.vector_store = vector_store or VectorStore(self.settings)
        self.redactor = redactor or PDFRedactor()
        self.llm = OpenAI(
            base_url=self.settings.llm_base_url,
            api_key=self.settings.llm_api_key,
        )

    def index_document(self, doc_id: str, pdf_bytes: bytes) -> int:
        layout = self.redactor.extract_layout_and_text(pdf_bytes, doc_id=doc_id)
        chunks = self.redactor.chunk_pages(
            layout,
            chunk_size=self.settings.chunk_size,
            chunk_overlap=self.settings.chunk_overlap,
        )
        return self.vector_store.index_chunks(chunks)

    def find_event_targets(
        self,
        event_description: str,
        doc_id: str,
        pdf_bytes: bytes,
    ) -> list[RedactionTarget]:
        hits = self.vector_store.query_event(event_description, doc_id=doc_id)
        confirmed = self._confirm_hits(event_description, hits)
        targets: list[RedactionTarget] = []
        for passage in confirmed:
            needles = self._candidate_needles(passage)
            found = self.redactor.find_text_bboxes(pdf_bytes, needles, use_regex=False)
            for t in found:
                if t.page != passage.page:
                    continue
                targets.append(
                    RedactionTarget(
                        page=t.page,
                        bbox=t.bbox,
                        reason=f"event:{event_description[:80]}",
                        matched_text=t.matched_text,
                    )
                )
            # If literal search failed, redact whole chunk page spans that overlap excerpt words
            if not found and passage.excerpt:
                approx = self.redactor.find_text_bboxes(
                    pdf_bytes,
                    [w for w in re.findall(r"[A-Za-z0-9]{4,}", passage.excerpt)[:6]],
                    use_regex=False,
                )
                for t in approx:
                    if t.page == passage.page:
                        targets.append(
                            RedactionTarget(
                                page=t.page,
                                bbox=t.bbox,
                                reason="event-approx",
                                matched_text=t.matched_text,
                            )
                        )
        return self.redactor._dedupe_targets(targets)

    def _confirm_hits(
        self,
        event_description: str,
        hits: list[EventHit],
    ) -> list[ConfirmedPassage]:
        confirmed: list[ConfirmedPassage] = []
        for hit in hits:
            decision = self._llm_confirm(event_description, hit.text)
            if decision.get("relevant") is True:
                confirmed.append(
                    ConfirmedPassage(
                        page=hit.page,
                        text=hit.text,
                        excerpt=str(decision.get("excerpt") or hit.text[:240]),
                        confidence=float(decision.get("confidence") or 0.0),
                        score=hit.score,
                    )
                )
        logger.info(
            "Event confirmation: %d/%d passages relevant for doc hits",
            len(confirmed),
            len(hits),
        )
        return confirmed

    def _llm_confirm(self, event_description: str, passage: str) -> dict[str, Any]:
        user = (
            f"TARGET EVENT:\n{event_description}\n\n"
            f"PASSAGE:\n{passage[:3000]}\n"
        )
        try:
            response = self.llm.chat.completions.create(
                model=self.settings.llm_model,
                temperature=self.settings.llm_temperature,
                max_tokens=min(256, self.settings.llm_max_tokens),
                messages=[
                    {"role": "system", "content": CONFIRM_SYSTEM},
                    {"role": "user", "content": user},
                ],
            )
            content = response.choices[0].message.content or "{}"
            return self._parse_json(content)
        except Exception as exc:  # noqa: BLE001
            logger.warning("LLM confirmation failed, falling back to heuristic: %s", exc)
            # Heuristic fallback when LLM endpoint is unavailable
            tokens = set(re.findall(r"[a-z0-9]{4,}", event_description.lower()))
            passage_l = passage.lower()
            overlap = sum(1 for t in tokens if t in passage_l)
            relevant = overlap >= max(2, len(tokens) // 3)
            return {
                "relevant": relevant,
                "confidence": min(1.0, overlap / max(1, len(tokens))),
                "excerpt": passage[:200] if relevant else "",
            }

    @staticmethod
    def _parse_json(content: str) -> dict[str, Any]:
        content = content.strip()
        try:
            return json.loads(content)
        except json.JSONDecodeError:
            match = re.search(r"\{.*\}", content, re.DOTALL)
            if match:
                try:
                    return json.loads(match.group(0))
                except json.JSONDecodeError:
                    pass
        return {"relevant": False, "confidence": 0.0, "excerpt": ""}

    @staticmethod
    def _candidate_needles(passage: ConfirmedPassage) -> list[str]:
        needles: list[str] = []
        if passage.excerpt and len(passage.excerpt.strip()) >= 8:
            needles.append(passage.excerpt.strip())
            # Also try first sentence-ish fragment
            frag = re.split(r"[.\n]", passage.excerpt.strip())[0].strip()
            if frag and frag not in needles and len(frag) >= 8:
                needles.append(frag)
        # Fall back to a window from the chunk
        window = passage.text.strip()
        if window:
            needles.append(window[:120])
        return needles
