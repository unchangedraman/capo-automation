#!/bin/bash
# build-image.sh
# Build a kubeadm-ready OpenStack image (optionally PG-tuned) and upload it to
# a target OpenStack cloud. Two-phase: `build` runs locally via image-builder
# and packer; `upload` pushes the qcow2 to Glance on the named cloud.
#
# Usage:
#   ./build-image.sh build                       # produce build-output/<name>.qcow2
#   ./build-image.sh upload --cloud my-lab       # upload to cloud from clouds.yaml
#   ./build-image.sh verify --cloud my-lab       # confirm image exists + checksum
#
# Config via config.env:
#   K8S_VERSION                 e.g. v1.29.15 (required)
#   IMAGE_NAME                  final name in Glance (set by this script's default if unset)
#   IMAGE_VARIANT               'base' or 'pgbench' (default: pgbench)
#   IMAGE_REVISION              bump when tuning changes (default: v1)
#   UBUNTU_VERSION              2204 or 2404 (default: 2204)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
load_config

# -------- derived names --------
K8S_VER_NOV="${K8S_VERSION#v}"
UBUNTU_VERSION="${UBUNTU_VERSION:-2204}"
IMAGE_VARIANT="${IMAGE_VARIANT:-pgbench}"
IMAGE_REVISION="${IMAGE_REVISION:-v1}"
EXPECTED_NAME="ubuntu-${UBUNTU_VERSION}-k8s-${K8S_VER_NOV}-${IMAGE_VARIANT}-${IMAGE_REVISION}"
IMAGE_NAME="${IMAGE_NAME:-$EXPECTED_NAME}"

BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build-output}"
IMAGE_BUILDER_DIR="${IMAGE_BUILDER_DIR:-$BUILD_DIR/image-builder}"
IMAGE_BUILDER_REF="${IMAGE_BUILDER_REF:-main}"
OUT_QCOW2="$BUILD_DIR/${IMAGE_NAME}.qcow2"

# -------- logging --------
section() { echo; echo "========== $* =========="; }
info()    { echo "  $*"; }
die()     { echo "ERROR: $*" >&2; exit 1; }

# -------- build-phase helpers --------
check_host_deps() {
  section "Checking host dependencies for image build"
  [ -e /dev/kvm ] || die "/dev/kvm not present — image-builder needs native KVM. Run build on a workstation, not inside a VM."

  local missing=()
  for bin in packer ansible-playbook qemu-system-x86_64 git make virt-customize; do
    command -v "$bin" >/dev/null || missing+=("$bin")
  done

  if [ ${#missing[@]} -gt 0 ]; then
    echo "Installing: ${missing[*]}"
    local sudo=""; [ "$(id -u)" -ne 0 ] && sudo="sudo"
    $sudo apt-get update -qq
    # map binaries to packages
    local pkgs=()
    for m in "${missing[@]}"; do
      case "$m" in
        packer)                pkgs+=(packer) ;;
        ansible-playbook)      pkgs+=(ansible) ;;
        qemu-system-x86_64)    pkgs+=(qemu-system-x86 qemu-utils qemu-kvm) ;;
        git)                   pkgs+=(git) ;;
        make)                  pkgs+=(make) ;;
        virt-customize)        pkgs+=(libguestfs-tools) ;;
      esac
    done
    # packer sometimes comes from hashicorp repo — try default first, warn if missing
    $sudo apt-get install -y "${pkgs[@]}" || die "apt install failed for: ${pkgs[*]}"
  fi

  info "packer:       $(packer version 2>/dev/null | head -1 || echo missing)"
  info "qemu:         $(qemu-system-x86_64 --version | head -1)"
  info "ansible:      $(ansible --version | head -1)"
  info "virt-customize: $(virt-customize --version | head -1)"
}

fetch_image_builder() {
  section "Fetching kubernetes-sigs/image-builder"
  mkdir -p "$BUILD_DIR"
  if [ -d "$IMAGE_BUILDER_DIR/.git" ]; then
    info "already cloned at $IMAGE_BUILDER_DIR"
    (cd "$IMAGE_BUILDER_DIR" && git fetch --tags --quiet && git checkout --quiet "$IMAGE_BUILDER_REF")
  else
    git clone --depth 1 --branch "$IMAGE_BUILDER_REF" \
      https://github.com/kubernetes-sigs/image-builder.git "$IMAGE_BUILDER_DIR"
  fi
}

