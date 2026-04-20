#!/bin/bash
# install-mgmt-cluster.sh — create the kind management cluster and install
# CAPI core + CAPO provider. Idempotent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
load_config

check_prereqs() {
  local missing=()
  for bin in docker kind kubectl clusterctl helm envsubst; do
    command -v "$bin" >/dev/null || missing+=("$bin")
  done
  if [ ${#missing[@]} -ne 0 ]; then
    echo "ERROR: missing binaries: ${missing[*]}" >&2
    echo "Run ./install-prereqs.sh first." >&2
    exit 1
  fi
  if ! docker version >/dev/null 2>&1; then
    echo "ERROR: docker is installed but current user cannot reach it." >&2
    echo "Run 'newgrp docker' or log out/in, then re-run." >&2
    exit 1
  fi
}

ensure_kind_cluster() {
  if kind get clusters 2>/dev/null | grep -q "^${MGMT_CLUSTER_NAME}$"; then
    echo "kind cluster '${MGMT_CLUSTER_NAME}' already exists — skipping create"
  else
    echo "Creating kind cluster '${MGMT_CLUSTER_NAME}'..."
    kind create cluster --name "${MGMT_CLUSTER_NAME}"
  fi
  kubectl config use-context "kind-${MGMT_CLUSTER_NAME}"
  kubectl wait --for=condition=Ready nodes --all --timeout=120s
}

ensure_capi() {
  if kubectl get ns capo-system >/dev/null 2>&1 \
     && kubectl -n capo-system get deploy capo-controller-manager >/dev/null 2>&1; then
    echo "CAPI + CAPO already installed — skipping clusterctl init"
    return
  fi
  echo "Running 'clusterctl init --infrastructure openstack'..."
  clusterctl init --infrastructure openstack
  # Wait for the provider controllers to come up
  for ns in capi-system capi-kubeadm-bootstrap-system capi-kubeadm-control-plane-system capo-system; do
    kubectl -n "$ns" rollout status deploy --timeout=180s 2>&1 | sed "s/^/  [$ns] /"
  done
}

echo "========== Management-cluster bootstrap =========="
echo "  kind cluster name:  ${MGMT_CLUSTER_NAME}"
echo "  CAPI provider:      openstack (CAPO)"
echo

check_prereqs
ensure_kind_cluster
ensure_capi

echo
echo "========== Management cluster ready =========="
kubectl get pods -A | grep -E 'capi|capo' || true
echo
echo "kubectl context: kind-${MGMT_CLUSTER_NAME}"
echo "Next: ./create-cluster.sh  then  ./post-bootstrap.sh"
