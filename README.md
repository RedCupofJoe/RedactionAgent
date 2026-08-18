# Auto Redaction + Document Discovery Lab (OpenShift AI)

End-to-end lab: redact sensitive content from public-record PDFs **and** discover related passages — on **OpenShift** with **OpenShift AI**, **GitOps**, **NVIDIA L40S (g6e.4xlarge)**, and **OpenShift Observability**.

This guide assumes you are **not** an OpenShift expert. Follow the steps in order.

---

## What you will deploy

| Namespace | Component |
|-----------|-----------|
| `minio` | MinIO (S3) + buckets + lab user |
| `rhoai-models` | Catalog SLM + embedding models (you deploy from UI) |
| `redaction-agent` | Redaction API + Streamlit UI (two tabs) |
| `discovery-agent` | Document Discovery API |
| `mcp-gateway` | MCP tool gateway |
| `lab-observability` | OpenTelemetry Collector (needs Observability Operator first) |

**Platform-first:** models come from the OpenShift AI **default model catalog**. Event vectors live in MinIO. Outside pieces allowed: **MinIO** and a **Hugging Face dataset** downloaded to local `scratch/`.

**Hardware target:** 3× **g6e.4xlarge** (1× NVIDIA **L40S** ~48GB each). Deploy catalog models that fit one GPU (1 GPU for chat, 1 for embeddings, 1 spare).

---

## Step 0 — Install operators yourself (before this repo)

Do **not** skip this. The lab scripts **check** these; they do **not** install them.

### 0.1 Required on every cluster

Install these **before** running lab scripts (order matters for GPUs):

1. **Red Hat OpenShift AI** (RHOAI) — DataScienceCluster with KServe + Dashboard + Model Registry  
2. **OpenShift GitOps** (Argo CD) — Operator **and** a healthy `openshift-gitops` Argo CD instance  
3. **Node Feature Discovery (NFD)** Operator **and** a `NodeFeatureDiscovery` instance  
   - Required so the NVIDIA GPU Operator can see GPU nodes (`feature.node.kubernetes.io/pci-10de.present`)  
   - Without NFD, `ClusterPolicy` often stays stuck with **`No NFD labels found`** and `nvidia.com/gpu` never appears  
   - OperatorHub → **Node Feature Discovery** → Install → create **NodeFeatureDiscovery** (defaults OK)  
4. **NVIDIA GPU Operator** — create `ClusterPolicy` after NFD is labeling nodes; wait until workers show allocatable `nvidia.com/gpu`  
5. **OpenShift Observability Operator** (+ Tempo / OpenTelemetry as required by your version)  
   - Install this **before** syncing the `lab-observability` Argo app  
   - Console → Operators → OperatorHub → search “Observability” / “Tempo” / “OpenTelemetry”

### 0.2 Also required for non-cloud / bare-metal style clusters

Pass `--non-cloud` to the checker later:

6. **Storage** Operator / CSI with a default StorageClass  

On AWS/ROSA managed storage these are often already present; the checker only **fails** Storage when `--non-cloud` is set and no StorageClass exists.

### 0.3 Workstation tools

- `oc` (logged in with enough rights to create namespaces / Applications)  
- `git`, Python **3.11+**, `openssl`  
- Optional: `podman`/`docker` to build images  

---

## Step 1 — Clone the repo locally

```bash
git clone <YOUR_REPO_URL>
cd RedactionAgent
```

You should already have the repo locally if you followed earlier lab steps (through secrets). Continue from here.

---

## Step 2 — Verify prerequisites

```bash
chmod +x scripts/*.sh
./scripts/check_prerequisites.sh
# Non-cloud:
# ./scripts/check_prerequisites.sh --non-cloud
```

**Expected:** `Prerequisites OK`  
**If FAIL on NFD:** install Node Feature Discovery, create a NodeFeatureDiscovery instance, wait for `pci-10de` labels on GPU nodes, then re-check GPU Operator / `ClusterPolicy`.  
**If FAIL on Observability:** install the Observability Operator, wait until CSVs/pods are healthy, re-run the checker.  
**Do not** run `deploy_lab.sh` until this passes.

