"""FastAPI backend for the Auto Redaction Agent."""

from __future__ import annotations

import logging
import uuid
from typing import Any

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from src.agent.criteria import RedactionCriteria
from src.services.s3_client import S3Client
from src.services.settings import get_settings

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

settings = get_settings()
app = FastAPI(
    title="Auto Redaction Agent API",
    version="1.0.0",
    description="Orchestrates PDF redaction on OpenShift AI via MCP tools.",
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

_jobs: dict[str, dict[str, Any]] = {}


class RedactionRequest(BaseModel):
    documents: list[str] = Field(..., min_length=1)
    person: str = ""
    place: str = ""
    time: str = ""
    events: str = ""
    custom: str = ""


class JobStatus(BaseModel):
    job_id: str
    status: str
    progress: float
    message: str
    logs: list[str] = Field(default_factory=list)
    results: list[dict[str, Any]] = Field(default_factory=list)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict[str, str]:
    return {"status": "ready"}


@app.get("/documents")
def list_documents(bucket: str | None = None) -> list[dict[str, Any]]:
    client = S3Client(settings)
    bucket_name = bucket or settings.s3_raw_bucket
    try:
        docs = client.list_documents(bucket_name)
        return [
            {
                "key": d.key,
                "size": d.size,
                "last_modified": d.last_modified,
                "etag": d.etag,
            }
            for d in docs
        ]
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@app.post("/redact", response_model=JobStatus)
def start_redaction(request: RedactionRequest) -> JobStatus:
    job_id = str(uuid.uuid4())
    _jobs[job_id] = {
        "job_id": job_id,
        "status": "running",
        "progress": 0.0,
        "message": "Starting",
        "logs": [],
        "results": [],
    }

    criteria = RedactionCriteria.from_form(
        person=request.person,
        place=request.place,
        time=request.time,
        events=request.events,
        custom=request.custom,
    )
    from src.agent.core import RedactionAgent

    agent = RedactionAgent(settings)

    def on_progress(message: str, progress: float, extra: dict[str, Any] | None = None) -> None:
        job = _jobs[job_id]
        job["message"] = message
        job["progress"] = progress
        job["logs"].append(message)
        if extra and "status" in extra:
            job["status"] = extra["status"]

    try:
        result = agent.run(
            request.documents,
            criteria,
            job_id=job_id,
            progress=on_progress,
        )
        _jobs[job_id]["results"] = [
            {
                "source_key": r.source_key,
                "output_key": r.output_key,
                "output_uri": r.output_uri,
                "target_count": r.target_count,
                "status": r.status,
                "error": r.error,
                "log": r.log,
            }
            for r in result.results
        ]
        _jobs[job_id]["status"] = result.status
        _jobs[job_id]["progress"] = 1.0
        _jobs[job_id]["message"] = "Complete"
    except Exception as exc:  # noqa: BLE001
        logger.exception("Job %s failed", job_id)
        _jobs[job_id]["status"] = "failed"
        _jobs[job_id]["message"] = str(exc)
        _jobs[job_id]["logs"].append(f"ERROR: {exc}")

    return JobStatus(**_jobs[job_id])


@app.get("/jobs/{job_id}", response_model=JobStatus)
def get_job(job_id: str) -> JobStatus:
    job = _jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    return JobStatus(**job)


@app.get("/documents/{bucket}/{file_key:path}/bytes")
def download_document(bucket: str, file_key: str):
    from fastapi.responses import Response

    client = S3Client(settings)
    try:
        data = client.fetch_bytes(bucket, file_key)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return Response(content=data, media_type="application/pdf")


def main() -> None:
    import uvicorn

    uvicorn.run(
        "src.services.api:app",
        host="0.0.0.0",
        port=8000,
        reload=False,
    )


if __name__ == "__main__":
    main()
