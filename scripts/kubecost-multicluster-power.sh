#!/bin/zsh
# kubecost-multicluster-power.sh
# Ordered shutdown and startup for the kubecost multi-cluster demo environment
# Clusters: kind-kubecost-primary, kind-kubecost-secondary

set -euo pipefail

PRIMARY="kind-kubecost-primary"
SECONDARY="kind-kubecost-secondary"

DOCKER_CONTAINERS=(
  "kubecost-primary-control-plane"
  "kubecost-primary-worker"
  "kubecost-primary-worker2"
  "kubecost-secondary-control-plane"
  "kubecost-secondary-worker"
  "kubecost-secondary-worker2"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

check_context() {
  kubectl config get-contexts "$1" &>/dev/null
}

docker_stop() {
  log "Stopping kind Docker containers..."
  for container in "${DOCKER_CONTAINERS[@]}"; do
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
      docker stop "$container" && ok "Stopped $container" || warn "Failed to stop $container"
    else
      warn "$container not running"
    fi
  done
}

docker_start() {
  log "Starting kind Docker containers..."
  for container in "${DOCKER_CONTAINERS[@]}"; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
      docker start "$container" && ok "Started $container" || warn "Failed to start $container"
    else
      warn "$container not found"
    fi
  done
  log "Waiting for API servers to be ready..."
  sleep 10
  kubectl wait --for=condition=Ready nodes --all --context kind-kubecost-primary --timeout=60s 2>/dev/null && \
    ok "kind-kubecost-primary nodes ready" || warn "Primary nodes not ready yet"
  kubectl wait --for=condition=Ready nodes --all --context kind-kubecost-secondary --timeout=60s 2>/dev/null && \
    ok "kind-kubecost-secondary nodes ready" || warn "Secondary nodes not ready yet"
}

# ──────────────────────────────────────────────────────────────────────────────
shutdown() {
  log "Starting ordered shutdown of kubecost multi-cluster demo..."
  echo ""

  log "=== Shutting down kind-kubecost-secondary ==="
  if check_context "$SECONDARY"; then
    log "Scaling down workloads on secondary..."
    for ns in team-alpha team-gamma team-delta; do
      kubectl scale deployment --all -n "$ns" --replicas=0 --context "$SECONDARY" 2>/dev/null && \
        ok "Scaled down $ns" || warn "$ns not found or already scaled"
    done
    log "Stopping Kubecost agent on secondary..."
    kubectl scale deployment kubecost-finopsagent -n kubecost --replicas=0 --context "$SECONDARY" 2>/dev/null && \
      ok "kubecost-finopsagent stopped" || warn "kubecost-finopsagent not found"
    kubectl scale statefulset kubecost-aggregator -n kubecost --replicas=0 --context "$SECONDARY" 2>/dev/null && \
      ok "kubecost-aggregator stopped" || warn "kubecost-aggregator not found"
  else
    warn "Skipping secondary — context not available"
  fi

  echo ""
  log "=== Shutting down kind-kubecost-primary ==="
  if check_context "$PRIMARY"; then
    log "Scaling down workloads on primary..."
    for ns in team-alpha team-beta; do
      kubectl scale deployment --all -n "$ns" --replicas=0 --context "$PRIMARY" 2>/dev/null && \
        ok "Scaled down $ns" || warn "$ns not found or already scaled"
    done
    log "Stopping Kubecost primary..."
    kubectl scale deployment kubecost-finopsagent -n kubecost --replicas=0 --context "$PRIMARY" 2>/dev/null && \
      ok "kubecost-finopsagent stopped" || warn "kubecost-finopsagent not found"
    kubectl scale statefulset kubecost-aggregator -n kubecost --replicas=0 --context "$PRIMARY" 2>/dev/null && \
      ok "kubecost-aggregator stopped" || warn "kubecost-aggregator not found"
    kubectl scale deployment kubecost-frontend -n kubecost --replicas=0 --context "$PRIMARY" 2>/dev/null && \
      ok "kubecost-frontend stopped" || warn "kubecost-frontend not found"
    log "Stopping MinIO..."
    kubectl scale deployment --all -n minio --replicas=0 --context "$PRIMARY" 2>/dev/null && \
      ok "MinIO stopped" || warn "MinIO not found"
    log "Stopping Gitea..."
    kubectl scale deployment gitea -n gitea --replicas=0 --context "$PRIMARY" 2>/dev/null && \
      ok "Gitea stopped" || warn "Gitea not found"
  else
    warn "Skipping primary — context not available"
  fi

  echo ""
  docker_stop
  echo ""
  ok "Shutdown complete."
  log "To start again: ./kubecost-multicluster-power.sh start"
}

# ──────────────────────────────────────────────────────────────────────────────
startup() {
  log "Starting kubecost multi-cluster demo environment..."
  echo ""

  docker_start
  echo ""

  log "=== Starting kind-kubecost-primary ==="
  if ! check_context "$PRIMARY"; then
    err "Primary context not found. Rebuild: kind create cluster --config bootstrap/kind-config-cluster1.yaml"
    exit 1
  fi

  log "Starting Gitea..."
  kubectl scale deployment gitea -n gitea --replicas=1 --context "$PRIMARY" 2>/dev/null && \
    ok "Gitea starting" || warn "Gitea not found"
  log "Starting MinIO..."
  kubectl scale deployment --all -n minio --replicas=1 --context "$PRIMARY" 2>/dev/null && \
    ok "MinIO starting" || warn "MinIO not found"
  log "Starting Kubecost primary..."
  kubectl scale deployment kubecost-frontend -n kubecost --replicas=1 --context "$PRIMARY" 2>/dev/null && \
    ok "kubecost-frontend starting" || warn "kubecost-frontend not found"
  kubectl scale statefulset kubecost-aggregator -n kubecost --replicas=1 --context "$PRIMARY" 2>/dev/null && \
    ok "kubecost-aggregator starting" || warn "kubecost-aggregator not found"
  kubectl scale deployment kubecost-finopsagent -n kubecost --replicas=1 --context "$PRIMARY" 2>/dev/null && \
    ok "kubecost-finopsagent starting" || warn "kubecost-finopsagent not found"
  log "Starting workloads on primary..."
  kubectl scale deployment alpha-app -n team-alpha --replicas=2 --context "$PRIMARY" 2>/dev/null && \
    ok "team-alpha scaled to 2" || warn "team-alpha not found"
  kubectl scale deployment beta-app -n team-beta --replicas=3 --context "$PRIMARY" 2>/dev/null && \
    ok "team-beta scaled to 3" || warn "team-beta not found"

  echo ""
  log "=== Starting kind-kubecost-secondary ==="
  if ! check_context "$SECONDARY"; then
    err "Secondary context not found. Rebuild: kind create cluster --config bootstrap/kind-config-cluster2.yaml"
    exit 1
  fi

  log "Starting Kubecost agent on secondary..."
  kubectl scale statefulset kubecost-aggregator -n kubecost --replicas=1 --context "$SECONDARY" 2>/dev/null && \
    ok "kubecost-aggregator starting" || warn "kubecost-aggregator not found"
  kubectl scale deployment kubecost-finopsagent -n kubecost --replicas=1 --context "$SECONDARY" 2>/dev/null && \
    ok "kubecost-finopsagent starting" || warn "kubecost-finopsagent not found"
  log "Starting workloads on secondary..."
  kubectl scale deployment alpha-app -n team-alpha --replicas=3 --context "$SECONDARY" 2>/dev/null && \
    ok "team-alpha scaled to 3" || warn "team-alpha not found"
  kubectl scale deployment gamma-app -n team-gamma --replicas=1 --context "$SECONDARY" 2>/dev/null && \
    ok "team-gamma scaled to 1" || warn "team-gamma not found"
  kubectl scale deployment delta-app -n team-delta --replicas=2 --context "$SECONDARY" 2>/dev/null && \
    ok "team-delta scaled to 2" || warn "team-delta not found"

  echo ""
  log "Waiting for Kubecost aggregator on primary..."
  kubectl rollout status statefulset/kubecost-aggregator -n kubecost \
    --context "$PRIMARY" --timeout=120s 2>/dev/null && \
    ok "kubecost-aggregator ready" || warn "Check aggregator manually"

  echo ""
  ok "Startup complete."
  echo ""
  log "Port-forward commands:"
  echo "  Kubecost UI:  kubectl port-forward -n kubecost svc/kubecost-frontend 9003:9090 --context kind-kubecost-primary"
  echo "  Prometheus:   kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090 --context kind-kubecost-primary"
  echo "  Gitea:        kubectl port-forward -n gitea pod/\$(kubectl get pod -n gitea -l app=gitea -o jsonpath='{.items[0].metadata.name}') 3002:3000 --context kind-kubecost-primary"
  echo "  MinIO:        kubectl port-forward -n minio pod/\$(kubectl get pod -n minio -l app=minio -o jsonpath='{.items[0].metadata.name}') 9000:9000 --context kind-kubecost-primary"
}

# ──────────────────────────────────────────────────────────────────────────────
status() {
  log "=== Cluster status ==="
  echo ""
  for ctx in "$PRIMARY" "$SECONDARY"; do
    log "--- $ctx ---"
    if check_context "$ctx"; then
      kubectl get pods -n kubecost --context "$ctx" \
        --no-headers 2>/dev/null | awk '{print "  "$1"\t"$3"\t"$4}' || warn "kubecost namespace not found"
    else
      warn "Context not available"
    fi
    echo ""
  done
}

# ──────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
  stop|shutdown)  shutdown ;;
  start|startup)  startup  ;;
  status)         status   ;;
  *)
    echo "Usage: $0 {start|stop|status}"
    echo ""
    echo "  start   — start Docker containers then scale up all components"
    echo "  stop    — scale down all components then stop Docker containers"
    echo "  status  — show pod status across both clusters"
    exit 1
    ;;
esac
