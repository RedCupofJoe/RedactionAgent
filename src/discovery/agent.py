"""Document Discovery Agent — search and summarize MinIO documents via catalog models."""

from __future__ import annotations

import logging
from dataclasses import asdict, dataclass, field
from typing import Any, Optional

from openai import OpenAI

from src.services.pdf_redactor import PDFRedactor
from src.services.s3_client import S3Client
from src.services.settings import Settings, get_settings
from src.services.telemetry import start_span
from src.services.vector_store import VectorStore

logger = logging.getLogger(__name__)


@dataclass
class DiscoveryHit:
    key: str
    page: int
    snippet: str
    score: float
    summary: str = ""


@dataclass
class DiscoveryResult:
    query: str
    hits: list = field(default_factory=list)
    indexed_docs: int = 0
    status: str = "ok"
    error: Optional[str] = None


class DiscoveryAgent:
    """Indexes raw documents and answers natural-language discovery queries."""

    def __init__(self, settings: Optional[Settings] = None) -> None:
        self.settings = settings or get_settings()
        self.s3 = S3Client(self.settings)
        self.redactor = PDFRedactor()
        self.vectors = VectorStore(
            self.settings,
            s3=self.s3,
            collection=self.settings.discovery_collection,
        )
        self.llm = OpenAI(
            base_url=self.settings.llm_base_url,
            api_key=self.settings.llm_api_key,
        )

    def index_raw_documents(self, keys: Optional[list] = None) -> int:
        with start_span("discovery.index_raw_documents"):
            docs = self.s3.list_documents(self.settings.s3_raw_bucket)
            if keys:
                keyset = set(keys)
                docs = [d for d in docs if d.key in keyset]
            count = 0
            for doc in docs:
                if not doc.key.lower().endswith(".pdf"):
                    continue
                pdf = self.s3.fetch_bytes(self.settings.s3_raw_bucket, doc.key)
                doc_id = doc.key.replace("/", "_")
                layout = self.redactor.extract_layout_and_text(pdf, doc_id=doc_id)
                chunks = self.redactor.chunk_pages(
                    layout,
                    chunk_size=self.settings.chunk_size,
                    chunk_overlap=self.settings.chunk_overlap,
                )
                for c in chunks:
                    c.text = f"[source:{doc.key}]\n{c.text}"
                count += self.vectors.index_chunks(chunks)
            return count

    def search(self, query: str, top_k: int = 5, summarize: bool = True) -> DiscoveryResult:
        result = DiscoveryResult(query=query)
        with start_span("discovery.search"):
            try:
                hits = self.vectors.query_event(query, top_k=top_k, score_threshold=0.05)
                for h in hits:
                    source = self._source_from_text(h.text)
                    snippet = h.text.split("\n", 1)[-1][:400]
                    summary = self._summarize(query, snippet) if summarize else ""
                    result.hits.append(
                        DiscoveryHit(
                            key=source,
                            page=h.page,
                            snippet=snippet,
                            score=h.score,
                            summary=summary,
                        )
                    )
                result.status = "ok"
            except Exception as exc:  # noqa: BLE001
                logger.exception("Discovery search failed")
                result.status = "failed"
                result.error = str(exc)
        return result

    @staticmethod
    def _source_from_text(text: str) -> str:
        if text.startswith("[source:") and "]" in text:
            return text[len("[source:") : text.index("]")]
        return "unknown"

    def _summarize(self, query: str, passage: str) -> str:
        try:
            resp = self.llm.chat.completions.create(
                model=self.settings.llm_model,
                temperature=0.1,
                max_tokens=180,
                messages=[
                    {
                        "role": "system",
                        "content": "Summarize how the passage relates to the user query in 2 sentences.",
                    },
                    {"role": "user", "content": f"Query: {query}\n\nPassage:\n{passage}"},
                ],
            )
            return (resp.choices[0].message.content or "").strip()
        except Exception as exc:  # noqa: BLE001
            logger.warning("Summarize failed: %s", exc)
            return passage[:180]

    def to_dict(self, result: DiscoveryResult) -> dict[str, Any]:
        return {
            "query": result.query,
            "status": result.status,
            "error": result.error,
            "hits": [asdict(h) for h in result.hits],
        }
