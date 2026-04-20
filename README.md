# capo-automation

Portable scripts that provision an HA Kubernetes cluster on **any OpenStack cloud** using **Cluster API Provider OpenStack (CAPO)**, then install **Cilium** (CNI), **OpenStack Cloud Controller Manager** (node init), **Cinder CSI** (block storage), and a production-shape **CloudNativePG** HA Postgres cluster with a **PgBouncer** pooler and read/write services.

From a blank Ubuntu VM with network access to an OpenStack cloud and the internet, five scripts in order produce a working HA Postgres cluster.

## Architecture

```
   bootstrap host                                OpenStack cloud
   --------------------------------              ------------------------------
    docker + kind + clusterctl + helm
     |
     +-- kind cluster  capi-mgmt
     |    +-- CAPI core controllers
     |    +-- CAPO (OpenStack provider)
     |                 |
     |                 v
     |            creates VMs, subnet, router,
     |            security groups, floating IPs,
     |            Octavia LB for kube-apiserver
     |                 |
     |                 v
     |    workload cluster (CP + workers)
     |        |
     |        +-- Cilium (CNI, kube-proxy optional)
     |        +-- OCCM (openstack cloud provider)
     |        +-- Cinder CSI (PVCs on Cinder volumes)
     |        +-- CloudNativePG
     |             +-- Cluster (3 instances, sync ANY 1)
     |             +-- Pooler (PgBouncer x 2)
```

## The five scripts

| Order | Script | Purpose |
|------:|--------|---------|
| 1 | `install-prereqs.sh` | Installs docker, kind, kubectl, clusterctl, helm, envsubst on a fresh Ubuntu host. Idempotent. |
| 2 | `install-mgmt-cluster.sh` | Creates the kind management cluster and installs CAPI + CAPO via `clusterctl init --infrastructure openstack`. |
| 3 | `bootstrap-openstack-resources.sh` | (Optional) Creates compute flavors and SSH keypair on your OpenStack. Verifies image + external network exist. |
| 4 | `create-cluster.sh` | Renders CAPO manifests from `config.env` and applies them. CAPO provisions subnets, router, SGs, VMs, LB. |
| 5 | `post-bootstrap.sh` | Once VMs are up, installs Cilium -> OCCM -> Cinder CSI -> CNPG -> PgBouncer. Waits for each phase to be ready. |

Every script is idempotent - safe to re-run.

## Quick start

On a fresh Ubuntu machine with internet:

```bash
git clone git@github.com:unchangedraman/capo-automation.git
cd capo-automation

# Fill in CHANGE_ME_* lines (OpenStack auth, external network UUID, etc.)
vim config.env

./install-prereqs.sh
newgrp docker   # or log out/in so the docker group takes effect

./install-mgmt-cluster.sh
./bootstrap-openstack-resources.sh   # optional if admin already set up flavors/keypair
./create-cluster.sh
./post-bootstrap.sh
```

When `post-bootstrap.sh` completes, the workload kubeconfig is at `/tmp/CLUSTER_NAME-kubeconfig` and the Postgres endpoints are:

```
Write:  <CNPG_CLUSTER_NAME>-pooler-rw.<CNPG_NAMESPACE>.svc.cluster.local:5432
Read:   <CNPG_CLUSTER_NAME>-ro.<CNPG_NAMESPACE>.svc.cluster.local:5432
```

## Single source of truth: config.env

All tunables live in `config.env`. Templates (`*.tmpl`) derive their values via `envsubst`. Change a value, re-run the relevant script, the templates re-render.

Derivation chain:

```
config.env
   |
   +-- clouds.yaml.tmpl           -> rendered -> base64 -> embedded in cluster-template.yaml
   +-- cloud.conf.tmpl            -> rendered -> cloud-config Secret in workload cluster
   +-- cluster-template.yaml.tmpl -> rendered -> kubectl apply (CAPO resources)
   +-- manifests/cnpg-cluster.yaml.tmpl -> rendered -> kubectl apply (CNPG Cluster CR)
```

For multiple environments, copy and override:

```bash
cp config.env config.prod.env
vim config.prod.env
CONFIG_FILE=config.prod.env ./create-cluster.sh
```

The `.gitignore` excludes `config.*.env` so real credentials never land in git.

## OpenStack prerequisites

| Resource | Who creates it | Notes |
|---|---|---|
| Glance image (kubeadm-ready) | Cloud admin | Name must match `IMAGE_NAME`. Build with [image-builder](https://image-builder.sigs.k8s.io/capi/providers/openstack). |
| External network | Cloud admin | UUID goes in `EXTERNAL_NETWORK_ID` - run `openstack network list --external` |
| Flavors | `bootstrap-openstack-resources.sh` | Defaults: 2 vCPU / 4 GiB / 20 GB |
| SSH keypair | `bootstrap-openstack-resources.sh` | Generates locally, uploads public half |
| Octavia (load-balancer) | Cloud admin | Required for the kube-apiserver LB |
| Cinder (block storage) | Cloud admin | Backend for PVCs |
| Quota | Cloud admin | >= 3 VMs, >= 6 vCPU, >= 12 GB RAM, >= 30 GB volumes, >= 1 LB |

## Cilium notes

Default install uses VXLAN tunneling (works on any OpenStack network) and runs alongside kube-proxy. To switch to pure-eBPF mode with kube-proxy disabled, set in `config.env`:

```bash
CILIUM_KUBE_PROXY_REPLACEMENT=true
CILIUM_TUNNEL_PROTOCOL=disabled     # requires routable pod CIDR
```

Hubble observability is enabled by default (set `CILIUM_HUBBLE_ENABLED=false` to disable).

## CNPG notes

The rendered `cnpg-cluster.yaml` declares:
- 3 Postgres instances, sync replication ANY 1 (RPO=0 within region for committed transactions)
- Required pod anti-affinity - replicas cannot co-locate on one node
- PgBouncer Pooler with 2 replicas for the write path
- Resource requests/limits from `config.env`

Failover test:

```bash
export KUBECONFIG=/tmp/CLUSTER_NAME-kubeconfig
kubectl cnpg status CNPG_CLUSTER_NAME -n CNPG_NAMESPACE
kubectl delete pod CNPG_CLUSTER_NAME-1 -n CNPG_NAMESPACE
# Watch failover to another replica
```

## License

MIT.
