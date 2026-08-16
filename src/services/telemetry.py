"""OpenTelemetry setup for FastAPI agents (exports to cluster OTLP collector)."""

from __future__ import annotations

import logging
import os
from typing import Any

logger = logging.getLogger(__name__)


def setup_telemetry(app: Any, *, service_name: str) -> None:
    """Instrument FastAPI if OpenTelemetry packages and endpoint are available."""
    endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "").strip()
    if not endpoint:
        logger.info("OTEL_EXPORTER_OTLP_ENDPOINT not set; telemetry disabled for %s", service_name)
        return
    try:
        from opentelemetry import trace
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
        from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
        from opentelemetry.sdk.resources import Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor

        resource = Resource.create(
            {
                "service.name": os.getenv("OTEL_SERVICE_NAME", service_name),
                "service.namespace": os.getenv("OTEL_SERVICE_NAMESPACE", "lab"),
            }
        )
        provider = TracerProvider(resource=resource)
        exporter = OTLPSpanExporter(endpoint=endpoint.rstrip("/") + "/v1/traces")
        provider.add_span_processor(BatchSpanProcessor(exporter))
        trace.set_tracer_provider(provider)
        FastAPIInstrumentor.instrument_app(app)
        logger.info("OpenTelemetry enabled for %s → %s", service_name, endpoint)
    except Exception as exc:  # noqa: BLE001
        logger.warning("Failed to enable OpenTelemetry for %s: %s", service_name, exc)


def start_span(name: str):
    """Context manager helper; no-op if OTel not configured."""
    try:
        from opentelemetry import trace

        return trace.get_tracer("redaction-lab").start_as_current_span(name)
    except Exception:  # noqa: BLE001
        from contextlib import nullcontext

        return nullcontext()
