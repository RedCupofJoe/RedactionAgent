# Secrets (local only)

Real credentials are **not** stored in Git.

## Generate

```bash
./scripts/generate_local_secrets.sh
```

Writes YAML under `secrets/local/` (gitignored):

| File | Cluster Secret |
|------|----------------|
| `minio-root.yaml` | `minio/minio-root` |
| `redaction-secrets.yaml` | `redaction-agent/redaction-secrets` |
| `redaction-secrets-mcp.yaml` | `mcp-gateway/redaction-secrets` |

Non-interactive:

```bash
export MINIO_ROOT_USER=labuser
export MINIO_ROOT_PASSWORD='your-strong-password'
./scripts/generate_local_secrets.sh --from-env
```

## Apply to OpenShift

```bash
./scripts/generate_local_secrets.sh --apply
# or
oc apply -f secrets/local/
```

Apply **before** or immediately after the MinIO / agent sync so pods can mount the Secrets. Argo CD does not manage these files.

Committed templates (placeholders only):

- `manifests/minio/secret.example.yaml`
- `manifests/agent/secret.example.yaml`
