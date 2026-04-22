# Shared functions for portable CAPO automation.
# Source this from all scripts.

load_config() {
  local cfg="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"
  if [ ! -f "$cfg" ]; then
    echo "ERROR: config file not found: $cfg" >&2; exit 1
  fi
  # shellcheck source=/dev/null
  set -a; . "$cfg"; set +a
  echo "Loaded config: $cfg"
}

render_template() {
  local src="$1" dst="$2"
  # Restrict envsubst to an explicit allowlist so shell-style $vars inside
  # embedded scripts (preKubeadmCommands, files.content, etc.) are preserved
  # instead of silently expanded to empty strings. Any variable referenced in
  # a template must be added here.
  local allow='$CLUSTER_NAME $CLOUD_NAME $CLOUDS_YAML_B64
    $EXTERNAL_NETWORK_ID $NODE_CIDR $POD_CIDR
    $CP_FLAVOR $WORKER_FLAVOR $IMAGE_NAME $SSH_KEY_NAME
    $K8S_VERSION $CP_REPLICAS $WORKER_REPLICAS
    $CILIUM_OVERLAY_SG_NAME
    $CNPG_VERSION $CNPG_NAMESPACE $CNPG_CLUSTER_NAME $CNPG_INSTANCES
    $CNPG_MIN_SYNC $CNPG_MAX_SYNC $STORAGE_CLASS $STORAGE_SIZE
    $PG_IMAGE $DB_NAME $DB_OWNER
    $PG_MAX_CONNECTIONS $PG_SHARED_BUFFERS $PG_EFFECTIVE_CACHE_SIZE $PG_WAL_KEEP_SIZE
    $PG_CPU_REQUEST $PG_MEM_REQUEST $PG_CPU_LIMIT $PG_MEM_LIMIT
    $OS_AUTH_URL $OS_USERNAME $OS_PASSWORD $OS_PROJECT_NAME
    $OS_USER_DOMAIN_NAME $OS_PROJECT_DOMAIN_NAME $OS_REGION_NAME $OS_INTERFACE'
  envsubst "$allow" < "$src" > "$dst"
  echo "  rendered $src → $dst"
}

render_cluster_template() {
  export CLOUDS_YAML_B64
  CLOUDS_YAML_B64=$(render_to_stdout "$SCRIPT_DIR/clouds.yaml.tmpl" | base64 -w0)
  render_template "$SCRIPT_DIR/cluster-template.yaml.tmpl" "$SCRIPT_DIR/cluster-template.yaml"
}

render_to_stdout() {
  # Same envsubst allowlist as render_template but stdout only (for piping).
  local src="$1"
  local allow='$OS_AUTH_URL $OS_USERNAME $OS_PASSWORD $OS_PROJECT_NAME
    $OS_USER_DOMAIN_NAME $OS_PROJECT_DOMAIN_NAME $OS_REGION_NAME $OS_INTERFACE
    $CLOUD_NAME'
  envsubst "$allow" < "$src"
}

install_cilium() {
  echo
  echo "Installing Cilium ${CILIUM_VERSION} via Helm..."
  helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
  helm repo update cilium >/dev/null

  local api_server api_host api_port
  api_server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  api_host=$(echo "$api_server" | sed -E 's|https?://([^:/]+).*|\1|')
  api_port=$(echo "$api_server" | sed -nE 's|https?://[^:]+:([0-9]+).*|\1|p')
  api_port=${api_port:-6443}

  local extra_args=()
  if [ "${CILIUM_KUBE_PROXY_REPLACEMENT:-false}" = "true" ]; then
    extra_args+=(--set kubeProxyReplacement=true --set k8sServiceHost="$api_host" --set k8sServicePort="$api_port")
  fi
  if [ "${CILIUM_TUNNEL_PROTOCOL:-vxlan}" = "disabled" ]; then
    extra_args+=(--set routingMode=native --set autoDirectNodeRoutes=true)
  else
    extra_args+=(--set tunnelProtocol="${CILIUM_TUNNEL_PROTOCOL}")
  fi
  if [ "${CILIUM_HUBBLE_ENABLED:-true}" = "true" ]; then
    extra_args+=(--set hubble.enabled=true --set hubble.relay.enabled=true --set hubble.ui.enabled=true)
  fi

  helm upgrade --install cilium cilium/cilium \
    --namespace kube-system \
    --version "${CILIUM_VERSION}" \
    --set ipam.mode=kubernetes \
    "${extra_args[@]}" \
    --wait --timeout 5m
  echo "Cilium installed."
}
