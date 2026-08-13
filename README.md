# Auto Redaction Agent — Red Hat OpenShift AI (RHOAI 3.5)

Ingest public-record PDFs, identify sensitive persons / places / times / events from operator criteria, and write **permanently redacted** PDFs to MinIO — running on **OpenShift 4.20** with **Red Hat OpenShift AI 3.5** (vLLM on NVIDIA A100).

---

## Deploy on OpenShift (start here)

This is the primary path. Local development is documented later.

### Target platform

| Item | Expectation |
|------|-------------|
| Cluster | OpenShift **4.20** on AWS |
| Nodes | 6 total; **3 workers with NVIDIA A100** GPUs |
| AI platform | Red Hat OpenShift AI (**RHOAI**) **3.5** |
| GitOps | OpenShift GitOps (Argo CD) |
| GPU stack | NVIDIA GPU Operator installed and healthy |
| Storage | A default `StorageClass` suitable for RWX/RWO (e.s.g. `gp3-csi`) |

### What gets deployed

| Component | Namespace | Role |
|-----------|-----------|------|
| MinIO (+ console Route, bucket Job) | `minio` | Object store: `raw-documents`, `redacted-documents` |
| Qdrant | `qdrant` | Vector index for event semantic search |
| MCP Gateway | `mcp-gateway` | HTTP MCP tool surface for the agent |
| Granite / vLLM InferenceService | `rhoai-models` | SLM for event confirmation (A100) |
| Agent API | `redaction-agent` | FastAPI orchestration |
| Streamlit Web UI | `redaction-agent` | Operator dashboard + Routes |

GitOps entrypoint: **App-of-Apps** at `.argocd/root-application.yaml` → children under `.argocd/infrastructure/`.

---

### Step 0 — Prerequisites checklist

Log into the cluster and verify operators before applying anything:

```bash
# Identity / context
oc whoami
oc cluster-info

# OpenShift GitOps (Argo CD)
oc get pods -n openshift-gitops

# RHOAI / Open Data Hub control plane (names vary slightly by install)
oc get csv -A | grep -iE 'rhods|opendatahub|authorino|kserve' || true
oc get datasciencecluster -A

# GPU nodes + NVIDIA device plugin
oc get nodes -l nvidia.com/gpu.present=true
oc get pods -n nvidia-gpu-operator   # or nvidia-device-plugin namespace on your cluster

# StorageClass used by MinIO / Qdrant PVCs (default in manifests: gp3-csi)
oc get storageclass
```

If your StorageClass is not `gp3-csi`, update:

- `manifests/minio/pvc.yaml`
- `manifests/qdrant/pvc.yaml`

If A100 product labels differ, update `nodeSelector` in:

- `manifests/rhoai-modelservice/inferenceservice.yaml`

```bash
# Discover the exact GPU product label on your nodes
oc get nodes -o json | jq -r '
  .items[] | select(.status.allocatable["nvidia.com/gpu"] != null) |
  "\(.metadata.name)\t\(.metadata.labels["nvidia.com/gpu.product"] // "n/a")"
'
```

Install client tools on your workstation: `oc`, `podman` (or `docker`), `git`, Python **3.11+**, and optionally MinIO Client (`mc`).

---

### Step 1 — Fork / clone and set the GitOps repo URL

Argo CD Applications point at a Git remote. Replace the placeholder everywhere:

```bash
git clone <YOUR_FORK_OR_REPO_URL>
cd RedactionAgent

export GITOPS_REPO="<YOUR_FORK_OR_REPO_URL>"   # e.g. https://github.com/org/RedactionAgent.git
export GITOPS_REV="main"

# Update all Argo CD Application repoURLs
find .argocd -name '*.yaml' -print0 | xargs -0 sed -i.bak \
  "s|https://github.com/EXAMPLE/RedactionAgent.git|${GITOPS_REPO}|g"
find .argocd -name '*.yaml.bak' -delete
```

Or edit manually:

- `.argocd/root-application.yaml`
- `.argocd/infrastructure/*/application.yaml`
- `.argocd/infrastructure/agent-application.yaml`

