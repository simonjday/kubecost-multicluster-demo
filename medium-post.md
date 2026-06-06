# Multi-Cluster Kubernetes Cost Attribution with Kubecost v3, MinIO, and Kyverno

*How to build a production-grade FinOps demo that shows real team-level cost visibility across two Kubernetes clusters — with policy-enforced label governance baked in.*

---

## Why this matters

Cost visibility in Kubernetes is easy to describe and hard to deliver. Everyone wants to answer "which team is spending what?" but in practice, two things get in the way:

1. **Labels are inconsistent.** Without enforcement, workloads get deployed without the labels Kubecost needs to attribute cost. The result is a growing "Unallocated workloads" bucket that makes the data meaningless.

2. **Multi-cluster visibility is an Enterprise problem.** Most teams start with a single cluster. As they scale, costs fragment across clusters and the unified view disappears.

This post walks through a demo that solves both — using Kubecost v3 Enterprise, MinIO for federated storage, and Kyverno to enforce label compliance at admission time.

---

## Architecture

Two kind clusters, completely isolated from any existing environments:

- **kind-kubecost-primary** — Kubecost UI, aggregator, federator, MinIO (S3-compatible object storage)
- **kind-kubecost-secondary** — Kubecost finops-agent only (no UI), pushes metrics to MinIO on cluster1

```
┌──────────────────────────────────────┐     ┌──────────────────────────────────────┐
│  kind-kubecost-primary  (cluster1)   │     │  kind-kubecost-secondary  (cluster2) │
│                                      │     │                                      │
│  Kubecost PRIMARY (UI + aggregator)  │     │  Kubecost AGENT (no UI)              │
│  ArgoCD + Kyverno                    │     │  ArgoCD + Kyverno                    │
│  Gitea (GitOps source for both)      │     │                                      │
│  MinIO (federated object storage)    │     │                                      │
│                                      │     │                                      │
│  team-alpha (shared) ────────────────┼─────┼─ team-alpha (shared)                 │
│  team-beta  (unique to c1)           │     │  team-gamma (unique to c2)           │
│                                      │     │  team-delta (unique to c2)           │
│                                      │     │                                      │
│  Kubecost Federator ◄────────────────┼─────┼─ finops-agent → MinIO               │
└──────────────────────────────────────┘     └──────────────────────────────────────┘
```

### Kubecost v3 federation model

Kubecost 3.x replaced Thanos with S3-compatible object storage. The `finops-agent` on each cluster pushes metrics to a shared MinIO bucket. The `federator` on the primary reads and combines all cluster data into a single view.

### Team / cluster matrix

The intentionally mixed workload distribution makes the demo interesting:

| Team | Cluster 1 | Cluster 2 | Cost centre |
|------|-----------|-----------|-------------|
| alpha | ✅ 2 replicas | ✅ 3 replicas | engineering |
| beta | ✅ 3 replicas | ❌ | platform |
| gamma | ❌ | ✅ 1 replica | data |
| delta | ❌ | ✅ 2 replicas | data |

`team-alpha` deliberately spans both clusters at different scales. This produces the key demo moment: one team, two clusters, one unified cost view.

---

## The governance layer — Kyverno label enforcement

Before anything shows up correctly in Kubecost, workloads need consistent labels. Two Kyverno ClusterPolicies enforce this at admission on both clusters:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-team-label
    match:
      any:
      - resources:
          kinds: [Deployment, StatefulSet, DaemonSet]
          namespaces: [team-alpha, team-beta, team-gamma, team-delta]
    validate:
      message: "Label 'team' is required for cost attribution."
      pattern:
        metadata:
          labels:
            team: "?*"
        spec:
          template:
            metadata:
              labels:
                team: "?*"
```

Try deploying without labels and you get blocked immediately:

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
resource Deployment/team-alpha/unlabelled-app was blocked due to the following policies
require-cost-centre-label:
  check-cost-centre-label: 'validation error: Label ''cost-centre'' is required'
require-team-label:
  check-team-label: 'validation error: Label ''team'' is required'
```

[SCREENSHOT: Terminal showing Kyverno admission denial]

