#!/usr/bin/env bash
# install-cnpg.sh
# Installs the CloudNative-PG operator onto the Kubernetes cluster via Helm.
#
# Review this script before running — it modifies cluster-level resources.
#
# Usage:
#   ./scripts/install-cnpg.sh
#
# Prerequisites:
#   - helm >= 3
#   - kubectl configured to point at your Kubernetes cluster

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REPO_NAME="cnpg"
REPO_URL="https://cloudnative-pg.github.io/charts"
CHART="cnpg/cloudnative-pg"
CHART_VERSION="0.27.1"
RELEASE_NAME="cnpg"
NAMESPACE="cnpg-system"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[install-cnpg] $*"; }
die()  { echo "[install-cnpg] ERROR: $*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
command -v helm    &>/dev/null || die "helm is not installed."
command -v kubectl &>/dev/null || die "kubectl is not installed."

log "Cluster context: $(kubectl config current-context)"

# ── Helm repo ─────────────────────────────────────────────────────────────────
if helm repo list 2>/dev/null | grep -q "^${REPO_NAME}"; then
    log "Helm repo '${REPO_NAME}' already added, updating..."
    helm repo update "${REPO_NAME}"
else
    log "Adding Helm repo '${REPO_NAME}' -> ${REPO_URL}"
    helm repo add "${REPO_NAME}" "${REPO_URL}"
    helm repo update "${REPO_NAME}"
fi

# ── Install / upgrade operator ────────────────────────────────────────────────
log "Installing ${CHART} v${CHART_VERSION} into namespace '${NAMESPACE}'..."

helm upgrade --install "${RELEASE_NAME}" "${CHART}" \
    --version "${CHART_VERSION}" \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --set replicaCount=1 \
    --wait \
    --timeout 5m

log "Operator deployed. Waiting for CRDs to be established..."

for crd in clusters.postgresql.cnpg.io backups.postgresql.cnpg.io scheduledbackups.postgresql.cnpg.io; do
    kubectl wait --for=condition=Established crd/"${crd}" --timeout=60s
    log "CRD ready: ${crd}"
done

log ""
log "CloudNative-PG operator is ready."
log "Next: apply the database cluster manifest:"
log "  kubectl apply -f k8s/postgres.yaml"