Commit and push these URL changes **before** applying the root Application (Argo CD pulls from remote, not your laptop).

---

### Step 2 — Create projects and pull secrets (as needed)

```bash
# Application namespaces (Argo can also create them via CreateNamespace=true)
oc new-project redaction-agent
oc new-project minio
oc new-project qdrant
oc new-project mcp-gateway
oc new-project rhoai-models

# If pulling models or base images from registry.redhat.io / quay.io private repos:
oc create secret docker-registry redhat-pull-secret \
  --docker-server=registry.redhat.io \
  --docker-username='<redhat-username>' \
  --docker-password='<redhat-token>' \
  -n rhoai-models

oc secrets link default redhat-pull-secret --for=pull -n rhoai-models
```

---

### Step 3 — Configure credentials (do this before first sync in production)

Demo secrets ship with placeholder MinIO credentials. For anything beyond a lab:

```bash
# Strong MinIO root credentials
oc -n minio create secret generic minio-root \
  --from-literal=rootUser='<MINIO_USER>' \
  --from-literal=rootPassword='<MINIO_PASSWORD>' \
  --dry-run=client -o yaml | oc apply -f -

# Agent / MCP consumers of MinIO + LLM
oc -n redaction-agent create secret generic redaction-secrets \
  --from-literal=S3_ACCESS_KEY='<MINIO_USER>' \
  --from-literal=S3_SECRET_KEY='<MINIO_PASSWORD>' \
  --from-literal=LLM_API_KEY='unused' \
  --from-literal=QDRANT_API_KEY='' \
  --dry-run=client -o yaml | oc apply -f -

# Mirror the same secret into mcp-gateway if that Deployment references it
oc -n mcp-gateway create secret generic redaction-secrets \
  --from-literal=S3_ACCESS_KEY='<MINIO_USER>' \
  --from-literal=S3_SECRET_KEY='<MINIO_PASSWORD>' \
  --from-literal=LLM_API_KEY='unused' \
  --from-literal=QDRANT_API_KEY='' \
  --dry-run=client -o yaml | oc apply -f -
```

Prefer Sealed Secrets or External Secrets Operator so credentials are not committed.

---

### Step 4 — Point the SLM InferenceService at a real model

Edit `manifests/rhoai-modelservice/inferenceservice.yaml` and set `spec.predictor.model.storageUri` to a valid source for your cluster, for example:

- OCI artifact from Red Hat AI / RHEL AI registries  
- S3 / MinIO URI where model weights live  
- PVC path if you pre-staged weights  

Default placeholder in-repo:

```yaml
storageUri: "oci://registry.redhat.io/rhelai1/granite-3-2-8b-instruct-fp8-nvidia-gpu@sha256:placeholder"
```

Also confirm:

- `ServingRuntime` image tag in `manifests/rhoai-modelservice/servingruntime.yaml` matches your **RHOAI 3.5** catalog (`quay.io/modh/vllm:...`)
- `nodeSelector` / tolerations match your A100 workers
- Alternate SLM: change served model name to `meta-llama/Llama-3.1-8B-Instruct` and supply an HF token secret if required

Commit and push the model URI change.

---

### Step 5 — Build and push container images

From a machine that can reach the OpenShift internal registry (or use an external registry and retag manifests).

```bash
oc project redaction-agent

# Expose / login to the internal registry (cluster-dependent)
# Example: oc registry login

export REGISTRY="image-registry.openshift-image-registry.svc:5000"
# From outside the cluster you often need the external registry route instead, e.g.:
# export REGISTRY="default-route-openshift-image-registry.apps.<cluster-domain>"

podman build -f Dockerfile.agent \
  -t ${REGISTRY}/redaction-agent/redaction-agent:latest .

podman build -f Dockerfile.ui \
  -t ${REGISTRY}/redaction-agent/redaction-ui:latest .

podman push ${REGISTRY}/redaction-agent/redaction-agent:latest
podman push ${REGISTRY}/redaction-agent/redaction-ui:latest

# MCP gateway uses the same image, different command
oc tag redaction-agent/redaction-agent:latest redaction-agent/mcp-gateway:latest
```

