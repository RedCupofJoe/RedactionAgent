"""Unit tests for S3 client against moto."""

from __future__ import annotations

import boto3
import pytest
from moto import mock_aws

from src.services.s3_client import S3Client
from src.services.settings import Settings


@pytest.fixture
def s3_settings(monkeypatch):
    monkeypatch.setenv("S3_ENDPOINT_URL", "https://s3.amazonaws.com")
    monkeypatch.setenv("S3_ACCESS_KEY", "testing")
    monkeypatch.setenv("S3_SECRET_KEY", "testing")
    monkeypatch.setenv("S3_RAW_BUCKET", "raw-documents")
    monkeypatch.setenv("S3_REDACTED_BUCKET", "redacted-documents")
    from src.services.settings import get_settings

    get_settings.cache_clear()
    return Settings(
        s3_endpoint_url="https://s3.amazonaws.com",
        s3_access_key="testing",
        s3_secret_key="testing",
        s3_raw_bucket="raw-documents",
        s3_redacted_bucket="redacted-documents",
        s3_secure=True,
    )


@mock_aws
def test_ensure_buckets_and_roundtrip(s3_settings):
    # moto uses default AWS endpoint; create client without custom endpoint quirks
    client = boto3.client("s3", region_name="us-east-1")
    wrapper = S3Client(s3_settings)
    wrapper._client = client

    wrapper.ensure_buckets()
    wrapper.upload_bytes("raw-documents", "demo/a.pdf", b"%PDF-1.4 demo")
    docs = wrapper.list_documents("raw-documents")
    assert any(d.key == "demo/a.pdf" for d in docs)
    assert wrapper.fetch_bytes("raw-documents", "demo/a.pdf") == b"%PDF-1.4 demo"
