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
| MinIO (+ console Route, bucket Job) | `minio` | Object store: `raw-documents`, `redacted-documents`, `vector-index` |
| MCP Gateway | `mcp-gateway` | HTTP MCP tool surface for the agent |
| Catalog SLM + embedding models | `rhoai-models` | Deployed from OpenShift AI **default model catalog** |
| Agent API | `redaction-agent` | FastAPI orchestration |
| Streamlit Web UI | `redaction-agent` | Operator dashboard + Routes |

**Platform-first:** chat and embedding models come from the OpenShift AI catalog; event vectors live in MinIO. The only intentional non-platform infra in this lab is **MinIO** (plus synthetic seed data). No Qdrant, no Hugging Face runtime downloads, no custom OCI model URIs.

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
oc get csv -A | grep -iE 'rhods|opendatahub|authorino|kserve|modelregistry' || true
oc get datasciencecluster -A

# GPU nodes + NVIDIA device plugin
oc get nodes -l nvidia.com/gpu.present=true
oc get pods -n nvidia-gpu-operator   # or nvidia-device-plugin namespace on your cluster

# StorageClass used by MinIO PVCs (default in manifests: gp3-csi)
oc get storageclass
```

If your StorageClass is not `gp3-csi`, update `manifests/minio/pvc.yaml`.

GPU hardware profiles for catalog deploys are selected in the OpenShift AI **Deploy model** wizard (match your A100 workers).

```bash
# Discover the exact GPU product label on your nodes (for hardware profiles)
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

### Step 3 — Configure credentials (local secrets, not in Git)

Demo plaintext Secrets are **not** committed. Generate them on your machine (output is gitignored under `secrets/local/`):

```bash
chmod +x scripts/generate_local_secrets.sh

# Interactive (prompts for user/password; blank password = auto-generate)
./scripts/generate_local_secrets.sh

# Or non-interactive
export MINIO_ROOT_USER=labuser
export MINIO_ROOT_PASSWORD='your-strong-password'
./scripts/generate_local_secrets.sh --from-env --apply
```

Apply without regenerating:

```bash
oc apply -f secrets/local/
```

Creates:

- `minio/minio-root`
- `redaction-agent/redaction-secrets`
- `mcp-gateway/redaction-secrets`

See [secrets/README.md](secrets/README.md). For production, prefer Sealed Secrets or External Secrets instead of long-lived local YAML.

---
### Step 4 — Deploy SLM + embeddings from the OpenShift AI model catalog

Do **not** bring in custom / special model URIs or in-pod Hugging Face downloads. Use the **default model catalog** built into OpenShift AI.

Prerequisites:

- OpenShift AI dashboard (`dashboard: Managed`)
- **KServe** Managed (RawDeployment)
- **Model registry** enabled (required for Catalog in RHOAI 3.5)
- GPU hardware profiles for your A100s

#### Deploy from the catalog (UI)

1. Open the **OpenShift AI** dashboard.
2. Go to **AI hub → Models → Catalog**.
3. Deploy **two** models into project `rhoai-models` (create it first if needed):
   - A **generative / instruct** model → chat / event confirmation (`LLM_*`)
   - An **embedding** model → semantic event search (`EMBEDDING_*`)
4. For each: **Deploy model** → project `rhoai-models` → short deployment name (e.g. `lab-slm`, `lab-embed`) → GPU hardware profile → Deploy.
5. Wait until both InferenceServices are Ready.

Official reference: [Working with the model catalog](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_the_model_catalog/).

#### Point the agent at the catalog deployments

```bash
oc get inferenceservice,svc -n rhoai-models
```

Update ConfigMaps (then sync / restart pods):

- [`manifests/agent/configmap.yaml`](manifests/agent/configmap.yaml)
- [`manifests/mcp-gateway/configmap.yaml`](manifests/mcp-gateway/configmap.yaml)

```text
LLM_BASE_URL=http://lab-slm-predictor.rhoai-models.svc.cluster.local:80/v1
LLM_MODEL=<id from GET /v1/models on the SLM>
EMBEDDING_BASE_URL=http://lab-embed-predictor.rhoai-models.svc.cluster.local:80/v1
EMBEDDING_MODEL=<id from GET /v1/models on the embedder>
```

Event chunk vectors are written to MinIO bucket **`vector-index`** (created by the MinIO bucket Job). There is **no** external vector database in this lab.

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
- `mcp-gateway`
- `rhoai-modelservice`
- `redaction-agent`
- `redaction-web-ui`

MinIO PostSync Job `minio-create-buckets` creates `raw-documents`, `redacted-documents`, and `vector-index`.

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

# MCP gateway
oc get pods,svc -n mcp-gateway
oc -n mcp-gateway port-forward svc/mcp-gateway 8080:8080
# curl http://127.0.0.1:8080/healthz
# curl http://127.0.0.1:8080/tools