run_image_builder() {
  section "Running image-builder (make build-qemu-ubuntu-${UBUNTU_VERSION})"
  local capi_dir="$IMAGE_BUILDER_DIR/images/capi"
  [ -d "$capi_dir" ] || die "image-builder layout changed — $capi_dir missing"

  local target="build-qemu-ubuntu-${UBUNTU_VERSION}"
  local k8s_series; k8s_series="${K8S_VER_NOV%.*}"  # e.g. 1.29

  cat > "$capi_dir/packer/qemu/overrides.json" <<EOF
{
  "kubernetes_deb_version": "${K8S_VER_NOV}-1.1",
  "kubernetes_rpm_version": "${K8S_VER_NOV}",
  "kubernetes_semver": "v${K8S_VER_NOV}",
  "kubernetes_series": "v${k8s_series}",
  "distro_arch": "amd64",
  "image_name": "${IMAGE_NAME}"
}
EOF
  info "wrote overrides → $capi_dir/packer/qemu/overrides.json"

  (
    cd "$capi_dir"
    PACKER_VAR_FILES="$capi_dir/packer/qemu/overrides.json" \
      make deps-qemu
    PACKER_VAR_FILES="$capi_dir/packer/qemu/overrides.json" \
      make "$target"
  )

  # image-builder writes to images/capi/output/<image_name>-kube-v...
  local produced
  produced=$(find "$capi_dir/output" -maxdepth 2 -name '*.qcow2' -newer "$capi_dir/packer/qemu/overrides.json" | head -1)
  [ -n "$produced" ] || die "no qcow2 produced under $capi_dir/output"

  mkdir -p "$BUILD_DIR"
  cp -f "$produced" "$OUT_QCOW2"
  info "produced: $OUT_QCOW2  ($(du -h "$OUT_QCOW2" | cut -f1))"
}

customize_for_pgbench() {
  [ "$IMAGE_VARIANT" = "pgbench" ] || { info "variant=$IMAGE_VARIANT — skipping PG tuning"; return; }
  section "Injecting PG-benchmark tuning into qcow2"

  [ -f "$SCRIPT_DIR/tuning/99-pgbench.conf" ]    || die "missing tuning/99-pgbench.conf"
  [ -f "$SCRIPT_DIR/tuning/disable-thp.service" ] || die "missing tuning/disable-thp.service"

  # virt-customize works on the qcow2 in-place
  virt-customize -a "$OUT_QCOW2" \
    --copy-in "$SCRIPT_DIR/tuning/99-pgbench.conf:/etc/sysctl.d/" \
    --copy-in "$SCRIPT_DIR/tuning/disable-thp.service:/etc/systemd/system/" \
    --run-command 'systemctl enable disable-thp.service' \
    --run-command 'apt-get purge -y unattended-upgrades || true' \
    --run-command 'apt-get clean && rm -rf /var/cache/apt/archives/*.deb'

  info "PG tuning baked: sysctls, THP-disable service, unattended-upgrades removed"
}

emit_manifest() {
  section "Writing build manifest"
  local manifest="$BUILD_DIR/${IMAGE_NAME}.manifest.json"
  local sha; sha=$(sha256sum "$OUT_QCOW2" | awk '{print $1}')
  local size; size=$(stat -c%s "$OUT_QCOW2")

  cat > "$manifest" <<EOF
{
  "image_name":       "$IMAGE_NAME",
  "k8s_version":      "$K8S_VERSION",
  "ubuntu_version":   "$UBUNTU_VERSION",
  "variant":          "$IMAGE_VARIANT",
  "revision":         "$IMAGE_REVISION",
  "qcow2_path":       "$OUT_QCOW2",
  "sha256":           "$sha",
  "size_bytes":       $size,
  "built_at":         "$(date -Is)",
  "image_builder_ref":"$IMAGE_BUILDER_REF",
  "tuning_files": [
    "$(sha256sum "$SCRIPT_DIR/tuning/99-pgbench.conf" 2>/dev/null | awk '{print $1}') 99-pgbench.conf",
    "$(sha256sum "$SCRIPT_DIR/tuning/disable-thp.service" 2>/dev/null | awk '{print $1}') disable-thp.service"
  ]
}
EOF
  info "manifest: $manifest"
  info "sha256:   $sha"
}

