"""Agent orchestration: criteria → MCP tools → redacted PDF output."""

from __future__ import annotations

import logging
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional

from src.agent.criteria import RedactionCriteria
from src.agent.mcp_tools import RedactionMCPTools
from src.services.settings import Settings, get_settings

logger = logging.getLogger(__name__)

ProgressCallback = Callable[[str, float, Optional[dict[str, Any]]], None]


@dataclass
class DocumentResult:
    source_key: str
    output_key: Optional[str]
    output_uri: Optional[str]
    target_count: int
    status: str
    error: Optional[str] = None
    log: list = field(default_factory=list)


@dataclass
class JobResult:
    job_id: str
    results: list
    status: str


class RedactionAgent:
    """Coordinates ingestion, entity/event matching, and PDF burn-in redaction."""

    def __init__(self, settings: Optional[Settings] = None) -> None:
        self.settings = settings or get_settings()
        self.tools = RedactionMCPTools(self.settings)
        self.event_processor = self.tools.event_processor

    def run(
        self,
        document_keys: list,
        criteria: RedactionCriteria,
        *,
        job_id: str = "job",
        progress: Optional[ProgressCallback] = None,
    ) -> JobResult:
        results: list = []
        total = max(1, len(document_keys))

        for index, key in enumerate(document_keys):
            doc_logs: list = []
            base_progress = index / total

            def emit(message: str, local: float = 0.0, extra: Optional[dict] = None) -> None:
                doc_logs.append(message)
                logger.info("[%s] %s", key, message)
                if progress:
                    progress(message, min(0.99, base_progress + local / total), extra)

            try:
                emit("Fetching document from raw-documents", 0.05)
                pdf_bytes = self.tools.fetch_document_bytes(
                    self.settings.s3_raw_bucket,
                    key,
                )
                doc_id = Path(key).stem
                targets: list = []

                literals = [*criteria.persons, *criteria.places, *criteria.times]
                if literals:
                    emit("Searching {} literal entities".format(len(literals)), 0.2)
                    targets.extend(
                        self.tools.redactor.find_text_bboxes(pdf_bytes, literals, use_regex=False)
                    )

                if criteria.custom:
                    emit("Applying custom / regex rules", 0.35)
                    for line in criteria.custom.splitlines():
                        line = line.strip()
                        if not line:
                            continue
                        if line.lower().startswith("re:"):
                            pattern = line[3:].strip()
                            targets.extend(
                                self.tools.redactor.find_text_bboxes(
                                    pdf_bytes, [pattern], use_regex=True
                                )
                            )
                        else:
                            targets.extend(
                                self.tools.redactor.find_text_bboxes(
                                    pdf_bytes, [line], use_regex=False
                                )
                            )

                if criteria.events:
                    emit("Indexing document chunks into Qdrant", 0.5)
                    self.event_processor.index_document(doc_id, pdf_bytes)
                    emit("Semantic event search + SLM confirmation", 0.65)
                    event_targets = self.event_processor.find_event_targets(
                        criteria.events,
                        doc_id,
                        pdf_bytes,
                    )
                    emit(
                        "Event pipeline produced {} targets".format(len(event_targets)),
                        0.75,
                    )
                    targets.extend(event_targets)

                targets = self.tools.redactor._dedupe_targets(targets)
                emit("Applying {} redactions with PyMuPDF".format(len(targets)), 0.85)
                redacted = self.tools.apply_pdf_redactions(
                    pdf_bytes,
                    [asdict(t) for t in targets],
                )

                out_key = "redacted-{}".format(Path(key).name)
                emit(
                    "Uploading to {}/{}".format(self.settings.s3_redacted_bucket, out_key),
                    0.95,
                )
                uri = self.tools.save_redacted_document(
                    self.settings.s3_redacted_bucket,
                    out_key,
                    redacted,
                )
                results.append(
                    DocumentResult(
                        source_key=key,
                        output_key=out_key,
                        output_uri=uri,
                        target_count=len(targets),
                        status="succeeded",
                        log=doc_logs,
                    )
                )
            except Exception as exc:  # noqa: BLE001
                logger.exception("Failed redacting %s", key)
                results.append(
                    DocumentResult(
                        source_key=key,
                        output_key=None,
                        output_uri=None,
                        target_count=0,
                        status="failed",
                        error=str(exc),
                        log=doc_logs + ["ERROR: {}".format(exc)],
                    )
                )

        status = "succeeded"
        if any(r.status == "failed" for r in results):
            status = "partial" if any(r.status == "succeeded" for r in results) else "failed"
        if progress:
            progress("Job complete", 1.0, {"status": status})
        return JobResult(job_id=job_id, results=results, status=status)


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    settings = get_settings()
    agent = RedactionAgent(settings)
    keys = [d.key for d in agent.tools.s3.list_documents(settings.s3_raw_bucket)]
    print("Found {} documents in {}".format(len(keys), settings.s3_raw_bucket))
    for k in keys[:20]:
        print(" - {}".format(k))


if __name__ == "__main__":
    main()
