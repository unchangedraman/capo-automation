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
  # openstack quota show without a project argument returns empty on some
  # installs, which coalesces to 0 and produces a false "quota too low" warning.
  local proj="${OS_PROJECT_NAME:-}"
  if [ -z "$proj" ]; then
    echo "WARN: OS_PROJECT_NAME unset — skipping quota check"
    return
  fi
  # -1 means unlimited in OpenStack quotas; treat as OK.
  _cmp() {
    local label=$1 cur=$2 need=$3 unit=$4
    if [ "$cur" = "-1" ]; then
      echo "$label quota OK (unlimited, need $need$unit)"
    elif [ "$cur" -lt "$need" ] 2>/dev/null; then
      echo "WARN: $label quota ($cur$unit) < needed ($need$unit)"
    else
      echo "$label quota OK ($cur$unit >= $need$unit)"
    fi
  }
  local cur
  cur=$(openstack quota show "$proj" -f value -c cores   2>/dev/null); _cmp cores   "${cur:-0}" "$need_cpu"  ""
  cur=$(openstack quota show "$proj" -f value -c ram     2>/dev/null); _cmp ram     "${cur:-0}" "$need_ram" " MiB"
  cur=$(openstack quota show "$proj" -f value -c volumes 2>/dev/null); _cmp volumes "${cur:-0}" "$need_vols" ""
}

check_orphan_volumes() {
  # After destroying a previous CAPO cluster, Cinder can leave volumes in
  # 'available' state that silently fail to delete because a dead QEMU still
  # holds an RBD exclusive-lock. Those volumes consume Cinder quota and RBD
  # space forever. Detecting them here lets the user fix before running
  # create-cluster.sh and hitting quota errors mid-provision.
  local stuck
  stuck=$(openstack volume list --status available --long -f value -c Name 2>/dev/null | grep -E '(my-k8s|capi|cnpg|pvc-)' | wc -l)
  if [ "${stuck:-0}" -gt 0 ]; then
    echo "WARN: $stuck orphan Cinder volume(s) in 'available' state from a previous deploy."
    echo "      If they won't delete via 'openstack volume delete' (ImageBusy error),"
    echo "      run the admin-keyring lock cleanup:"
    echo "         ~/Desktop/namma-cloud/scripts/kolla-ansible/cleanup-orphan-rbd-locks.sh <vdc-name> --delete"
    echo "      On non-VDC (real) OpenStack, talk to the Cinder admin to break locks."
  else
    echo "No orphan Cinder volumes detected"
  fi
}

ensure_cilium_overlay_sg() {
  # CAPO's managedSecurityGroups reconciler wipes any rule it doesn't own, so
  # we can't just append VXLAN rules to the CP/worker SGs. Instead, create a
  # standalone SG that CAPO leaves alone and reference it from each
  # OpenStackMachineTemplate.securityGroups. Opens:
  #   - UDP 8472 : Cilium VXLAN overlay (default tunnelProtocol)
  #   - UDP 6081 : Geneve (in case Cilium is reconfigured)
  #   - TCP 4240 : cilium-health endpoint
  #   - ICMP     : pod<->pod + cilium-health ICMP probes
  # All restricted to the cluster's NODE_CIDR so only nodes inside this
  # cluster can talk VXLAN to each other.
  local name="${CILIUM_OVERLAY_SG_NAME}"
  if openstack security group show "$name" >/dev/null 2>&1; then
    echo "Cilium overlay SG '$name' exists"
    return
  fi
  echo "creating Cilium overlay SG '$name'"
  openstack security group create "$name" \
    --description "Cilium VXLAN overlay + health for ${CLUSTER_NAME}" >/dev/null
  for rule in \
      "udp 8472" \
      "udp 6081" \
      "tcp 4240"; do
    read -r proto port <<<"$rule"
    openstack security group rule create --ingress \
      --protocol "$proto" --dst-port "$port" \
      --remote-ip "${NODE_CIDR}" "$name" >/dev/null
  done
  openstack security group rule create --ingress \
    --protocol icmp --remote-ip "${NODE_CIDR}" "$name" >/dev/null
  echo "  opened UDP 8472 / 6081, TCP 4240, ICMP from ${NODE_CIDR}"
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

echo; echo 'Step 7: Cilium overlay SG (works around CAPO SG reconciler)'
ensure_cilium_overlay_sg

echo; echo 'Step 8: orphan Cinder volumes check'
check_orphan_volumes

echo
echo '========== OpenStack resources ready =========='
echo 'Next: ./create-cluster.sh  then  ./post-bootstrap.sh'