This is the governance story: without policy enforcement, unlabelled workloads silently accumulate in the "Unallocated" bucket. With Kyverno, the data stays clean.

---

## The critical kube-state-metrics fix

This is the most common gotcha with Kubecost label attribution. kube-state-metrics v2+ drops all pod labels by default, so Kubecost can't see them even if your pods are correctly labelled.

Fix it on both clusters:

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --version 85.0.1 --reuse-values \
  --set-string "kube-state-metrics.extraArgs[0]=--metric-labels-allowlist=pods=[team\,cost-centre\,environment\,app\,cluster]" \
  --kube-context kind-kubecost-primary
```

Verify the fix worked by querying Prometheus directly:

```bash
curl -s "http://localhost:9090/api/v1/query?query=kube_pod_labels{namespace=\"team-alpha\"}" \
  | jq '.data.result[0].metric'
```

You should see `label_team`, `label_cost_centre`, `label_environment`, `label_cluster` in the response. If you get null, the allowlist isn't applied — this is the single biggest cause of the "Unallocated workloads" problem.

---

## Kubecost v3 — what changed from v2

If you've used Kubecost before, v3 has several breaking changes worth knowing:

| v2 | v3 |
|----|-----|
| `kubecostProductConfigs.clusterName` | `global.clusterId` |
| `kubecostFrontend.enabled` | `frontend.enabled` |
| `federatedETL.federatedCluster` | `finopsagent.enabled` |
| Thanos for federation | S3/MinIO via `global.federatedStorage` |
| `cost-analyzer` chart | `kubecost` chart from new repo |
| Port 9002 | Port 9090 |

Install with the new chart:

```bash
helm repo add kubecost3 https://kubecost.github.io/kubecost/
helm install kubecost kubecost3/kubecost \
  -n kubecost \
  --set global.clusterId=kubecost-primary
```

Primary cluster values:

```yaml
global:
  clusterId: "kubecost-primary"
  federatedStorage:
    existingSecret: "federated-store"
    fileName: "federated-store.yaml"

frontend:
  enabled: true

finopsagent:
  enabled: true

federator:
  enabled: true
```

Secondary cluster values (agent only, no UI):

```yaml
global:
  clusterId: "kubecost-secondary"
  federatedStorage:
    existingSecret: "federated-store"
    fileName: "federated-store.yaml"

frontend:
  enabled: false

finopsagent:
  enabled: true

federator:
  enabled: false
```

---

## MinIO federation

MinIO runs on cluster1 and acts as the shared S3 bucket. Both clusters need a secret pointing at it — but with different endpoints since cluster2 can't use the in-cluster DNS of cluster1.

**Cluster1** (in-cluster DNS):
```yaml
type: S3
config:
  bucket: kubecost-federated
  endpoint: minio.minio.svc.cluster.local:9000
  access_key: <MINIO_USER>
  secret_key: <MINIO_PASSWORD>
  insecure: true
```

**Cluster2** (Docker network IP + NodePort — the key insight for kind-to-kind connectivity):
```yaml
type: S3
config:
  bucket: kubecost-federated
  endpoint: <CLUSTER1_DOCKER_IP>:30900
  access_key: <MINIO_USER>
  secret_key: <MINIO_PASSWORD>
  insecure: true
```

Verify it's working:

```bash
mc ls kubecost-minio/kubecost-federated/
# Should show: controller/  federated/  finops-agent/
```

---

## What the UI shows

### Overview — both clusters active

[SCREENSHOT: Overview page showing kubecost-primary and kubecost-secondary with costs]

The overview shows both clusters as active with separate cost cards and a combined total. This is the Enterprise multi-cluster view enabled by the 30-day trial (Settings → Start Free Trial).

### Allocations by team — unified view

[SCREENSHOT: Allocations aggregated by team showing alpha, beta, gamma, delta]

All four teams visible in a single view. `alpha` represents spend from both clusters combined. `beta` is cluster1-only, `gamma` and `delta` are cluster2-only.

### The money shot — alpha by cluster

[SCREENSHOT: Allocations filtered to team=alpha, aggregated by cluster showing kubecost-primary and kubecost-secondary]

Click into `alpha` and aggregate by cluster. This is the demo moment: one engineering team running workloads on two different clusters, with per-cluster cost visibility. The different replica counts and resource requests produce different costs per cluster — exactly the kind of insight that drives rightsizing decisions.

Via API:

```bash
curl -s "http://localhost:9003/model/allocation?window=1d&aggregate=cluster&accumulate=true&filter=label%5Bteam%5D%3A%22alpha%22" \
  | jq '.data[0] | to_entries | map(select(.key | startswith("_") | not)) | map({cluster: .key, total: .value.totalCost})'
