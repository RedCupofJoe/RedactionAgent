"""Semantic event index using OpenShift AI catalog embeddings + MinIO storage.

Platform-first design:
- Embeddings come from an OpenAI-compatible InferenceService deployed from the
  OpenShift AI default model catalog (not in-pod Hugging Face downloads).
- Vectors and chunk payloads are stored in MinIO (lab-allowed object store),
  not a separate third-party vector database.
"""

from __future__ import annotations

import hashlib
import json
import logging
import math
import re
from dataclasses import asdict, dataclass
from typing import Any, Optional

from openai import OpenAI

from src.services.pdf_redactor import PageChunk
from src.services.s3_client import S3Client
from src.services.settings import Settings, get_settings

logger = logging.getLogger(__name__)


@dataclass
class EventHit:
    chunk_id: str
    doc_id: str
    page: int
    text: str
    score: float
    payload: dict[str, Any]


@dataclass
class IndexedChunk:
    chunk_id: str
    doc_id: str
    page: int
    text: str
    vector: list[float]


def _cosine(a: list[float], b: list[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0.0 or nb == 0.0:
        return 0.0
    return dot / (na * nb)


def _l2_normalize(vector: list[float]) -> list[float]:
    norm = math.sqrt(sum(x * x for x in vector))
    if norm == 0.0:
        return vector
    return [x / norm for x in vector]


class CatalogEmbedder:
    """OpenAI-compatible embeddings client aimed at an RHOAI catalog InferenceService."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._client = OpenAI(
            base_url=settings.embedding_base_url,
            api_key=settings.embedding_api_key or settings.llm_api_key or "unused",
        )

    def embed(self, texts: list[str]) -> list[list[float]]:
        if not texts:
            return []
        # Local deterministic fallback for offline unit tests / demos without a catalog embedder
        if self.settings.embedding_base_url.startswith("local://"):
            return [_local_embed(t, self.settings.embedding_dim) for t in texts]
        try:
            response = self._client.embeddings.create(
                model=self.settings.embedding_model,
                input=texts,
            )
            # OpenAI returns data sorted by index
            ordered = sorted(response.data, key=lambda d: d.index)
            return [_l2_normalize(list(d.embedding)) for d in ordered]
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "Catalog embedding call failed (%s); using local lexical fallback vectors",
                exc,
            )
            return [_local_embed(t, self.settings.embedding_dim) for t in texts]

    def embed_one(self, text: str) -> list[float]:
        return self.embed([text])[0]


def _local_embed(text: str, dim: int) -> list[float]:
    """Deterministic bag-of-tokens hash embedding (offline fallback only)."""
    vec = [0.0] * dim
    tokens = re.findall(r"[a-z0-9]{3,}", text.lower())
    if not tokens:
        tokens = ["empty"]
    for tok in tokens:
        digest = hashlib.sha256(tok.encode("utf-8")).digest()
        for i in range(0, min(len(digest), dim)):
            vec[i % dim] += (digest[i] - 128) / 128.0
    return _l2_normalize(vec)


class VectorStore:
    """Indexes PDF chunks into MinIO and runs cosine semantic search."""

    def __init__(
        self,
        settings: Optional[Settings] = None,
        s3: Optional[S3Client] = None,
        embedder: Optional[CatalogEmbedder] = None,
        collection: Optional[str] = None,
    ) -> None:
        self.settings = settings or get_settings()
        self.s3 = s3 or S3Client(self.settings)
        self.embedder = embedder or CatalogEmbedder(self.settings)
        self.collection = collection or self.settings.vector_collection
        self.bucket = self.settings.s3_vector_bucket

    def ensure_collection(self) -> None:
        self.s3.ensure_buckets([self.bucket])

    def _doc_key(self, doc_id: str) -> str:
        safe = doc_id.replace("/", "_")
        return f"{self.collection}/{safe}.json"

    def index_chunks(self, chunks: list[PageChunk], *, replace_doc: bool = True) -> int:
        if not chunks:
            return 0
        self.ensure_collection()
        doc_id = chunks[0].doc_id
        texts = [c.text for c in chunks]
        vectors = self.embedder.embed(texts)
        records = [
            IndexedChunk(
                chunk_id=chunk.chunk_id,
                doc_id=chunk.doc_id,
                page=chunk.page,
                text=chunk.text,
                vector=vector,
            )
            for chunk, vector in zip(chunks, vectors)
        ]
        payload = {
            "collection": self.collection,
            "doc_id": doc_id,
            "chunks": [asdict(r) for r in records],
        }
        body = json.dumps(payload).encode("utf-8")
        self.s3.upload_bytes(
            self.bucket,
            self._doc_key(doc_id),
            body,
            content_type="application/json",
        )
        logger.info(
            "Indexed %d chunks for doc_id=%s into s3://%s/%s",
            len(records),
            doc_id,
            self.bucket,
            self._doc_key(doc_id),
        )
        return len(records)

    def delete_document(self, doc_id: str) -> None:
        self.ensure_collection()
        key = self._doc_key(doc_id)
        try:
            self.s3._client.delete_object(Bucket=self.bucket, Key=key)
        except Exception as exc:  # noqa: BLE001
            logger.debug("delete_document %s: %s", doc_id, exc)

    def _load_doc_chunks(self, doc_id: str) -> list[IndexedChunk]:
        key = self._doc_key(doc_id)
        if not self.s3.object_exists(self.bucket, key):
            return []
        raw = self.s3.fetch_bytes(self.bucket, key)
        data = json.loads(raw.decode("utf-8"))
        return [IndexedChunk(**c) for c in data.get("chunks", [])]

    def _load_all_chunks(self) -> list[IndexedChunk]:
        docs = self.s3.list_documents(self.bucket, prefix=f"{self.collection}/")
        chunks: list[IndexedChunk] = []
        for doc in docs:
            if not doc.key.endswith(".json"):
                continue
            raw = self.s3.fetch_bytes(self.bucket, doc.key)
            data = json.loads(raw.decode("utf-8"))
            chunks.extend(IndexedChunk(**c) for c in data.get("chunks", []))
        return chunks

    def query_event(
        self,
        event_description: str,
        *,
        doc_id: Optional[str] = None,
        top_k: Optional[int] = None,
        score_threshold: Optional[float] = None,
    ) -> list[EventHit]:
        self.ensure_collection()
        top_k = top_k if top_k is not None else self.settings.event_top_k
        score_threshold = (
            score_threshold
            if score_threshold is not None
            else self.settings.event_score_threshold
        )
        query_vector = self.embedder.embed_one(event_description)
        candidates = self._load_doc_chunks(doc_id) if doc_id else self._load_all_chunks()

        scored: list[EventHit] = []
        for chunk in candidates:
            score = _cosine(query_vector, chunk.vector)
            if score < score_threshold:
                continue
            scored.append(
                EventHit(
                    chunk_id=chunk.chunk_id,
                    doc_id=chunk.doc_id,
                    page=chunk.page,
                    text=chunk.text,
                    score=score,
                    payload={
                        "chunk_id": chunk.chunk_id,
                        "doc_id": chunk.doc_id,
                        "page": chunk.page,
                        "text": chunk.text,
                    },
                )
            )
        scored.sort(key=lambda h: h.score, reverse=True)
        return scored[:top_k]
