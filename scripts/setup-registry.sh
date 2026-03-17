#!/usr/bin/env bash
# setup-registry.sh
# Configures a container image registry for a k3s cluster.
#
# Run this script on EVERY node in your cluster (server and agents).
# On the server node it will also deploy the registry pod if needed.
#
# Usage:
#   sudo ./scripts/setup-registry.sh [NODE_PORT] [REGISTRY_IP...]
#
# NODE_PORT defaults to 32000.
# REGISTRY_IPs default to both the LAN IP (192.168.1.110) and the
# Tailscale IP (100.69.236.43) so the registry is reachable from either network.
# Pass one or more IPs explicitly to override the defaults.

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
NODE_PORT="${1:-32000}"
shift || true
if [[ $# -gt 0 ]]; then
  REGISTRY_IPS=("$@")
else
  REGISTRY_IPS=(192.168.1.110 100.69.236.43)
fi
K3S_REGISTRIES="/etc/rancher/k3s/registries.yaml"
K3S_CONFIG="/etc/rancher/k3s/config.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(cd "${SCRIPT_DIR}/../k8s" && pwd)"

# Primary host used for log messages and pod deploy
PRIMARY_HOST="${REGISTRY_IPS[0]}:${NODE_PORT}"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[setup-registry] $*"; }
warn() { echo "[setup-registry] WARN: $*" >&2; }
die()  { echo "[setup-registry] ERROR: $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "This script must be run as root (sudo)."
}

require_k3s() {
  command -v k3s &>/dev/null || die "k3s is not installed on this node."
}

# Returns the k3s minor version as an integer (e.g. 28 for v1.28.4+k3s2).
k3s_minor_version() {
  k3s --version 2>/dev/null \
    | head -1 \
    | grep -oE 'v[0-9]+\.[0-9]+' \
    | head -1 \
    | cut -d. -f2
}

# Returns "server" if k3s is running as a server, "agent" otherwise.
node_role() {
  if systemctl is-active --quiet k3s 2>/dev/null; then
    echo "server"
  elif systemctl is-active --quiet k3s-agent 2>/dev/null; then
    echo "agent"
  else
    # Fall back to checking running processes
    if pgrep -f "k3s server" &>/dev/null; then
      echo "server"
    else
      echo "agent"
    fi
  fi
}

# ── Embedded registry (Spegel, k3s >= v1.26) ─────────────────────────────────
enable_embedded_registry() {
  log "Enabling k3s embedded registry (Spegel)..."

  mkdir -p "$(dirname "${K3S_CONFIG}")"

  if [[ -f "${K3S_CONFIG}" ]] && grep -q "^embedded-registry:" "${K3S_CONFIG}"; then
    log "embedded-registry already set in ${K3S_CONFIG}, skipping."
  else
    echo "embedded-registry: true" >> "${K3S_CONFIG}"
    log "Added 'embedded-registry: true' to ${K3S_CONFIG}."
    K3S_NEEDS_RESTART=true
  fi
}

# ── Deployed registry (registry:2 pod) ───────────────────────────────────────
deploy_registry_pod() {
  log "Deploying registry:2 pod via kubectl..."
  kubectl apply -f "${K8S_DIR}/registry.yaml"

  log "Waiting for registry pod to become ready..."
  kubectl rollout status deployment/registry -n registry-system --timeout=120s

  log "Registry deployed. NodePort: ${NODE_PORT}"
  log "Push images with:  docker push ${PRIMARY_HOST}/<image>:<tag>"
}

# ── registries.yaml ───────────────────────────────────────────────────────────
configure_registries_yaml() {
  mkdir -p "$(dirname "${K3S_REGISTRIES}")"

  local any_added=false
  for ip in "${REGISTRY_IPS[@]}"; do
    local host="${ip}:${NODE_PORT}"
    log "Configuring ${K3S_REGISTRIES} for insecure registry at ${host}..."

    # If the entry already exists, skip to avoid duplicates.
    if [[ -f "${K3S_REGISTRIES}" ]] && grep -q "${host}" "${K3S_REGISTRIES}"; then
      log "${host} already present in ${K3S_REGISTRIES}, skipping."
      continue
    fi

    # Append mirror config (preserves any existing entries).
    cat >> "${K3S_REGISTRIES}" <<EOF

mirrors:
  "${host}":
    endpoint:
      - "http://${host}"
configs:
  "${host}":
    tls:
      insecure_skip_verify: true
EOF

    log "${K3S_REGISTRIES} updated for ${host}."
    any_added=true
  done

  [[ "${any_added}" == "true" ]] && K3S_NEEDS_RESTART=true
}

# ── k3s restart ───────────────────────────────────────────────────────────────
restart_k3s() {
  local role="$1"
  local svc="k3s"
  [[ "${role}" == "agent" ]] && svc="k3s-agent"

  if systemctl is-active --quiet "${svc}"; then
    log "Restarting ${svc} to apply config changes..."
    systemctl restart "${svc}"
    log "${svc} restarted."
  else
    warn "${svc} service is not active — skipping restart. Start it manually when ready."
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  require_root
  require_k3s

  K3S_NEEDS_RESTART=false
  ROLE="$(node_role)"
  MINOR="$(k3s_minor_version)"

  log "Detected node role: ${ROLE}"
  log "k3s minor version: ${MINOR}"

  if [[ "${ROLE}" == "server" ]]; then
    if [[ "${MINOR}" -ge 26 ]]; then
      log "k3s >= v1.26 detected — using Spegel embedded registry."
      enable_embedded_registry
    else
      log "k3s < v1.26 — deploying registry:2 pod."
      deploy_registry_pod
    fi
  else
    log "Agent node — skipping registry deployment (run this on the server node for that)."
    log "Configuring this agent to trust the registry at ${PRIMARY_HOST} (and any additional IPs)."
  fi

  configure_registries_yaml

  if [[ "${K3S_NEEDS_RESTART}" == "true" ]]; then
    restart_k3s "${ROLE}"
  else
    log "No config changes required — no restart needed."
  fi

  echo ""
  log "Done. Summary:"
  for ip in "${REGISTRY_IPS[@]}"; do
    log "  Registry address : ${ip}:${NODE_PORT}"
  done
  log "  Push example     : docker push ${PRIMARY_HOST}/sample-grpc:latest"
  log "  Pod image ref    : image: ${PRIMARY_HOST}/sample-grpc:latest"
  echo ""

  if [[ "${ROLE}" == "server" ]]; then
    warn "Multi-node cluster detected. Run this script on each agent node as well:"
    warn "  sudo ./scripts/setup-registry.sh ${NODE_PORT}"
  fi
}

main "$@"
