# Contributing

## Setup

1. Copy any `*.yaml` files in `shared/` that contain credentials and create local overrides:
   ```bash
   cp shared/federated-store-cluster1.yaml shared/federated-store-cluster1.local.yaml
   # Edit with your actual credentials — *.local.yaml is gitignored
   ```

2. Update placeholder values before deploying:
   - `<GITEA_ADMIN_USER>` / `<GITEA_PASSWORD>` — your Gitea admin credentials
   - `<MINIO_PASSWORD>` — MinIO root password
   - `<CLUSTER1_DOCKER_IP>` — output of `docker inspect kubecost-primary-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'`

## Structure

See README.md for full setup instructions.

## Issues & PRs

Issues and pull requests welcome. Please test against a local kind environment before submitting.
