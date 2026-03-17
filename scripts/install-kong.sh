#!/usr/bin/env bash
# One-time script to install Kong Ingress Controller on Kubernetes via Helm.
# Run from the repo root: ./scripts/install-kong.sh
set -euo pipefail

helm repo add kong https://charts.konghq.com
helm repo update

kubectl create namespace kong --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install kong kong/ingress \
    --namespace kong \
    --values k8s/kong-values.yaml \
    --wait

echo "Kong installed. Proxy NodePort: 30080"
