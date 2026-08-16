"""Discovery Agent FastAPI service."""

from __future__ import annotations

import logging
from typing import Any, Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from src.discovery.agent import DiscoveryAgent
from src.services.telemetry import setup_telemetry
from src.services.settings import get_settings

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

settings = get_settings()
app = FastAPI(title="Document Discovery Agent API", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
setup_telemetry(app, service_name="discovery-agent")


class IndexRequest(BaseModel):
    documents: Optional[list[str]] = None


class SearchRequest(BaseModel):
    query: str = Field(..., min_length=1)
    top_k: int = 5
    summarize: bool = True
    reindex: bool = False


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict[str, str]:
    return {"status": "ready"}


@app.post("/index")
def index_documents(body: IndexRequest) -> dict[str, Any]:
    agent = DiscoveryAgent(settings)
    try:
        n = agent.index_raw_documents(body.documents)
        return {"indexed_chunks": n, "status": "ok"}
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.get("/search")
def search_get(
    q: str = Query(..., min_length=1),
    top_k: int = 5,
    summarize: bool = True,
) -> dict[str, Any]:
    agent = DiscoveryAgent(settings)
    result = agent.search(q, top_k=top_k, summarize=summarize)
    return agent.to_dict(result)


@app.post("/search")
def search_post(body: SearchRequest) -> dict[str, Any]:
    agent = DiscoveryAgent(settings)
    if body.reindex:
        agent.index_raw_documents()
    result = agent.search(body.query, top_k=body.top_k, summarize=body.summarize)
    return agent.to_dict(result)


def main() -> None:
    import uvicorn

    uvicorn.run("src.discovery.api:app", host="0.0.0.0", port=8001, reload=False)


if __name__ == "__main__":
    main()