If you use an external registry (Quay, ECR, etc.), update image names in:

- `k8s/overlays/openshift/kustomization.yaml`
- `manifests/agent/deployment.yaml`
- `manifests/web-ui/deployment.yaml`
- `manifests/mcp-gateway/deployment.yaml`

Then commit/push.

ImageStream alternative (build inside the cluster):

```bash
oc new-build --name=redaction-agent --binary --strategy=docker -n redaction-agent
oc start-build redaction-agent --from-dir=. --follow -n redaction-agent
# Repeat with Dockerfile.ui / Dockerfile.agent as needed, or use BuildConfigs committed later
```

---

### Step 6 — Apply the Argo CD root Application

```bash
oc apply -f .argocd/root-application.yaml
```

Watch sync:

```bash
oc get applications -n openshift-gitops
oc get applications -n openshift-gitops -o wide

# Optional: Argo CD CLI
argocd app list
argocd app get auto-redaction-root
```

Child apps that should become Healthy/Synced:

- `minio`
- `qdrant`
- `mcp-gateway`
- `rhoai-modelservice`
- `redaction-agent`
- `redaction-web-ui`

MinIO PostSync Job `minio-create-buckets` creates `raw-documents` and `redacted-documents`.

Manual Kustomize apply (if you are not using Argo CD yet):

```bash
oc apply -k k8s/overlays/openshift
```

Prefer GitOps for day-2 drift control.

---

### Step 7 — Verify infrastructure and model serving

```bash
# MinIO
oc get pods,svc,route,pvc -n minio
oc logs -n minio job/minio-create-buckets

# Qdrant
oc get pods,svc,pvc -n qdrant
oc exec -n qdrant deploy/qdrant -- wget -qO- http://127.0.0.1:6333/readyz

# MCP gateway
oc get pods,svc -n mcp-gateway
oc -n mcp-gateway port-forward svc/mcp-gateway 8080:8080
# curl http://127.0.0.1:8080/healthz
# curl http://127.0.0.1:8080/tools

# RHOAI model
oc get servingruntime,inferenceservice -n rhoai-models
oc get pods -n rhoai-models -l serving.kserve.io/inferenceservice=granite
oc logs -n rhoai-models -l serving.kserve.io/inferenceservice=granite --tail=100

# Agent + UI
oc get pods,svc,route -n redaction-agent
oc -n redaction-agent get route redaction-ui -o jsonpath='{.spec.host}{"\n"}'
oc -n redaction-agent get route redaction-agent-api -o jsonpath='{.spec.host}{"\n"}'
```

Smoke-test the OpenAI-compatible SLM endpoint (RawDeployment Service name may be `granite-predictor`):

```bash
oc -n rhoai-models port-forward svc/granite-predictor 8080:80

curl -s http://127.0.0.1:8080/v1/models | jq .
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "ibm-granite/granite-3.2-8b-instruct",
    "messages": [{"role":"user","content":"Reply with OK"}],
    "max_tokens": 16
  }' | jq .
```

Confirm ConfigMaps point `LLM_BASE_URL` at that in-cluster Service:

- `manifests/agent/configmap.yaml`
- `manifests/mcp-gateway/configmap.yaml`

Default:

```text
http://granite-predictor.rhoai-models.svc.cluster.local:80/v1
```

---

### Step 8 — Seed sample public-record PDFs

From a workstation that can reach the MinIO API Route (or run inside the cluster):

```bash
export S3_ENDPOINT_URL="https://$(oc -n minio get route minio-api -o jsonpath='{.spec.host}')"
export S3_ACCESS_KEY='<MINIO_USER>'
export S3_SECRET_KEY='<MINIO_PASSWORD>'
export S3_RAW_BUCKET=raw-documents
export S3_REDACTED_BUCKET=redacted-documents
export S3_SECURE=true

python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python scripts/seed_dataset.py --synthetic-only
```

