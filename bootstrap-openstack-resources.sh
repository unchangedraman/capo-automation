#!/bin/bash
# bootstrap-openstack-resources.sh
# One-time setup of OpenStack resources the scripts require: flavors + keypair.
# Assumes the 'openstack' CLI is installed and authenticated to the target cloud.
# The image and external network still need to exist — those are admin-level.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
load_config

# Auth via env vars so no clouds.yaml is needed here
export OS_AUTH_URL OS_USERNAME OS_PASSWORD OS_PROJECT_NAME OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_NAME OS_REGION_NAME OS_INTERFACE
export OS_IDENTITY_API_VERSION=3

command -v openstack >/dev/null || { echo 'ERROR: openstack CLI not installed (pip install python-openstackclient)' >&2; exit 1; }

ensure_flavor() {
  local name="$1" vcpus="$2" ram_mb="$3" disk_gb="$4"
  if openstack flavor show "$name" >/dev/null 2>&1; then
    echo "flavor '$name' already exists"
  else
    echo "creating flavor '$name' ($vcpus vCPU / ${ram_mb} MiB / ${disk_gb} GB)"
    openstack flavor create --vcpus "$vcpus" --ram "$ram_mb" --disk "$disk_gb" "$name" >/dev/null
  fi
}

ensure_keypair() {
  local name="$1"
  if openstack keypair show "$name" >/dev/null 2>&1; then
    echo "keypair '$name' already exists"
  else
    local key_path="$HOME/.ssh/${name}"
    if [ ! -f "$key_path" ]; then
      echo "generating new SSH key at $key_path"
      ssh-keygen -t ed25519 -N '' -f "$key_path" -C "capo-$(hostname)"
    fi
    echo "uploading public key to OpenStack as '$name'"
    openstack keypair create --public-key "${key_path}.pub" "$name" >/dev/null
  fi
}

check_image() {
  if openstack image show "${IMAGE_NAME}" >/dev/null 2>&1; then
    echo "image '${IMAGE_NAME}' exists"
  else
    echo "ERROR: image '${IMAGE_NAME}' not found in Glance." >&2
    echo "Upload a kubeadm-compatible Ubuntu image named '${IMAGE_NAME}'." >&2
    echo "Reference: https://image-builder.sigs.k8s.io/capi/providers/openstack" >&2
    exit 1
  fi
}

check_external_network() {
  if openstack network show "${EXTERNAL_NETWORK_ID}" >/dev/null 2>&1; then
    echo "external network ${EXTERNAL_NETWORK_ID} exists"
  else
    echo "ERROR: external network ${EXTERNAL_NETWORK_ID} not found." >&2
    echo "Run: openstack network list --external" >&2
    exit 1
  fi
}

check_octavia() {
  if openstack loadbalancer list >/dev/null 2>&1; then
    echo "Octavia reachable (LB service answering)"
  else
    echo "ERROR: Octavia (load-balancer) not reachable — CAPO needs it for the kube-apiserver LB." >&2
    echo "Check: openstack endpoint list --service load-balancer" >&2
    exit 1
  fi
}

check_cinder() {
  if openstack volume type list -f value -c Name >/dev/null 2>&1; then
    echo "Cinder reachable (volume types listable)"
  else
    echo "ERROR: Cinder (volumev3) not reachable — PVCs will fail." >&2
    exit 1
  fi
}

check_quota() {
  local need_cpu=$(( (CP_REPLICAS + WORKER_REPLICAS) * 2 ))
  local need_ram=$(( (CP_REPLICAS + WORKER_REPLICAS) * 4096 ))
  local need_vols=$(( CNPG_INSTANCES ))
  local cur
  cur=$(openstack quota show -f value -c cores 2>/dev/null || echo 0)
  [ "$cur" -lt "$need_cpu" ] 2>/dev/null \
    && echo "WARN: cores quota ($cur) < needed ($need_cpu)" \
    || echo "cores quota OK ($cur >= $need_cpu)"
  cur=$(openstack quota show -f value -c ram 2>/dev/null || echo 0)
  [ "$cur" -lt "$need_ram" ] 2>/dev/null \
    && echo "WARN: ram quota ($cur MiB) < needed ($need_ram MiB)" \
    || echo "ram quota OK ($cur MiB >= $need_ram MiB)"
  cur=$(openstack quota show -f value -c volumes 2>/dev/null || echo 0)
  [ "$cur" -lt "$need_vols" ] 2>/dev/null \
    && echo "WARN: volumes quota ($cur) < needed ($need_vols)" \
    || echo "volumes quota OK ($cur >= $need_vols)"
}

echo '========== Bootstrapping OpenStack resources =========='

echo; echo 'Step 1: verify image (admin prerequisite)'
check_image

echo; echo 'Step 2: verify external network (admin prerequisite)'
check_external_network

echo; echo 'Step 3: verify Octavia + Cinder services'
check_octavia
check_cinder

echo; echo 'Step 4: verify project quota'
check_quota

echo; echo 'Step 5: flavors'
ensure_flavor "${CP_FLAVOR}"     2 4096 20
ensure_flavor "${WORKER_FLAVOR}" 2 4096 20

echo; echo 'Step 6: SSH keypair'
ensure_keypair "${SSH_KEY_NAME}"

echo
echo '========== OpenStack resources ready =========='
echo 'Next: ./create-cluster.sh  then  ./post-bootstrap.sh'
