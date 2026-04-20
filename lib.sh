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
  envsubst < "$src" > "$dst"
  echo "  rendered $src → $dst"
}

render_cluster_template() {
  export CLOUDS_YAML_B64
  CLOUDS_YAML_B64=$(envsubst < "$SCRIPT_DIR/clouds.yaml.tmpl" | base64 -w0)
  render_template "$SCRIPT_DIR/cluster-template.yaml.tmpl" "$SCRIPT_DIR/cluster-template.yaml"
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