Or with `mc`:

```bash
mc alias set rhoai "$S3_ENDPOINT_URL" "$S3_ACCESS_KEY" "$S3_SECRET_KEY"
mc ls rhoai/raw-documents
```

---

### Step 9 — Open the UI and run a redaction job

```bash
echo "https://$(oc -n redaction-agent get route redaction-ui -o jsonpath='{.spec.host}')"
```

In the UI:

1. Refresh documents and multi-select PDFs (or **Select all**).
2. Enter criteria, for example:
   - **Person:** `Jordan Hale`
   - **Place:** `Plant B`, `Oak Ridge`
   - **Time:** `July 2021`
   - **Events:** `The chemical spill at Plant B in July 2021`
3. Click **Run redaction**.
4. Download / preview the output from `redacted-documents`.

API-only check:

```bash
API="https://$(oc -n redaction-agent get route redaction-agent-api -o jsonpath='{.spec.host}')"
curl -sk "$API/healthz"
curl -sk "$API/documents" | jq .
curl -sk -X POST "$API/redact" -H 'Content-Type: application/json' -d '{
  "documents": ["foia/plant-b-incident-memo.pdf"],
  "person": "Jordan Hale",
  "place": "Plant B",
  "time": "July 2021",
  "events": "The chemical spill at Plant B in July 2021",
  "custom": ""
}' | jq .
```

---

### Step 10 — Day-2 operations

**Roll a new agent/UI image**

```bash
podman build -f Dockerfile.agent -t ${REGISTRY}/redaction-agent/redaction-agent:<tag> .
podman push ${REGISTRY}/redaction-agent/redaction-agent:<tag>
oc -n redaction-agent set image deploy/redaction-agent api=.../redaction-agent:<tag>
# or bump newTag in Git and let Argo sync
```

**Scale the model**

Edit `minReplicas` / `maxReplicas` on the InferenceService and sync.

**Rotate MinIO credentials**

Update Secrets in `minio`, `redaction-agent`, and `mcp-gateway`, then restart Deployments.

**Tear down (lab)**

```bash
oc delete -f .argocd/root-application.yaml
oc delete applications -n openshift-gitops -l app.kubernetes.io/part-of=auto-redaction-agent
oc delete project redaction-agent minio qdrant mcp-gateway rhoai-models
```

---

### OpenShift troubleshooting

| Symptom | What to check |
|---------|----------------|
| Argo app `Unknown` / `ComparisonError` | `repoURL` reachable by Argo; path exists on `targetRevision` |
| MinIO PVC Pending | StorageClass name; AWS volume limits |
| Bucket Job failed | MinIO Service DNS `minio.minio.svc.cluster.local:9000`; root Secret keys |
| InferenceService not Ready | GPU Operator; nodeSelector; `storageUri`; pull secret; vLLM logs |
| Agent redaction fails on Events | Qdrant Ready; embedding model download; `LLM_BASE_URL` |
| UI empty document list | Agent Route / ConfigMap `AGENT_API_URL`; MinIO credentials; seed script |
| Route timeouts on large PDFs | Annotation `haproxy.router.openshift.io/timeout` (overlay sets `300s`) |

---

## Architecture

```text
┌─────────────┐     ┌──────────────┐     ┌────────────────────┐
│ Streamlit   │────▶│ Agent API    │────▶│ MCP Gateway tools  │
│ Web UI      │     │ (FastAPI)    │     │ list/fetch/extract │
└─────────────┘     └──────┬───────┘     │ query/apply/save   │
                           │             └─────────┬──────────┘
           ┌───────────────┼───────────────┬───────┘
           ▼               ▼               ▼
     ┌──────────┐   ┌────────────┐   ┌─────────────┐
     │ MinIO    │   │ Qdrant     │   │ RHOAI vLLM  │
     │ raw /    │   │ event      │   │ Granite 3.2 │
     │ redacted │   │ embeddings │   │ 8B Instruct │
     └──────────┘   └────────────┘   └─────────────┘
```

**Runtime flow**

