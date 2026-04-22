#!/bin/bash
# install-prereqs.sh — install docker, kind, kubectl, clusterctl, helm on Ubuntu.
# Idempotent: skips anything already installed at the pinned version.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
load_config

ARCH="amd64"
[ "$(uname -m)" = "aarch64" ] && ARCH="arm64"

need_sudo() { [ "$(id -u)" -ne 0 ] && echo 'sudo' || echo ''; }
SUDO=$(need_sudo)

section() { echo; echo "========== $* =========="; }

install_docker() {
  if command -v docker >/dev/null && docker version >/dev/null 2>&1; then
    echo "docker: already installed ($(docker --version))"
    return
  fi
  section "Installing docker"
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq ca-certificates curl gnupg
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update -qq
  # Ubuntu 24.04 ships docker-compose-v2 which owns the same cli-plugin path
  # as Docker's docker-compose-plugin; remove it first to avoid dpkg conflict.
  if dpkg -l docker-compose-v2 2>/dev/null | grep -q '^ii'; then
    $SUDO apt-get remove -y -qq docker-compose-v2 || true
  fi
  $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  $SUDO usermod -aG docker "${USER}"
  echo "NOTE: log out and back in (or run 'newgrp docker') so this shell sees docker group membership."
}

install_kubectl() {
  if command -v kubectl >/dev/null; then
    echo "kubectl: already installed ($(kubectl version --client -o json 2>/dev/null | grep gitVersion | head -1 || kubectl version --client --short 2>/dev/null))"
    return
  fi
  section "Installing kubectl ${KUBECTL_VERSION}"
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  $SUDO install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm /tmp/kubectl
}

install_kind() {
  if command -v kind >/dev/null && [ "$(kind version 2>/dev/null | awk '{print $2}')" = "${KIND_VERSION}" ]; then
    echo "kind: already at ${KIND_VERSION}"
    return
  fi
  section "Installing kind ${KIND_VERSION}"
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
  $SUDO install -m 0755 /tmp/kind /usr/local/bin/kind
  rm /tmp/kind
}

install_clusterctl() {
  if command -v clusterctl >/dev/null && clusterctl version 2>/dev/null | grep -q "GitVersion:\"${CLUSTERCTL_VERSION}\""; then
    echo "clusterctl: already at ${CLUSTERCTL_VERSION}"
    return
  fi
  section "Installing clusterctl ${CLUSTERCTL_VERSION}"
  curl -fsSLo /tmp/clusterctl "https://github.com/kubernetes-sigs/cluster-api/releases/download/${CLUSTERCTL_VERSION}/clusterctl-linux-${ARCH}"
  $SUDO install -m 0755 /tmp/clusterctl /usr/local/bin/clusterctl
  rm /tmp/clusterctl
}

install_helm() {
  if command -v helm >/dev/null && helm version --short 2>/dev/null | grep -q "${HELM_VERSION}"; then
    echo "helm: already at ${HELM_VERSION}"
    return
  fi
  section "Installing helm ${HELM_VERSION}"
  curl -fsSLo /tmp/helm.tar.gz "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  tar -xzf /tmp/helm.tar.gz -C /tmp
  $SUDO install -m 0755 /tmp/linux-${ARCH}/helm /usr/local/bin/helm
  rm -rf /tmp/helm.tar.gz /tmp/linux-${ARCH}
}

install_envsubst() {
  if command -v envsubst >/dev/null; then return; fi
  section "Installing envsubst (gettext)"
  $SUDO apt-get install -y -qq gettext-base
}

install_openstack_client() {
  # Need `openstack` CLI + octavia plugin so bootstrap-openstack-resources.sh
  # can verify octavia (`openstack loadbalancer list`) and create flavors/keypair.
  if command -v openstack >/dev/null && openstack loadbalancer --help >/dev/null 2>&1; then
    echo "openstack CLI + octaviaclient already installed"
    return
  fi
  section "Installing openstack CLI + octaviaclient"
  $SUDO apt-get install -y -qq python3-openstackclient python3-octaviaclient
}

echo "Installing prerequisites (ARCH=${ARCH})..."
install_envsubst
install_docker
install_kubectl
install_kind
install_clusterctl
install_helm
install_openstack_client

echo
echo "========== Versions =========="
docker --version       || echo 'docker: NOT installed'
kind --version         || echo 'kind: NOT installed'
kubectl version --client --short 2>/dev/null || kubectl version --client -o json 2>/dev/null | grep gitVersion | head -1
clusterctl version 2>&1 | head -1
helm version --short

echo
echo "Prereqs installed. Next: ./install-mgmt-cluster.sh"
