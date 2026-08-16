# Secrets (local only)

Real credentials are **not** stored in Git.

## Preferred (lab)

```bash
./scripts/setup_minio.sh --apply
```

Creates gitignored files under `secrets/local/`:

| File | Purpose |
|------|---------|
| `minio-root.yaml` | MinIO admin (console) |
| `minio-lab-user.yaml` | Lab S3 user in `minio` |
| `redaction-secrets.yaml` | Same lab user for redaction-agent |
| `discovery-secrets.yaml` | Same lab user for discovery-agent |
| `mcp-secrets.yaml` | Same lab user for mcp-gateway |
| `minio-lab-user-creds.env` | Local env for `seed_minio.sh` |

Legacy helper: `scripts/generate_local_secrets.sh` (still works for older flows).

Apply before or with `scripts/deploy_lab.sh`. Argo does **not** commit these files.
