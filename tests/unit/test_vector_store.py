"""Unit tests for MinIO-backed vector store with local embeddings."""

from __future__ import annotations

import boto3
import pytest
from moto import mock_aws

from src.services.pdf_redactor import PageChunk
from src.services.s3_client import S3Client
from src.services.settings import Settings, get_settings
from src.services.vector_store import VectorStore


@pytest.fixture
def vector_settings(monkeypatch):
    monkeypatch.setenv("S3_ENDPOINT_URL", "https://s3.amazonaws.com")
    monkeypatch.setenv("S3_ACCESS_KEY", "testing")
    monkeypatch.setenv("S3_SECRET_KEY", "testing")
    monkeypatch.setenv("S3_VECTOR_BUCKET", "vector-index")
    monkeypatch.setenv("EMBEDDING_BASE_URL", "local://")
    monkeypatch.setenv("EMBEDDING_MODEL", "local")
    monkeypatch.setenv("EMBEDDING_DIM", "32")
    get_settings.cache_clear()
    return Settings(
        s3_endpoint_url="https://s3.amazonaws.com",
        s3_access_key="testing",
        s3_secret_key="testing",
        s3_vector_bucket="vector-index",
        embedding_base_url="local://",
        embedding_model="local",
        embedding_dim=32,
        vector_collection="redaction-events",
        event_score_threshold=0.01,
    )


@mock_aws
def test_index_and_query_event(vector_settings):
    client = boto3.client("s3", region_name="us-east-1")
    s3 = S3Client(vector_settings)
    s3._client = client
    store = VectorStore(settings=vector_settings, s3=s3)

    chunks = [
        PageChunk(
            doc_id="memo",
            page=0,
            chunk_id="memo:p0:c0",
            text="chemical spill at Plant B in July 2021 secondary containment",
        ),
        PageChunk(
            doc_id="memo",
            page=1,
            chunk_id="memo:p1:c0",
            text="employee picnic schedule and cafeteria hours",
        ),
    ]
    assert store.index_chunks(chunks) == 2
    hits = store.query_event("chemical spill at Plant B", doc_id="memo", top_k=2)
    assert hits
    assert hits[0].chunk_id == "memo:p0:c0"
    assert hits[0].score >= hits[-1].score