# RHOAI model (deployed from the default OpenShift AI catalog — see Step 4)
oc get inferenceservice,svc -n rhoai-models
ISVC=$(oc get inferenceservice -n rhoai-models -o jsonpath='{.items[0].metadata.name}')
oc get pods -n rhoai-models -l serving.kserve.io/inferenceservice=${ISVC}
oc logs -n rhoai-models -l serving.kserve.io/inferenceservice=${ISVC} --tail=100

# Agent + UI
oc get pods,svc,route -n redaction-agent
oc -n redaction-agent get route redaction-ui -o jsonpath='{.spec.host}{"\n"}'
oc -n redaction-agent get route redaction-agent-api -o jsonpath='{.spec.host}{"\n"}'
```

Smoke-test the OpenAI-compatible endpoint created by the catalog deploy:

```bash
ISVC=$(oc get inferenceservice -n rhoai-models -o jsonpath='{.items[0].metadata.name}')
oc -n rhoai-models port-forward svc/${ISVC}-predictor 8080:80

# other terminal:
curl -s http://127.0.0.1:8080/v1/models | jq .
MODEL=$(curl -s http://127.0.0.1:8080/v1/models | jq -r '.data[0].id')
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK\"}],\"max_tokens\":16}" | jq .
```

Confirm ConfigMaps point `LLM_BASE_URL` / `LLM_MODEL` at that catalog deployment:

- `manifests/agent/configmap.yaml`
- `manifests/mcp-gateway/configmap.yaml`

Example (deployment name `lab-slm`):

```text
http://lab-slm-predictor.rhoai-models.svc.cluster.local:80/v1
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
python scripts/seed_dataset.py
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

Adjust replicas in the OpenShift AI dashboard for the catalog deployment (or `oc edit inferenceservice -n rhoai-models`).

**Rotate MinIO credentials**

Update Secrets in `minio`, `redaction-agent`, and `mcp-gateway`, then restart Deployments.

**Tear down (lab)**

```bash
oc delete -f .argocd/root-application.yaml
oc delete applications -n openshift-gitops -l app.kubernetes.io/part-of=auto-redaction-agent
oc delete project redaction-agent minio mcp-gateway rhoai-models
```

---

### OpenShift troubleshooting

| Symptom | What to check |
|---------|----------------|
| Argo app `Unknown` / `ComparisonError` | `repoURL` reachable by Argo; path exists on `targetRevision` |
| MinIO PVC Pending | StorageClass name; AWS volume limits |
| Bucket Job failed | MinIO Service DNS `minio.minio.svc.cluster.local:9000`; root Secret keys |
| InferenceService not Ready | GPU Operator / hardware profile; catalog deploy status; cluster pull secret; vLLM logs |
| Agent redaction fails on Events | Catalog embedder Ready; MinIO `vector-index` bucket; `EMBEDDING_*` / `LLM_*` match catalog deploys |
| UI empty document list | Agent Route / ConfigMap `AGENT_API_URL`; MinIO credentials; seed script |
| Route timeouts on large PDFs | Annotation `haproxy.router.openshift.io/timeout` (overlay sets `300s`) |

---

### Same cluster: document discovery agent

Multiple namespaces for this stack **do not block** a second agent. Impact comes from **shared GPUs**, **Argo Application names**, and **whether discovery reuses or duplicates** MinIO / catalog models.

**Recommended pattern:** treat MinIO and the OpenShift AI **catalog-deployed** SLM + embedding models as **shared platform**. Deploy discovery in its **own app namespace** (for example `discovery-agent`). Do **not** stand up a second always-on MinIO or GPU model unless you have proven spare capacity.

| Shared resource | Redaction reserves | What discovery should do |
|-----------------|--------------------|--------------------------|
| App namespace | `redaction-agent`, `mcp-gateway` | Use a different namespace (e.g. `discovery-agent`) |
| MinIO (`minio`) | Buckets `raw-documents`, `redacted-documents`, `vector-index` | Reuse the same MinIO; create **separate** buckets / collection prefixes |
| Catalog SLM + embedder (`rhoai-models`) | GPU InferenceServices from the default catalog | Call the same OpenAI-compatible endpoints; only deploy another catalog model if a free A100 remains |
| Argo CD apps in `openshift-gitops` | `minio`, `mcp-gateway`, `rhoai-modelservice`, `redaction-agent`, `redaction-web-ui`, `auto-redaction-root` | Name discovery apps `discovery-*` only — **never** reuse `minio` / `rhoai-modelservice` |

Reserved names (do not overwrite for other agents):

- MinIO buckets: `raw-documents`, `redacted-documents`, `vector-index`
- Vector collection prefix: `redaction-events`

Discovery config can point at the same in-cluster endpoints redaction already uses:

```text
S3_ENDPOINT_URL=http://minio.minio.svc.cluster.local:9000
LLM_BASE_URL=http://<catalog-slm>-predictor.rhoai-models.svc.cluster.local:80/v1
EMBEDDING_BASE_URL=http://<catalog-embed>-predictor.rhoai-models.svc.cluster.local:80/v1
```

The `redaction-agent` namespace includes a CPU/memory `ResourceQuota` so the app tier is less likely to starve other agents’ pods. GPU capacity is **not** quota’d here — budget A100s explicitly when adding a second model.

---

## Architecture

```text
┌─────────────┐     ┌──────────────┐     ┌────────────────────┐
│ Streamlit   │────▶│ Agent API    │────▶│ MCP Gateway tools  │
│ Web UI      │     │ (FastAPI)    │     │ list/fetch/extract │
└─────────────┘     └──────┬───────┘     │ query/apply/save   │
                           │             └─────────┬──────────┘
           ┌───────────────┼───────────────────────┘
           ▼               ▼
     ┌──────────┐   ┌─────────────────────┐
     │ MinIO    │   │ OpenShift AI catalog│
     │ raw /    │   │ SLM + embeddings    │
     │ redacted │   │ (default catalog)   │
     │ vectors  │   └─────────────────────┘
     └──────────┘
```

**Runtime flow**

1. Seed synthetic FOIA-style PDFs into MinIO `raw-documents`.
2. Operator selects files and enters Person / Place / Time / Events / Custom criteria.
3. Agent extracts layout-aware text (PyMuPDF), matches literals/regex; for **Events**, chunks are embedded via the **catalog embedding** service, stored under MinIO `vector-index`, retrieved by cosine similarity, confirmed by the **catalog SLM**, then mapped to bounding boxes.
4. Redactions are burned in with solid black rectangles and uploaded to `redacted-documents`.

---

## Repository layout

```text
.argocd/                 # Argo CD App-of-Apps + child Applications
k8s/                     # Kustomize base + OpenShift overlay
manifests/               # Workload manifests (MinIO, MCP, RHOAI notes, agent, UI)
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
| `S3_RAW_BUCKET` | Source PDFs (**reserved**) | `raw-documents` |
| `S3_REDACTED_BUCKET` | Outputs (**reserved**) | `redacted-documents` |
| `S3_VECTOR_BUCKET` | Event vectors (**reserved**) | `vector-index` |
| `VECTOR_COLLECTION` | Prefix in vector bucket (**reserved**) | `redaction-events` |
| `LLM_BASE_URL` | Catalog SLM OpenAI API | `http://lab-slm-predictor.rhoai-models.svc.cluster.local:80/v1` |
| `LLM_MODEL` | Served model id from catalog | From `GET /v1/models` after Step 4 |
| `EMBEDDING_BASE_URL` | Catalog embedder OpenAI API | `http://lab-embed-predictor.rhoai-models.svc.cluster.local:80/v1` |
| `EMBEDDING_MODEL` | Embedding model id from catalog | From `GET /v1/models` after Step 4 |
| `AGENT_API_URL` | UI → API | `http://redaction-agent.redaction-agent.svc.cluster.local:8000` |

**Reserved for this agent** (other agents on the same cluster should pick different bucket/collection names): `raw-documents`, `redacted-documents`, `vector-index`, `redaction-events`.

See `.env.example` and `configs/settings.yaml`. Cluster values live in ConfigMaps/Secrets under `manifests/`.

---

## MCP tools

| Tool | Purpose |
|------|---------|
| `list_s3_documents` | List bucket objects |
| `fetch_document_bytes` | Download PDF bytes |
| `extract_pdf_layout_and_text` | Page text + span bboxes |
| `query_event_vector_index` | Semantic event search (catalog embeddings + MinIO index) |
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

# Infrastructure (MinIO only — models come from the cluster catalog or local:// fallback)
docker compose up -d minio
bash scripts/setup_minio_buckets.sh
python scripts/seed_dataset.py

# Processes
make api    # :8000
make ui     # :8501
make mcp    # :8080
```

Point `LLM_BASE_URL` / `EMBEDDING_BASE_URL` at catalog InferenceServices (or use `EMBEDDING_BASE_URL=local://` for offline lexical fallback). If the chat LLM is unreachable, event confirmation falls back to a lexical heuristic so demos still run.

```bash
make test
```

---

## Security notes

- MinIO / agent credentials are generated into `secrets/local/` (gitignored) via `scripts/generate_local_secrets.sh` — never commit that directory.
- Redaction is destructive (content removed from the PDF content stream). Validate on sample FOIA packets before production use.
- Protect UI/API Routes with OpenShift OAuth / network policies as required by your ATO.
- Do not commit real pull secrets, HF tokens, or cloud keys.

---

## License

Apache-2.0