---

## Step 3 — Point GitOps at your Git remote

Argo CD pulls from Git (not your laptop).

```bash
./scripts/configure_gitops_repo.sh https://github.com/<org>/<repo>.git main
git add .argocd
git commit -m "Configure Argo repoURL for lab"
git push
```

---

## Step 4 — MinIO secrets (admin + lab user)

Creates gitignored files under `secrets/local/` and applies them to the cluster.

```bash
./scripts/setup_minio.sh --apply
```

**What this does**

- `minio-root` Secret — MinIO **admin** (console login)  
- `minio-lab-user` + mirrored Secrets in `redaction-agent`, `discovery-agent`, `mcp-gateway` — app S3 credentials  
- Buckets (via MinIO PostSync Job after deploy): `raw-documents`, `redacted-documents`, `vector-index`, `discovery-index`  

If you already ran an older secrets step, the script **reuses** existing `secrets/local` files unless you pass `--force`.

**MinIO console:** after deploy, open the `minio-console` Route and log in with root user/password from `secrets/local/minio-root.yaml`.

---

## Step 5 — Deploy catalog models (L40S-sized)

### 5.0 Create an NVIDIA GPU hardware profile (once)

Out of the box RHOAI only ships **`default-profile` (CPU)**. If Hardware profile is grayed out / stuck on default, create a GPU profile first:

```bash
oc apply -f manifests/rhoai-modelservice/hardware-profile-nvidia-l40s.yaml
oc get hardwareprofiles -n redhat-ods-applications
```

Or in the dashboard (as OpenShift AI admin): **Settings → Hardware profiles → Create**, add resource identifier `nvidia.com/gpu` (type Accelerator, count 1), leave visible everywhere.

### 5.1 Deploy from the catalog

1. Open **OpenShift AI** dashboard → **AI hub → Models → Catalog**  
2. Deploy into project **`rhoai-models`**  
3. For each model, set the **Kubernetes resource name** (not only a display name):  
   - Instruct / chat (fits **L40S ~48GB**) → resource name **`lab-slm`**  
   - Embedding → resource name **`lab-embed`**  
4. In the deploy wizard, click **Edit resource name** (or equivalent) and change the auto-filled catalog name (e.g. `redhataigranite-embedding-engl`) to the names above. Leaving the catalog default breaks lab scripts that expect `lab-slm` / `lab-embed`.  
5. Pick **NVIDIA L40S GPU** (not `default-profile` / CPU)  
6. Wait until both InferenceServices are Ready  

Verify the resource names before continuing:

```bash
oc get inferenceservice -n rhoai-models
# Expect NAME columns: lab-slm  and  lab-embed
```

```bash
./scripts/discover_catalog_models.sh --write
# Optional: also patch live ConfigMaps + restart agent pods
# ./scripts/discover_catalog_models.sh --write --apply
```

That prints and (with `--write`) fills:

```text
LLM_BASE_URL=http://lab-slm-predictor.rhoai-models.svc.cluster.local:8080/v1
LLM_MODEL=<id from /v1/models>
EMBEDDING_BASE_URL=http://lab-embed-predictor.rhoai-models.svc.cluster.local:8080/v1
EMBEDDING_MODEL=<id from /v1/models>
```

in:

- `manifests/agent/configmap.yaml`  
- `manifests/discovery/configmap.yaml`  
- `manifests/mcp-gateway/configmap.yaml`  

Then commit/push so Argo syncs (or rely on `--apply` for an immediate cluster patch).

GPU budget reminder: **1 GPU SLM + 1 GPU embed + 1 spare** on 3× g6e.4xlarge (1× L40S each).

---

## Step 6 — Deploy the lab with GitOps

### 6.1 Build and push images (from your laptop)

`image-registry.openshift-image-registry.svc:5000` only resolves **inside** the cluster. From a Mac/laptop use one of these:

