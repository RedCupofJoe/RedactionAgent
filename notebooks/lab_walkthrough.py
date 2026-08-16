"""
OpenShift AI Lab — Redaction & Discovery walkthrough
====================================================

Run this in an OpenShift AI **Workbench** (Jupyter) so you can see how the
agents talk to MinIO and catalog-deployed models.

Prerequisites
-------------
1. Lab GitOps apps synced (MinIO, redaction-agent, discovery-agent).
2. Catalog models `lab-slm` and `lab-embed` Ready in `rhoai-models`.
3. Environment variables (or edit below):

   REDACT_API_URL=https://<redaction-agent-api-route>
   DISCOVERY_API_URL=https://<discovery-agent-api-route>

In a workbench you can also call in-cluster DNS:

   http://redaction-agent.redaction-agent.svc.cluster.local:8000
   http://discovery-agent.discovery-agent.svc.cluster.local:8001
"""

# %%
import os
import json
import httpx

REDACT = os.getenv(
    "REDACT_API_URL",
    "http://redaction-agent.redaction-agent.svc.cluster.local:8000",
)
DISCOVERY = os.getenv(
    "DISCOVERY_API_URL",
    "http://discovery-agent.discovery-agent.svc.cluster.local:8001",
)
client = httpx.Client(timeout=120.0, verify=False)

print("Redaction API:", REDACT)
print("Discovery API:", DISCOVERY)

# %% [markdown]
# ## 1. Health checks

# %%
print(client.get(f"{REDACT}/healthz").json())
print(client.get(f"{DISCOVERY}/healthz").json())

# %% [markdown]
# ## 2. List documents in MinIO `raw-documents`

# %%
docs = client.get(f"{REDACT}/documents").json()
print(f"{len(docs)} document(s)")
for d in docs[:10]:
    print("-", d.get("key"), d.get("size"), "bytes")

# %% [markdown]
# ## 3. Run a small redaction job
# Pick the first PDF (if any) and redact a known synthetic entity.

# %%
pdfs = [d["key"] for d in docs if str(d.get("key", "")).lower().endswith(".pdf")]
if not pdfs:
    print("No PDFs yet — run scripts/seed_minio.sh from your laptop.")
else:
    payload = {
        "documents": [pdfs[0]],
        "person": "Jordan Hale",
        "place": "Plant B",
        "time": "July 2021",
        "events": "The chemical spill at Plant B in July 2021",
        "custom": "",
    }
    print("Submitting:", json.dumps(payload, indent=2))
    job = client.post(f"{REDACT}/redact", json=payload).json()
    print("Status:", job.get("status"), "progress:", job.get("progress"))
    for line in job.get("logs") or []:
        print(" ", line)
    print(json.dumps(job.get("results"), indent=2)[:2000])

# %% [markdown]
# ## 4. Document discovery
# Index (optional) then search with a natural-language query.

# %%
print(client.post(f"{DISCOVERY}/index", json={}).json())
found = client.post(
    f"{DISCOVERY}/search",
    json={
        "query": "chemical spill at Plant B",
        "top_k": 3,
        "summarize": True,
        "reindex": False,
    },
).json()
print(json.dumps(found, indent=2)[:3000])

# %% [markdown]
# ## 5. What to look at next
# - Streamlit UI Route `redaction-ui` (tabs for both agents)
# - OpenShift Observability / Tempo UI for traces (`redaction-agent`, `discovery-agent`)
# - Locust load test: `scripts/run_load_test.sh`
