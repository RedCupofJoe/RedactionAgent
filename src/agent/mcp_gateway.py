"""Lightweight MCP Gateway HTTP server exposing redaction tools."""

from __future__ import annotations

import base64
import logging
from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from src.agent.mcp_tools import RedactionMCPTools
from src.services.settings import get_settings

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

settings = get_settings()
tools = RedactionMCPTools(settings)

app = FastAPI(
    title="Redaction MCP Gateway",
    version="1.0.0",
    description="HTTP MCP-compatible gateway for Auto Redaction Agent tools.",
)


class ToolCallRequest(BaseModel):
    name: str
    arguments: dict[str, Any] = Field(default_factory=dict)
    pdf_b64: str | None = None


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/tools")
def list_tools() -> list[dict[str, Any]]:
    return tools.tool_specs()


@app.post("/tools/call")
def call_tool(request: ToolCallRequest) -> dict[str, Any]:
    pdf_bytes = base64.b64decode(request.pdf_b64) if request.pdf_b64 else None
    try:
        result = tools.call_tool(request.name, request.arguments, pdf_bytes=pdf_bytes)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        logger.exception("Tool call failed: %s", request.name)
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    if isinstance(result, (bytes, bytearray)):
        return {
            "content_type": "application/pdf",
            "encoding": "base64",
            "data": base64.b64encode(result).decode("ascii"),
        }
    return {"result": result}


def main() -> None:
    import uvicorn

    uvicorn.run(
        "src.agent.mcp_gateway:app",
        host=settings.mcp_server_host,
        port=settings.mcp_server_port,
        reload=False,
    )


if __name__ == "__main__":
    main()