**Option A — registry default Route (recommended on Mac; port-forward often drops mid-push):**

```bash
oc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"defaultRoute":true}}'
export REGISTRY=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')
# OpenShift accepts any username + a valid token
podman login -u unused -p "$(oc whoami -t)" "${REGISTRY}"

oc project redaction-agent
oc create imagestream redaction-agent 2>/dev/null || true
oc create imagestream redaction-ui 2>/dev/null || true

# Apple Silicon: must target amd64 or pods CrashLoop with "Exec format error"
podman build --platform linux/amd64 -f Dockerfile.agent -t ${REGISTRY}/redaction-agent/redaction-agent:latest .
podman build --platform linux/amd64 -f Dockerfile.ui -t ${REGISTRY}/redaction-agent/redaction-ui:latest .
podman push ${REGISTRY}/redaction-agent/redaction-agent:latest
podman push ${REGISTRY}/redaction-agent/redaction-ui:latest

oc tag redaction-agent/redaction-agent:latest redaction-agent/mcp-gateway:latest
oc -n discovery-agent create imagestream discovery-agent 2>/dev/null || true
oc tag redaction-agent/redaction-agent:latest discovery-agent/discovery-agent:latest
oc set image-lookup -n redaction-agent redaction-agent redaction-ui
oc rollout restart -n redaction-agent deployment/redaction-ui deployment/redaction-agent
```

**Option B — port-forward** (if you cannot enable the default Route): keep `oc port-forward -n openshift-image-registry svc/image-registry 5000:5000` running, use `REGISTRY=127.0.0.1:5000` (not `localhost`, which can hit IPv6), and the same `--platform linux/amd64` builds/pushes with `--tls-verify=false`.

### 6.2 Deploy GitOps apps

```bash
./scripts/deploy_lab.sh
# Important: use the Argo CRD — plain 'applications' is OpenShift app.k8s.io (empty/wrong)
oc get applications.argoproj.io -n openshift-gitops
```

**Expected child apps:** `minio`, `mcp-gateway`, `rhoai-modelservice`, `redaction-agent`, `redaction-web-ui`, `discovery-agent`, `lab-observability`.

If apps show **OutOfSync** with `Forbidden` / `cannot create resource` for the `openshift-gitops-argocd-application-controller` SA:

```bash
ARGO_SA=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
for ns in redaction-agent discovery-agent mcp-gateway minio lab-observability rhoai-models; do
  oc get ns "$ns" >/dev/null 2>&1 || oc create ns "$ns"
  oc label ns "$ns" argocd.argoproj.io/managed-by=openshift-gitops --overwrite
  # managed-by Role cannot create ResourceQuotas; admin covers Deployments/Services/Routes/Quotas
  oc adm policy add-role-to-user admin "$ARGO_SA" -n "$ns"
done

# Refresh alone is not enough after sync retries are exhausted — force a sync:
for app in redaction-agent discovery-agent mcp-gateway lab-observability redaction-web-ui minio; do
  oc -n openshift-gitops patch applications.argoproj.io/"$app" --type merge \
    -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
done
oc get applications.argoproj.io -n openshift-gitops
```

`deploy_lab.sh` now applies labels + admin and triggers sync automatically.

If `lab-observability` fails: Observability/OpenTelemetry Operator missing or Tempo endpoint DNS wrong — see `manifests/observability/`.

Routes:

```bash
oc -n redaction-agent get route redaction-ui
oc -n redaction-agent get route redaction-agent-api
oc -n discovery-agent get route discovery-agent-api
oc -n minio get route
```

---

## Step 7 — Fetch Hugging Face dataset → scratch → MinIO

```bash
./scripts/fetch_dataset.sh          # ~500 DocLayNet-v1.2 page PDFs → scratch/datasets/
./scripts/seed_minio.sh             # synthetic + scratch PDFs → raw-documents
```

If `seed_minio.sh` fails with `InvalidAccessKeyId` / `HeadBucket` 403, the MinIO PostSync Job never created buckets or the lab user (OpenShift non-root: `mc` needs `HOME=/tmp`). Fix and re-run:

