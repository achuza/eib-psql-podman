# Edge Image Builder - PostgreSQL HA Lab

Build a customized SUSE Linux Micro image that boots a 3-node k3s edge cluster with **CloudNativePG-managed HA PostgreSQL 18** as the headline workload, using the [SUSE Edge Image Builder](https://github.com/suse-edge/edge-image-builder).

This lab is a PostgreSQL-focused variant of the broader EIB stack: same edge management substrate (Rancher + Longhorn), but the data tier is the point.

---

## Available Configurations

| Configuration | Description | EIB Version | Base OS |
|---------------|-------------|-------------|---------|
| **rancher-3node** | 3-node k3s cluster running a CloudNativePG operator + 3-instance SUSE PostgreSQL 18 HA cluster, on Longhorn replicated storage, managed by Rancher. | 1.3 | SL Micro 6.2 |

### Database Stack

- **Operator**: CloudNativePG 0.28.2 (chart) / CNPG operator image 1.29.1
- **Engine**: SUSE PostgreSQL 18 (`registry.suse.com/suse/postgres:18`)
- **Cluster name**: `suse-psql` in namespace `db-production`
- **Topology**: 3 instances, preferred pod anti-affinity by hostname
- **Replication**: `minSyncReplicas: 1`, `maxSyncReplicas: 1`
- **Storage**: 20 GiB per instance, `longhorn-replicated-2` storage class
- **External access**: `suse-psql-external` `LoadBalancer` service (read-write)
- **Pod security**: non-root (uid/gid 999)
- **Embedded images**: bundled in the image so the cluster can come up air-gapped

The cluster manifest lives at `rancher-3node/kubernetes/manifests/02-postgres-cluster.yaml` — edit it to change instance count, storage size, resource limits, or sync replica policy.

### Supporting Stack

- **Kubernetes**: k3s v1.34.8+k3s1
- **Management**: Rancher 2.13.2 (with cert-manager 1.14.2)
- **Storage**: Longhorn 1.11.1 (chart 109.3.0+up1.11.1) — backing CNPG volumes
- **AI**: Rancher AI Agent 0.1.0 + Rancher AI UI Extension 0.1.15
- **IIoT**: Ignition by Inductive Automation 0.2.0
- **Virtualization** *(optional, disabled by default)*: KubeVirt 0.6.0 + CDI + Dashboard — commented out in `eib-config.yaml`; uncomment those chart blocks (and the `suse-edge` repository) to enable.
- **Security** *(optional, disabled by default)*: NeuVector 2.8.10 — likewise commented out.

---

## Prerequisites

### Base Images

- [SL Micro 6.2 ISO](https://www.suse.com/download/sle-micro/)
  - `SL-Micro.aarch64-6.2-Default-SelfInstall-GM.install.iso`

### Required Tools

- **[Podman](https://podman.io/)** — Container runtime (required for building images)
- **[UTM](https://mac.getutm.app/)** — VM host for macOS (optional, for local testing)
- **[Ollama](https://ollama.com/)** — Local LLM runtime (optional, only if you exercise the Rancher AI extension)

---

## System Setup (MacBook)

### 1. Install Podman

```bash
brew install podman
podman machine init --cpus 6 --memory 8192 --disk-size 100
podman machine start
```

### 2. Pull Edge Image Builder

```bash
podman pull registry.suse.com/edge/3.5/edge-image-builder:1.3.2
```

### 3. Install UTM

```bash
brew install utm
```

---

## Building the Image

```bash
cd rancher-3node
mkdir base-images
mv ~/Downloads/SL-Micro.aarch64-6.2-Default-SelfInstall-GM.install.iso \
   base-images/SL-Micro.aarch64-6.2-Default-SelfInstall-GM.install.iso
```

Add your SUSE registration code to `eib-config.yaml`:

```yaml
operatingSystem:
  packages:
    sccRegistrationCode: YOUR-REGISTRATION-CODE-HERE
```

Build:

```bash
podman run --privileged --rm -it \
  -v $(pwd):/eib \
  registry.suse.com/edge/3.5/edge-image-builder:1.3.2 \
  build --definition-file eib-config.yaml
```

Output: `rancher-3node-aarch64-6.2.iso`.

---

## Deployment

### UTM (macOS)

Create three VMs (one per node) using the built ISO. Recommended per node:

- **Memory**: 8192 MB
- **CPU**: 4–8 cores
- **Storage**: 100 GB
- **Network**: shared (UTM default is `192.168.64.x`); set each node's MAC to match the config

### Network

- **API VIP**: `192.168.64.10`
- **API host**: `192.168.64.10.sslip.io`

---

## Working with the PostgreSQL Cluster

Once all three nodes are up and the cluster has settled (5–10 minutes after first boot), the CloudNativePG cluster will reconcile.

### Verify the cluster

```bash
kubectl get cluster -n db-production
kubectl get pods -n db-production -l cnpg.io/cluster=suse-psql
kubectl get pvc -n db-production
```

You should see three pods (`suse-psql-1`, `suse-psql-2`, `suse-psql-3`) with one primary and two replicas.

### Connect from inside the cluster

```bash
kubectl get svc -n db-production
# suse-psql-rw   ClusterIP — read-write to current primary
# suse-psql-ro   ClusterIP — read-only to replicas
# suse-psql-r    ClusterIP — round-robin reads across all instances
```

### Connect from outside the cluster

The `suse-psql-external` `LoadBalancer` service is provisioned for external R/W access:

```bash
kubectl get svc -n db-production suse-psql-external
```

Use the assigned external IP (Longhorn/MetalLB will allocate from the configured pool — see `rancher-3node/kubernetes/manifests/postgres-ippool-l2adv.yaml`).

### Retrieve the superuser credentials

CNPG generates a `Secret` named `suse-psql-superuser`:

```bash
kubectl get secret -n db-production suse-psql-superuser \
  -o jsonpath='{.data.password}' | base64 -d
```

### Inspect cluster status with the cnpg plugin

```bash
kubectl cnpg status suse-psql -n db-production
```

(Install the [cnpg kubectl plugin](https://cloudnative-pg.io/documentation/current/kubectl-plugin/) first if you don't have it.)

### Accessing Rancher

```bash
kubectl get secret --namespace cattle-system bootstrap-secret \
  -o go-template='{{.data.bootstrapPassword|base64decode}}{{"\n"}}'
```

Then browse to `https://192.168.64.10.sslip.io`.

---

## Customization

### Scale the PostgreSQL cluster

Edit `rancher-3node/kubernetes/manifests/02-postgres-cluster.yaml`:

```yaml
spec:
  instances: 5         # add replicas
  storage:
    size: 100Gi        # bigger volumes
  resources:
    requests:
      memory: "2Gi"
      cpu: "1"
    limits:
      memory: "8Gi"
```

CNPG will reconcile rolling.

### Use a different Postgres image

Swap `spec.imageName` to any CNPG-compatible image (e.g., a different SUSE Postgres tag, or upstream `ghcr.io/cloudnative-pg/postgresql`). Don't forget to add it to `embeddedArtifactRegistry.images` in `eib-config.yaml` if you want it bundled into the ISO.

### Change the storage class

The default is `longhorn-replicated-2` (2 replicas). Switch `storage.storageClass` to `longhorn-replicated-3` for stronger durability at the cost of capacity. The available classes are defined in `rancher-3node/kubernetes/manifests/01-longhorn-storageclass.yaml`.

### Adjust Helm charts

Modify `kubernetes.helm.charts` in `eib-config.yaml`. Each entry needs `name`, `version`, `repositoryName`, `targetNamespace`.

### Change Kubernetes version

```yaml
kubernetes:
  version: v1.34.8+k3s1
```

See [k3s releases](https://github.com/k3s-io/k3s/releases).

---

## Troubleshooting

### Build failures

- **"No space left on device"** — increase Podman disk: `podman machine rm && podman machine init --cpus 6 --memory 8192 --disk-size 100`
- **"Permission denied"** — make sure `podman run` includes `--privileged`
- **Package install failures** — verify your SCC registration code

### PostgreSQL cluster won't start

- Check operator logs: `kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg`
- Check cluster events: `kubectl describe cluster suse-psql -n db-production`
- Check PVCs are bound: `kubectl get pvc -n db-production` (Longhorn must be healthy)
- Verify Longhorn nodes: `kubectl get nodes.longhorn.io -n longhorn-system`

### LoadBalancer service stuck pending

- The IP pool / L2 advertisement manifests (`postgres-ippool-l2adv.yaml`) must apply successfully. Check MetalLB / Longhorn LB controller logs.

---

## Resources

- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/)
- [SUSE PostgreSQL Container](https://registry.suse.com/suse/postgres)
- [Edge Image Builder](https://github.com/suse-edge/edge-image-builder)
- [SUSE Linux Micro Downloads](https://www.suse.com/download/sle-micro/)
- [Rancher Documentation](https://ranchermanager.docs.rancher.com/)
- [Longhorn Documentation](https://longhorn.io/docs/)
- [k3s Documentation](https://docs.k3s.io/)
