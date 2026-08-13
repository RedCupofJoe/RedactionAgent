"""Application settings loaded from environment variables."""

from __future__ import annotations

from functools import lru_cache
from typing import Optional

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # S3 / MinIO
    s3_endpoint_url: str = "http://localhost:9000"
    s3_access_key: str = "minioadmin"
    s3_secret_key: str = "minioadmin"
    s3_region: str = "us-east-1"
    s3_raw_bucket: str = "raw-documents"
    s3_redacted_bucket: str = "redacted-documents"
    s3_secure: bool = False

    # Qdrant
    qdrant_url: str = "http://localhost:6333"
    qdrant_collection: str = "redaction-events"
    qdrant_api_key: Optional[str] = None

    # Embeddings
    embedding_model: str = "BAAI/bge-small-en-v1.5"
    embedding_dim: int = 384

    # LLM (RHOAI vLLM OpenAI-compatible)
    llm_base_url: str = "http://localhost:8001/v1"
    llm_api_key: str = "unused"
    llm_model: str = "ibm-granite/granite-3.2-8b-instruct"
    llm_temperature: float = 0.1
    llm_max_tokens: int = 1024

    # MCP
    mcp_gateway_url: str = "http://localhost:8080"
    mcp_server_host: str = "0.0.0.0"
    mcp_server_port: int = 8080

    # Agent
    agent_api_url: str = "http://localhost:8000"
    log_level: str = "INFO"
    chunk_size: int = 800
    chunk_overlap: int = 120
    event_top_k: int = 8
    event_score_threshold: float = 0.55


@lru_cache
def get_settings() -> Settings:
    return Settings()
