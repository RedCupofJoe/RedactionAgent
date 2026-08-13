"""MCP tools exposed by the redaction agent gateway."""

from __future__ import annotations

import logging
from dataclasses import asdict
from typing import Any

from src.agent.event_processor import EventProcessor
from src.services.pdf_redactor import PDFRedactor, RedactionTarget
from src.services.s3_client import S3Client
from src.services.settings import Settings, get_settings
from src.services.vector_store import VectorStore

logger = logging.getLogger(__name__)


class RedactionMCPTools:
    """Standard MCP tool implementations for the Auto Redaction Agent."""

    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or get_settings()
        self.s3 = S3Client(self.settings)
        self.redactor = PDFRedactor()
        self.vector_store = VectorStore(self.settings)
        self.event_processor = EventProcessor(
            vector_store=self.vector_store,
            redactor=self.redactor,
            settings=self.settings,
        )

    # --- Tool: list_s3_documents ---
    def list_s3_documents(self, bucket_name: str) -> list[dict[str, Any]]:
        docs = self.s3.list_documents(bucket_name)
        return [asdict(d) for d in docs]

    # --- Tool: fetch_document_bytes ---
    def fetch_document_bytes(self, bucket_name: str, file_key: str) -> bytes:
        return self.s3.fetch_bytes(bucket_name, file_key)

    # --- Tool: extract_pdf_layout_and_text ---
    def extract_pdf_layout_and_text(self, pdf_bytes: bytes, doc_id: str = "doc") -> dict[str, Any]:
        return self.redactor.extract_layout_and_text(pdf_bytes, doc_id=doc_id)

    # --- Tool: query_event_vector_index ---
    def query_event_vector_index(
        self,
        event_description: str,
        doc_id: str,
    ) -> list[dict[str, Any]]:
        hits = self.vector_store.query_event(event_description, doc_id=doc_id)
        return [asdict(h) for h in hits]

    # --- Tool: apply_pdf_redactions ---
    def apply_pdf_redactions(
        self,
        pdf_bytes: bytes,
        redaction_targets: list[dict[str, Any] | RedactionTarget],
    ) -> bytes:
        return self.redactor.apply_redactions(pdf_bytes, redaction_targets)

    # --- Tool: save_redacted_document ---
    def save_redacted_document(
        self,
        bucket_name: str,
        file_key: str,
        pdf_bytes: bytes,
    ) -> str:
        return self.s3.upload_bytes(bucket_name, file_key, pdf_bytes)

    def tool_specs(self) -> list[dict[str, Any]]:
        """OpenAI / MCP-compatible tool schema definitions."""
        return [
            {
                "name": "list_s3_documents",
                "description": "List objects in an S3/MinIO bucket.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "bucket_name": {"type": "string"},
                    },
                    "required": ["bucket_name"],
                },
            },
            {
                "name": "fetch_document_bytes",
                "description": "Download a document from S3/MinIO as bytes.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "bucket_name": {"type": "string"},
                        "file_key": {"type": "string"},
                    },
                    "required": ["bucket_name", "file_key"],
                },
            },
            {
                "name": "extract_pdf_layout_and_text",
                "description": "Extract page text and span bounding boxes from a PDF.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "doc_id": {"type": "string"},
                    },
                    "required": [],
                },
            },
            {
                "name": "query_event_vector_index",
                "description": "Semantic search for passages related to an event description.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "event_description": {"type": "string"},
                        "doc_id": {"type": "string"},
                    },
                    "required": ["event_description", "doc_id"],
                },
            },
            {
                "name": "apply_pdf_redactions",
                "description": "Burn solid black redaction rectangles into a PDF.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "redaction_targets": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "page": {"type": "integer"},
                                    "bbox": {
                                        "type": "array",
                                        "items": {"type": "number"},
                                        "minItems": 4,
                                        "maxItems": 4,
                                    },
                                    "reason": {"type": "string"},
                                    "matched_text": {"type": "string"},
                                },
                                "required": ["page", "bbox"],
                            },
                        }
                    },
                    "required": ["redaction_targets"],
                },
            },
            {
                "name": "save_redacted_document",
                "description": "Upload a redacted PDF to S3/MinIO.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "bucket_name": {"type": "string"},
                        "file_key": {"type": "string"},
                    },
                    "required": ["bucket_name", "file_key"],
                },
            },
        ]

    def call_tool(self, name: str, arguments: dict[str, Any], pdf_bytes: bytes | None = None) -> Any:
        if name == "list_s3_documents":
            return self.list_s3_documents(arguments["bucket_name"])
        if name == "fetch_document_bytes":
            return self.fetch_document_bytes(arguments["bucket_name"], arguments["file_key"])
        if name == "extract_pdf_layout_and_text":
            if pdf_bytes is None:
                raise ValueError("pdf_bytes required for extract_pdf_layout_and_text")
            return self.extract_pdf_layout_and_text(pdf_bytes, arguments.get("doc_id", "doc"))
        if name == "query_event_vector_index":
            return self.query_event_vector_index(
                arguments["event_description"],
                arguments["doc_id"],
            )
        if name == "apply_pdf_redactions":
            if pdf_bytes is None:
                raise ValueError("pdf_bytes required for apply_pdf_redactions")
            return self.apply_pdf_redactions(pdf_bytes, arguments["redaction_targets"])
        if name == "save_redacted_document":
            if pdf_bytes is None:
                raise ValueError("pdf_bytes required for save_redacted_document")
            return self.save_redacted_document(
                arguments["bucket_name"],
                arguments["file_key"],
                pdf_bytes,
            )
        raise ValueError(f"Unknown tool: {name}")