```bash
# After pulling the job-create-buckets.yaml fix (HOME + MC_CONFIG_DIR=/tmp):
oc delete job -n minio minio-create-buckets --force --grace-period=0
oc delete pod -n minio -l job-name=minio-create-buckets --force --grace-period=0
oc apply -f manifests/minio/job-create-buckets.yaml
oc wait -n minio --for=condition=complete job/minio-create-buckets --timeout=120s
./scripts/seed_minio.sh
```

`seed_minio.sh` will also fall back to MinIO **root** from `secrets/local/minio-root.yaml` when the lab user is missing, so you can upload PDFs before the Job is healthy. Agents still need the lab user + policy once the Job succeeds.

Default: **`docling-project/DocLayNet-v1.2`**, **`HF_DATASET_LIMIT=500`** (single-page PDFs streamed from the Hub — not the multi‑GB DocLayNet extra zip).

```bash
# lab default (500 pages)
./scripts/fetch_dataset.sh

# smaller smoke pull
HF_DATASET_LIMIT=10 ./scripts/fetch_dataset.sh

# explicit
HF_DATASET_REPO=docling-project/DocLayNet-v1.2 HF_DATASET_LIMIT=500 HF_DATASET_SPLIT=test \
  ./scripts/fetch_dataset.sh
```

Passing `docling-project/DocLayNet` remaps to **v1.2** (base repo has no PDF blobs on the Hub).

---

## Step 8 — Use the Web UI (two tabs)

Open the `redaction-ui` Route.

1. **Redaction Agent** tab — select documents, enter Person / Place / Time / Events / Custom, run redaction, preview  
2. **Document Discovery Agent** tab — enter a query (optionally re-index), view scored snippets + summaries  

Smoke test from laptop:

```bash
./scripts/smoke_test.sh
```

---

## Step 9 — Jupyter workbench notebook

Create the workbench in the **OpenShift AI UI**, then seed the walkthrough notebook from your laptop.

### 9.1 Create the workbench (UI)

1. Open the OpenShift AI dashboard (`rhods-dashboard` Route in `redhat-ods-applications`).
2. Open (or create) Data Science project **`rhoai-models`**.
3. **Create workbench** with:
   - **Name:** anything memorable (e.g. `lab-walkthrough`)
   - **Image:** **Jupyter | Data Science | CPU | Python 3.12** (latest / 2025.2 or 3.4 is fine)
   - **Size:** Small is enough for the API demo
4. Start the workbench and wait until status is **Running**.
5. Optional: add environment variables (otherwise the notebook uses in-cluster defaults):
   - `REDACT_API_URL` = `http://redaction-agent.redaction-agent.svc.cluster.local:8000`
   - `DISCOVERY_API_URL` = `http://discovery-agent.discovery-agent.svc.cluster.local:8001`

### 9.2 Seed the walkthrough file

From this repo (workbench must be Running):

```bash
./scripts/setup_workbench.sh
# If you have more than one workbench:
./scripts/setup_workbench.sh --name <workbench-name>
./scripts/setup_workbench.sh --list
```

That copies `notebooks/lab_walkthrough.ipynb` into `/opt/app-root/src/` inside the workbench.

### 9.3 Run the demo

1. Open the workbench from the dashboard  
2. Open `lab_walkthrough.ipynb`  
3. Run all cells — health, list docs, redact, discovery  

Companion script: `notebooks/lab_walkthrough.py`

---

## Step 10 — View OpenTelemetry traces

**Do not open** `lab-otel-collector.lab-observability.svc.cluster.local` in a browser — that DNS name only works **inside** the cluster.

Observe → **Alerting / Metrics / Dashboards / Targets** is the default monitoring UI. **Observe → Traces** appears only after TempoMonolithic + the Distributed Tracing UIPlugin are installed (this lab’s `lab-observability` app). Hard-refresh the console (or log out/in) if Traces is missing after those resources are Ready.

### 10.1 One-time setup (if Traces is missing)