```

```json
[
  { "cluster": "kubecost-primary",   "total": 0.00111 },
  { "cluster": "kubecost-secondary", "total": 0.00083 }
]
```

### Chargeback by cost-centre

[SCREENSHOT: Allocations aggregated by cost-centre showing engineering, platform, data]

Swap the aggregate to `cost-centre` label for the chargeback view. `engineering` covers alpha across both clusters, `platform` covers beta, `data` covers gamma and delta.

---

## GitOps with ArgoCD

Both clusters are managed via ArgoCD pointing at a single Gitea repo. Each cluster has its own path (`cluster1/` and `cluster2/`) within the repo, with a single ArgoCD Application per cluster.

A few gotchas worth documenting:

**kind-config.yaml must not be in the ArgoCD sync path.** It's a kind CLI config file, not a Kubernetes manifest. ArgoCD will try to apply it and fail. Solution: move it to a `bootstrap/` directory and exclude it from sync.

**Exclude the argocd/ directory from sync** to avoid the Application managing itself:

```yaml
source:
  directory:
    recurse: true
    exclude: 'argocd/**'
```

**Kyverno ClusterPolicies need ignoreDifferences** because Kyverno mutates `.spec`, `.status`, and `.metadata.annotations` post-apply, causing permanent OutOfSync:

```yaml
ignoreDifferences:
- group: kyverno.io
  kind: ClusterPolicy
  jsonPointers:
  - /status
  - /spec
  - /metadata/annotations
```

**ArgoCD Unknown deadlock on first boot** — if the Application goes Unknown and stays there, delete and recreate it. ArgoCD skips auto-sync when status is Unknown, creating a deadlock that only a recreation breaks.

---

## Repo structure

Everything is in GitHub at [github.com/simonjday/kubecost-multicluster-demo](https://github.com/simonjday/kubecost-multicluster-demo):

```
kubecost-multicluster-demo/
├── bootstrap/              # kind cluster configs — NOT synced by ArgoCD
├── cluster1/               # Primary cluster manifests
│   ├── argocd/
│   ├── kubecost/
│   ├── namespaces/
│   ├── policy/
│   └── workloads/
├── cluster2/               # Secondary cluster manifests
│   ├── argocd/
│   ├── kubecost/
│   ├── namespaces/
│   ├── policy/
│   └── workloads/
└── shared/                 # Policies and secret templates
```

The README has the full 16-step setup guide including all the fixes encountered during the live build.

---

## Key takeaways

**Kubecost v3 is a significant architectural shift.** The move from Thanos to S3-compatible storage simplifies federation but requires updating all your values files if you're migrating from v2.

**kube-state-metrics label allowlist is non-negotiable.** Without it, all your workloads show as Unallocated regardless of how well you've labelled them. It's a one-line fix but it's easy to miss.

**Kyverno makes the cost data trustworthy.** Kubecost can only attribute cost to workloads that have the right labels. Kyverno ensures those labels are always there — turning cost visibility from aspirational to operational.

**kind-to-kind networking needs NodePort.** For local multi-cluster demos with kind, the Docker network IP + NodePort is the reliable way to get inter-cluster connectivity without a load balancer.

---

*The full setup guide and all manifests are available at [github.com/simonjday/kubecost-multicluster-demo](https://github.com/simonjday/kubecost-multicluster-demo). If you found this useful or hit different issues with your setup, drop a comment below.*

---

**Tags:** Kubernetes, FinOps, Kubecost, Platform Engineering, DevOps, Cost Attribution, Kyverno, GitOps, ArgoCD
