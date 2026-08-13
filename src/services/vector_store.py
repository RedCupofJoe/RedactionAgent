"""Qdrant vector store for semantic event correlation."""

from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass
from typing import Any

from qdrant_client import QdrantClient
from qdrant_client.http import models as qm

from src.services.pdf_redactor import PageChunk
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


class EmbeddingModel:
    """Lazy-loaded sentence-transformers embedder (bge-small-en-v1.5 by default)."""

    def __init__(self, model_name: str) -> None:
        self.model_name = model_name
        self._model = None

    def _load(self):
        if self._model is None:
            from sentence_transformers import SentenceTransformer

            logger.info("Loading embedding model: %s", self.model_name)
            self._model = SentenceTransformer(self.model_name)
        return self._model

    def embed(self, texts: list[str]) -> list[list[float]]:
        model = self._load()
        vectors = model.encode(texts, normalize_embeddings=True, show_progress_bar=False)
        return [v.tolist() for v in vectors]

    def embed_one(self, text: str) -> list[float]:
        return self.embed([text])[0]


class VectorStore:
    """Indexes PDF chunks and runs semantic search for event redaction."""

    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or get_settings()
        self.client = QdrantClient(
            url=self.settings.qdrant_url,
            api_key=self.settings.qdrant_api_key or None,
            prefer_grpc=False,
        )
        self.embedder = EmbeddingModel(self.settings.embedding_model)
        self.collection = self.settings.qdrant_collection

    def ensure_collection(self) -> None:
        existing = {c.name for c in self.client.get_collections().collections}
        if self.collection in existing:
            return
        logger.info("Creating Qdrant collection: %s", self.collection)
        self.client.create_collection(
            collection_name=self.collection,
            vectors_config=qm.VectorParams(
                size=self.settings.embedding_dim,
                distance=qm.Distance.COSINE,
            ),
        )
        self.client.create_payload_index(
            collection_name=self.collection,
            field_name="doc_id",
            field_schema=qm.PayloadSchemaType.KEYWORD,
        )

    def index_chunks(self, chunks: list[PageChunk], *, replace_doc: bool = True) -> int:
        if not chunks:
            return 0
        self.ensure_collection()
        doc_id = chunks[0].doc_id
        if replace_doc:
            self.delete_document(doc_id)

        texts = [c.text for c in chunks]
        vectors = self.embedder.embed(texts)
        points: list[qm.PointStruct] = []
        for chunk, vector in zip(chunks, vectors, strict=True):
            points.append(
                qm.PointStruct(
                    id=str(uuid.uuid5(uuid.NAMESPACE_URL, chunk.chunk_id)),
                    vector=vector,
                    payload={
                        "chunk_id": chunk.chunk_id,
                        "doc_id": chunk.doc_id,
                        "page": chunk.page,
                        "text": chunk.text,
                    },
                )
            )
        self.client.upsert(collection_name=self.collection, points=points)
        logger.info("Indexed %d chunks for doc_id=%s", len(points), doc_id)
        return len(points)

    def delete_document(self, doc_id: str) -> None:
        self.ensure_collection()
        self.client.delete(
            collection_name=self.collection,
            points_selector=qm.FilterSelector(
                filter=qm.Filter(
                    must=[qm.FieldCondition(key="doc_id", match=qm.MatchValue(value=doc_id))]
                )
            ),
        )

    def query_event(
        self,
        event_description: str,
        *,
        doc_id: str | None = None,
        top_k: int | None = None,
        score_threshold: float | None = None,
    ) -> list[EventHit]:
        self.ensure_collection()
        top_k = top_k if top_k is not None else self.settings.event_top_k
        score_threshold = (
            score_threshold
            if score_threshold is not None
            else self.settings.event_score_threshold
        )
        query_vector = self.embedder.embed_one(event_description)
        query_filter = None
        if doc_id:
            query_filter = qm.Filter(
                must=[qm.FieldCondition(key="doc_id", match=qm.MatchValue(value=doc_id))]
            )

        results = self.client.search(
            collection_name=self.collection,
            query_vector=query_vector,
            query_filter=query_filter,
            limit=top_k,
            score_threshold=score_threshold,
            with_payload=True,
        )

        hits: list[EventHit] = []
        for point in results:
            payload = point.payload or {}
            hits.append(
                EventHit(
                    chunk_id=str(payload.get("chunk_id", "")),
                    doc_id=str(payload.get("doc_id", "")),
                    page=int(payload.get("page", 0)),
                    text=str(payload.get("text", "")),
                    score=float(point.score or 0.0),
                    payload=payload,
                )
            )
        return hits
