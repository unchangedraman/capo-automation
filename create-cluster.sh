#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

load_config

echo "========== Creating CAPO cluster: $CLUSTER_NAME =========="
echo "  OpenStack:  $OS_AUTH_URL (region $OS_REGION_NAME, cloud $CLOUD_NAME)"
echo "  Image:      $IMAGE_NAME"
echo "  Flavors:    cp=$CP_FLAVOR  worker=$WORKER_FLAVOR (x$WORKER_REPLICAS)"
echo "  Pod CIDR:   $POD_CIDR"
echo "  Node CIDR:  $NODE_CIDR"

echo
echo "Rendering cluster-template.yaml from template..."
render_cluster_template

echo
echo "Applying CAPO resources (Cluster, ControlPlane, MachineDeployment, Secret)..."
kubectl apply -f "$SCRIPT_DIR/cluster-template.yaml"

echo
echo "Done. Watch progress with:"
echo "  kubectl get clusters,machines -w"
echo "After machines are Running:"
echo "  $SCRIPT_DIR/post-bootstrap.sh"
