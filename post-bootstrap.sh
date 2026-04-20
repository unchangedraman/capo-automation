#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

load_config

echo "========== Post-CAPO Bootstrap: $CLUSTER_NAME =========="

# Wait for machines
echo "Waiting for all CAPI machines to be Running..."
for i in $(seq 1 60); do
  RUNNING=$(kubectl get machines --no-headers 2>/dev/null | grep -c Running || true)
  TOTAL=$(kubectl get machines --no-headers 2>/dev/null | wc -l || true)
  echo "  $RUNNING/$TOTAL Running"
  [ "$RUNNING" = "$TOTAL" ] && [ "$TOTAL" -gt 0 ] && break
  sleep 10
done

# Workload kubeconfig
echo "Fetching workload kubeconfig..."
clusterctl get kubeconfig "$CLUSTER_NAME" > "/tmp/${CLUSTER_NAME}-kubeconfig"
export KUBECONFIG="/tmp/${CLUSTER_NAME}-kubeconfig"

# Wait for nodes
echo "Waiting for nodes to appear..."
for i in $(seq 1 30); do
  NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || true)
  [ "$NODES" -gt 0 ] && break
  sleep 5
done
kubectl get nodes

# 1. Install Cilium CNI
install_cilium

# 2. Cloud-config secret for OCCM + Cinder CSI (OpenStack-specific)
echo
echo "Creating cloud-config secret from cloud.conf.tmpl..."
render_template "$SCRIPT_DIR/cloud.conf.tmpl" "$SCRIPT_DIR/cloud.conf"
kubectl -n kube-system create secret generic cloud-config \
  --from-file=cloud.conf="$SCRIPT_DIR/cloud.conf" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. OpenStack Cloud Controller Manager
echo
echo "Installing OpenStack Cloud Controller Manager..."
kubectl apply -f "$SCRIPT_DIR/manifests/cloud-controller-manager-roles.yaml" 2>&1 | tail -1
kubectl apply -f "$SCRIPT_DIR/manifests/cloud-controller-manager-role-bindings.yaml" 2>&1 | tail -1
kubectl apply -f "$SCRIPT_DIR/manifests/openstack-cloud-controller-manager-ds.yaml" 2>&1 | tail -1

echo "Waiting for OCCM to initialize nodes (removes uninitialized taint)..."
for i in $(seq 1 30); do
  UNINIT=$(kubectl get nodes -o jsonpath='{range .items[*]}{.spec.taints[*].key}{"\n"}{end}' 2>/dev/null | grep -c uninitialized || true)
  [ "$UNINIT" = "0" ] && break
  sleep 5
done

# 4. Cinder CSI
echo
echo "Installing Cinder CSI..."
kubectl apply -f "$SCRIPT_DIR/manifests/csi-driver.yaml" 2>&1 | tail -1
kubectl apply -f "$SCRIPT_DIR/manifests/cinder-csi-controllerplugin-rbac.yaml" 2>&1 | tail -1
kubectl apply -f "$SCRIPT_DIR/manifests/cinder-csi-nodeplugin-rbac.yaml" 2>&1 | tail -1
kubectl apply -f "$SCRIPT_DIR/manifests/cinder-csi-controllerplugin.yaml" 2>&1 | tail -1
kubectl apply -f "$SCRIPT_DIR/manifests/cinder-csi-nodeplugin.yaml" 2>&1 | tail -1
kubectl apply -f "$SCRIPT_DIR/manifests/storageclass.yaml" 2>&1 | tail -1

# 5. Wait for core pods
echo
echo "Waiting for core pods to be ready..."
for i in $(seq 1 30); do
  NOT_READY=$(kubectl get pods -A --no-headers 2>/dev/null | grep -v Running | grep -v Completed | wc -l || true)
  [ "$NOT_READY" = "0" ] && break
  sleep 10
done

# 6. CNPG operator
echo
echo "========== Installing CloudNativePG ${CNPG_VERSION} =========="
kubectl apply --server-side -f "$SCRIPT_DIR/manifests/cnpg-${CNPG_VERSION}.yaml" 2>&1 | tail -5
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=180s

echo
echo "Patching operator for HA (2 replicas + anti-affinity)..."
kubectl -n cnpg-system patch deployment cnpg-controller-manager \
  --patch-file "$SCRIPT_DIR/manifests/cnpg-operator-patch.yaml"
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=120s

# 7. CNPG Cluster
echo
echo "Deploying CNPG Cluster (instances=${CNPG_INSTANCES}, sync=${CNPG_MIN_SYNC}/${CNPG_MAX_SYNC}, storageClass=${STORAGE_CLASS})..."
kubectl create namespace "${CNPG_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
render_template "$SCRIPT_DIR/manifests/cnpg-cluster.yaml.tmpl" "$SCRIPT_DIR/manifests/cnpg-cluster.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/cnpg-cluster.yaml"

echo
echo "Waiting for CNPG cluster to reach healthy state (~3-5 min)..."
for i in $(seq 1 40); do
  READY=$(kubectl -n "${CNPG_NAMESPACE}" get cluster "${CNPG_CLUSTER_NAME}" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo 0)
  PHASE=$(kubectl -n "${CNPG_NAMESPACE}" get cluster "${CNPG_CLUSTER_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || echo 'pending')
  echo "  t=${i} ready=${READY}/${CNPG_INSTANCES} phase='${PHASE}'"
  [ "$READY" = "${CNPG_INSTANCES}" ] && [ "$PHASE" = 'Cluster in healthy state' ] && break
  sleep 15
done

# 8. PgBouncer Pooler
echo
echo "Deploying PgBouncer pooler..."
render_template "$SCRIPT_DIR/manifests/cnpg-pooler.yaml.tmpl" "$SCRIPT_DIR/manifests/cnpg-pooler.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/cnpg-pooler.yaml"

# 9. Grant schema perms (benchmark-friendly)
echo
echo "Granting schema permissions to ${DB_OWNER}..."
kubectl -n "${CNPG_NAMESPACE}" exec "${CNPG_CLUSTER_NAME}-1" -c postgres -- \
  psql -U postgres -d "${DB_NAME}" -c "GRANT ALL ON SCHEMA public TO ${DB_OWNER};" 2>&1 | tail -1

# 10. Final status
echo
echo "========== Bootstrap Complete =========="
kubectl get nodes -o wide
echo
kubectl -n "${CNPG_NAMESPACE}" get cluster "${CNPG_CLUSTER_NAME}"
echo
kubectl -n "${CNPG_NAMESPACE}" get pods -o wide
echo
kubectl -n "${CNPG_NAMESPACE}" get svc
echo
echo "Kubeconfig: /tmp/${CLUSTER_NAME}-kubeconfig"
echo "  export KUBECONFIG=/tmp/${CLUSTER_NAME}-kubeconfig"
echo
echo "Write endpoint:  ${CNPG_CLUSTER_NAME}-pooler-rw.${CNPG_NAMESPACE}.svc.cluster.local"
echo "Read endpoint:   ${CNPG_CLUSTER_NAME}-ro.${CNPG_NAMESPACE}.svc.cluster.local"