```bash
# Tempo backend + collector wiring (GitOps sync or):
oc apply -k manifests/observability/

# Adds Observe → Traces in the console (Cluster Observability Operator)
oc apply -f manifests/observability/uiplugin-distributed-tracing.yaml

oc get tempomonolithic,opentelemetrycollector,uiplugin -n lab-observability
oc get route -n lab-observability
```

Wait until `TempoMonolithic/lab` and `OpenTelemetryCollector/lab-otel` are Ready and UIPlugin `distributed-tracing` is Available. Hard-refresh the OpenShift console — you should see **Observe → Traces**.

Use the **Jaeger UI** Route in `lab-observability` as a fallback if the console Traces tab is delayed.

### 10.2 Generate and view traces

1. Generate traffic (Streamlit UI, workbench notebook, or `./scripts/smoke_test.sh`)  
2. Open **Observe → Traces**, select Tempo instance **lab** / tenant **lab**, filter services `redaction-agent` / `discovery-agent`  
3. Or open the **Jaeger UI** Route in `lab-observability` (same traces)

Agents export OTLP HTTP **in-cluster** to the lab collector:

```text
http://lab-otel-collector.lab-observability.svc.cluster.local:4318
```

The collector forwards traces to Tempo via the gateway (`tempo-lab-gateway…:4317`) with TLS, the collector ServiceAccount bearer token, and tenant header `X-Scope-OrgID: lab`.
---

## Step 11 — Load-bearing test (from your laptop)

```bash
./scripts/run_load_test.sh
# USERS=10 RUN_TIME=3m ./scripts/run_load_test.sh
```

Hits `/documents`, `/redact`, and discovery `/search`. On 3× L40S (g6e.4xlarge), higher concurrency should show API/GPU saturation — that is expected.

---

## Step 12 — Teardown (lab)

```bash
oc delete -f .argocd/root-application.yaml
oc delete applications.argoproj.io -n openshift-gitops -l app.kubernetes.io/part-of=auto-redaction-agent
oc delete project redaction-agent discovery-agent minio mcp-gateway lab-observability
# Keep rhoai-models if you want to reuse catalog deployments
```

---

## Architecture (short)

```text
UI (tabs) → Redaction API + Discovery API
         → MinIO (raw / redacted / vector-index / discovery-index)
         → Catalog SLM + Embeddings (rhoai-models)
         → OTel Collector → Observability Tempo UI
```

---

## Scripts cheat sheet

| Script | Purpose |
|--------|---------|
| `check_prerequisites.sh` | Gate: AI, GitOps, **NFD**, GPU, Observability, Storage |
| `discover_catalog_models.sh` | Resolve `LLM_*` / `EMBEDDING_*` from Ready catalog predictors |
| `configure_gitops_repo.sh` | Set Argo `repoURL` |
| `setup_minio.sh` | Generate/apply MinIO root + lab-user Secrets |
| `setup_workbench.sh` | Step 9: copy `lab_walkthrough.ipynb` into a UI-created workbench |
| `deploy_lab.sh` | Check + secrets + apply root Application |
| `fetch_dataset.sh` | HF → `scratch/datasets/` |
| `seed_minio.sh` | Upload synthetic + scratch PDFs |
| `smoke_test.sh` | Health + list docs |
| `run_load_test.sh` | Locust load test |

---

## Configuration reference

| Variable | Meaning |
|----------|---------|
| `S3_*` | MinIO endpoint + buckets (lab-user Secret) |
| `LLM_*` / `EMBEDDING_*` | Catalog InferenceServices |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Lab collector |
| `VECTOR_COLLECTION` | `redaction-events` |
| `DISCOVERY_COLLECTION` | `discovery-events` |

---

## Same cluster / discovery coexistence

Discovery already ships in `discovery-agent`. Share MinIO + catalog models; do not reuse reserved bucket/collection names for other labs: `raw-documents`, `redacted-documents`, `vector-index`, `discovery-index`, `redaction-events`, `discovery-events`.

---

## License

Apache-2.0