# -------- upload-phase helpers --------
upload_image() {
  local cloud="$1"
  [ -n "$cloud" ] || die "upload: --cloud <name> required"
  command -v openstack >/dev/null || die "openstack CLI not installed on this host"
  [ -f "$OUT_QCOW2" ] || die "qcow2 not found: $OUT_QCOW2 — run './build-image.sh build' first"

  section "Uploading to cloud '$cloud'"
  if openstack --os-cloud "$cloud" image show "$IMAGE_NAME" >/dev/null 2>&1; then
    local existing; existing=$(openstack --os-cloud "$cloud" image show "$IMAGE_NAME" -f value -c checksum)
    local local_md5; local_md5=$(md5sum "$OUT_QCOW2" | awk '{print $1}')
    if [ "$existing" = "$local_md5" ]; then
      info "image '$IMAGE_NAME' already in Glance with matching checksum — skipping upload"
      return
    else
      die "image '$IMAGE_NAME' exists in Glance but checksum differs. Bump IMAGE_REVISION or delete existing manually."
    fi
  fi

  openstack --os-cloud "$cloud" image create \
    --disk-format qcow2 \
    --container-format bare \
    --min-disk 20 \
    --property os_type=linux \
    --property os_distro=ubuntu \
    --property hw_scsi_model=virtio-scsi \
    --property hw_disk_bus=scsi \
    --property hypervisor_type=qemu \
    --file "$OUT_QCOW2" \
    "$IMAGE_NAME"

  info "upload complete"
  openstack --os-cloud "$cloud" image show "$IMAGE_NAME" -f value -c id -c checksum -c size
}

verify_image() {
  local cloud="$1"
  [ -n "$cloud" ] || die "verify: --cloud <name> required"
  section "Verifying image '$IMAGE_NAME' on cloud '$cloud'"
  openstack --os-cloud "$cloud" image show "$IMAGE_NAME" \
    -f value -c id -c status -c checksum -c size -c min_disk \
    || die "image not found on cloud '$cloud'"
  if [ -f "$OUT_QCOW2" ]; then
    local remote; remote=$(openstack --os-cloud "$cloud" image show "$IMAGE_NAME" -f value -c checksum)
    local local_md5; local_md5=$(md5sum "$OUT_QCOW2" | awk '{print $1}')
    [ "$remote" = "$local_md5" ] \
      && info "checksum matches local qcow2" \
      || { echo "WARN: remote checksum $remote != local $local_md5"; exit 1; }
  fi
}

# -------- dispatcher --------
cmd="${1:-}"; shift || true
cloud=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cloud) cloud="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

case "$cmd" in
  build)
    echo "Target image: $IMAGE_NAME"
    echo "Output:       $OUT_QCOW2"
    check_host_deps
    fetch_image_builder
    run_image_builder
    customize_for_pgbench
    emit_manifest
    echo
    echo "Build complete. Next: ./build-image.sh upload --cloud <name>"
    ;;
  upload)  upload_image "$cloud" ;;
  verify)  verify_image "$cloud" ;;
  *)
    cat >&2 <<EOF
Usage:
  $0 build                           # build qcow2 locally (needs /dev/kvm)
  $0 upload --cloud <cloud-name>     # push to Glance on cloud from clouds.yaml
  $0 verify --cloud <cloud-name>     # confirm image present + checksum

Expects config.env to be loaded. Key vars:
  K8S_VERSION=${K8S_VERSION:-<unset>}
  IMAGE_NAME=${IMAGE_NAME}
  IMAGE_VARIANT=${IMAGE_VARIANT}
  IMAGE_REVISION=${IMAGE_REVISION}
  UBUNTU_VERSION=${UBUNTU_VERSION}
EOF
    exit 1 ;;
esac