1. Seed FOIA-style / synthetic PDFs into MinIO `raw-documents`.
2. Operator selects files and enters Person / Place / Time / Events / Custom criteria.
3. Agent extracts layout-aware text (PyMuPDF), matches literals/regex; for **Events**, chunks are embedded into Qdrant, retrieved semantically, confirmed by the SLM, then mapped to bounding boxes.
4. Redactions are burned in with solid black rectangles and uploaded to `redacted-documents`.

---

## Repository layout

```text
.argocd/                 # Argo CD App-of-Apps + child Applications
k8s/                     # Kustomize base + OpenShift overlay
manifests/               # Workload manifests (MinIO, Qdrant, MCP, RHOAI, agent, UI)
src/agent/               # Orchestration, MCP tools, event processor
src/services/            # S3, PDF redactor, vector store, FastAPI
src/ui/                  # Streamlit dashboard
scripts/                 # MinIO bucket setup + dataset seed
tests/                   # Unit + integration tests
Dockerfile.agent         # API / MCP / agent image
Dockerfile.ui            # Streamlit image
docker-compose.yml       # Optional local stack
```

---

## Configuration reference

| Variable | Purpose | Typical OpenShift value |
|----------|---------|-------------------------|
| `S3_ENDPOINT_URL` | MinIO API | `http://minio.minio.svc.cluster.local:9000` |
| `S3_RAW_BUCKET` | Source PDFs | `raw-documents` |
| `S3_REDACTED_BUCKET` | Outputs | `redacted-documents` |
| `QDRANT_URL` | Vector DB | `http://qdrant.qdrant.svc.cluster.local:6333` |
| `LLM_BASE_URL` | RHOAI vLLM OpenAI API | `http://granite-predictor.rhoai-models.svc.cluster.local:80/v1` |
| `LLM_MODEL` | Served model name | `ibm-granite/granite-3.2-8b-instruct` |
| `EMBEDDING_MODEL` | Chunk embeddings | `BAAI/bge-small-en-v1.5` |
| `AGENT_API_URL` | UI → API | `http://redaction-agent.redaction-agent.svc.cluster.local:8000` |

See `.env.example` and `configs/settings.yaml`. Cluster values live in ConfigMaps/Secrets under `manifests/`.

---

## MCP tools

| Tool | Purpose |
|------|---------|
| `list_s3_documents` | List bucket objects |
| `fetch_document_bytes` | Download PDF bytes |
| `extract_pdf_layout_and_text` | Page text + span bboxes |
| `query_event_vector_index` | Semantic event search in Qdrant |
| `apply_pdf_redactions` | PyMuPDF burn-in black rectangles |
| `save_redacted_document` | Upload to `redacted-documents` |

HTTP gateway: `GET /tools`, `POST /tools/call` on the `mcp-gateway` Service (`:8080`).

---

## UI capabilities

- Multi-select document table with **Select all**
- Form fields: Person, Place, Time, Events, Custom (`re:` prefix for regex lines)
- Progress bar, logs, per-document results
- Side-by-side first-page preview + downloads

---

## Local development (optional)

Use this only for laptop iteration. Production path is the OpenShift section above.

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env

# Infrastructure
docker compose up -d minio qdrant
bash scripts/setup_minio_buckets.sh
python scripts/seed_dataset.py --synthetic-only

# Processes
make api    # :8000
make ui     # :8501
make mcp    # :8080
```

Point `LLM_BASE_URL` at a reachable OpenAI-compatible endpoint (cluster Route via VPN, or local vLLM). If the LLM is unreachable, event confirmation falls back to a lexical heuristic so demos still run.

```bash
make test
```

---

## Security notes

- In-repo MinIO credentials are **lab placeholders** — replace before any shared or production cluster.
- Redaction is destructive (content removed from the PDF content stream). Validate on sample FOIA packets before production use.
- Protect UI/API Routes with OpenShift OAuth / network policies as required by your ATO.
- Do not commit real pull secrets, HF tokens, or cloud keys.

---

## License

Apache-2.0
