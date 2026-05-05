# Plan: DPU-Based Tenant-Isolated Cluster-as-a-Service in OSAC

## Context

**Problem:** OSAC currently provisions hosted clusters on bare metal using ESI or Netris network backends, but lacks support for DPU-backed workers with per-tenant network isolation enforced at the hardware level (on the SmartNIC itself).

**Goal:** Allow the fulfillment service to create a hosted cluster where:
- The control plane runs on the hub (via HyperShift)
- Worker nodes are DPU-equipped bare metal nodes
- Each worker's DPU is configured via the DPF operator to route data traffic into an isolated tenant network
- Workers from different tenants cannot communicate, even if they share a physical worker pool

**Key challenge:** Reconfiguring a DPU's route to isolate a worker may cause the hub to lose connectivity to that worker.

---

## Component Glossary

| Component | What it is |
|-----------|-----------|
| **OSAC** | Self-service platform for provisioning OpenShift clusters and VMs through a governed API |
| **Fulfillment Service** | REST/gRPC API that receives user requests for clusters and dispatches them to the operator |
| **OSAC Operator** | Kubernetes controller that watches CRDs (ClusterOrder, Tenant, etc.) and triggers AAP jobs |
| **AAP** | Ansible Automation Platform -- runs playbooks that create/delete actual infrastructure |
| **HyperShift** | Runs an OpenShift cluster's control plane as pods on a "hub" cluster; workers can be anywhere |
| **HostedCluster** | CRD representing a cluster whose control plane is hosted on the hub |
| **NodePool** | CRD defining how many workers belong to a HostedCluster |
| **MCE** | Multicluster Engine operator -- includes HyperShift and the assisted-service for bare metal discovery |
| **Agent** | A bare metal node that booted a discovery ISO, registered with the hub, and waits to be assigned |
| **InfraEnv** | CRD that generates the discovery ISO agents boot from |
| **DPU** | Data Processing Unit -- a SmartNIC (e.g. NVIDIA BlueField) with its own ARM processor that handles networking in hardware, offloading it from the host CPU |
| **DPF Operator** | NVIDIA operator that manages DPU configuration via CRDs (BFB, DPUSet, DPUServiceConfiguration) |
| **NVIDIA Air** | Cloud-based network simulation lab -- virtual DPUs, switches, and hosts for testing without hardware |
| **Tenant** | OSAC CRD representing an isolated namespace with its own network and storage boundaries |
| **VirtualNetwork** | OSAC CRD for a logical network grouping (like a VPC) |
| **Subnet** | OSAC CRD that creates a namespace + ClusterUserDefinedNetwork for L2 isolation |
| **CUDN** | ClusterUserDefinedNetwork -- OVN-Kubernetes CRD provisioning an isolated L2 overlay network |
| **NMStateConfig** | CRD that configures network interfaces (IPs, routes, VLANs) on bare metal nodes during install |
| **`network_steps_collection`** | OSAC's pluggable backend selector -- points to the Ansible collection providing `cluster_infra` and `external_access` roles |

---

## Networking Concepts (beginner-friendly)

| Concept | Explanation |
|---------|------------|
| **VLAN** | Tags network packets with an ID so one physical cable can carry multiple isolated networks -- devices with different VLAN IDs can't talk to each other |
| **VRF** | Creates separate routing tables on one device so it can participate in multiple networks simultaneously without them leaking into each other |
| **Dual-homing** | A node with two network connections -- one for management (hub always reaches it) and one for data (reconfigured per tenant) |
| **BGP** | Protocol that tells routers "I can reach network X" -- used to advertise service IPs from hosted clusters to the physical network |
| **L2 isolation** | Network isolation at the Ethernet frame level -- isolated devices can't see each other's traffic even on the same switch |
| **Konnectivity** | A tunnel that workers open back to the hub control plane -- survives network changes because the worker initiates it |

---

## Step-by-Step Plan

### Phase 1: Learn the Fundamentals

**OSAC Architecture (summaries instead of reading each file):**

| # | Step |
|---|------|
| 1 | **OSAC platform overview:** Users call the fulfillment-service REST API to order clusters/VMs -> the osac-operator watches CRDs and triggers AAP jobs -> AAP playbooks create the actual infrastructure (HostedClusters, networking, agents). Three components, one pipeline. |
| 2 | **OSAC CLI:** The `osac` command is a thin wrapper around the fulfillment API -- `osac create cluster-order` sends a gRPC request that creates a ClusterOrder CRD on the hub, which the operator picks up. |
| 3 | **osac-operator:** Runs two controllers per CRD -- a "resource controller" that watches CRDs and triggers AAP to provision infrastructure, and a "feedback controller" that polls AAP/fulfillment-service to sync status back. CRDs: ClusterOrder, Tenant, VirtualNetwork, Subnet, SecurityGroup, PublicIPPool, ComputeInstance. |
| 4 | **osac-aap:** Ansible playbooks organized as "template roles" (e.g. `ocp_4_17_small` for clusters, `cudn_net` for networking). The key abstraction is `network_steps_collection` -- a variable pointing to a pluggable backend (e.g. `massopencloud.steps`, `nico.steps`, `netris.steps`) that provides `cluster_infra` and `external_access` roles. Adding a new backend = adding a new collection. |
| 5 | Read NVIDIA's HyperShift docs to understand how the control plane runs as pods on the hub while workers run elsewhere | #FIXME: hypershift isn't an NVIDIA thing. It is a redhat product - summerize it in one line instead of asking me to read.
| 6 | Read NVIDIA BlueField DPU docs to understand the ARM processor on the NIC, how it sits in the data path, and how the DPF operator controls it via CRDs | #FIXME: summerize it in one line instead of asking me to read.
| 7 | Read the DPF Operator docs focusing on the CRDs: BFB (boot image), DPUSet (grouping), DPUServiceConfiguration (network config) | #FIXME: summerize it in one line instead of asking me to read.

### Phase 2: Understand the Current Codebase

**Key flows and patterns (summaries):**

| # | Step |
|---|------|
| 8 | **Cluster creation flow:** `ClusterOrder` CRD created -> operator's `clusterorder_controller.go` detects it -> triggers AAP job template `osac-create-hosted-cluster` -> runs template role `ocp_4_17_small` which executes a 7-step pipeline. |
| 9 | **The 7-step pipeline** (`ocp_4_17_small/tasks/install.yaml`): (1) pre-install hook, (2) create HostedCluster + NodePool CRDs on hub, (3) create cluster infrastructure via `{{ network_steps_collection }}.cluster_infra` (this is the pluggable part), (4) configure external access (DNS, ingress), (5) retrieve admin kubeconfig, (6) wait for cluster operators, (7) post-install hook. Steps 3-4 are what the DPF backend needs to implement. |
| 10 | **Backend delegation:** `cluster_infra/tasks/create.yaml` does `include_role: {{ network_steps_collection }}.cluster_infra` -- the actual backend is selected by the `NETWORK_STEPS_COLLECTION` env var. This is the exact extension point for DPF. |
| 11 | **NICo backend as reference** (`nico.steps`): Creates a VPC in NVIDIA's bare-metal manager, provisions DPU instances, waits for agents to register via assisted-installer, labels/approves agents for the NodePool, sets up MetalLB for service IPs. This is the closest existing pattern to what DPF integration will look like. |
| 12 | **Tenant model:** A Tenant CRD maps to a namespace + StorageClass on the target cluster. The tenant controller watches until both exist and sets the tenant to Ready. OVN-Kubernetes UserDefinedNetwork provides L2 isolation per tenant namespace. |
| 13 | **NMStateConfig:** Templates in `nmstate_config/templates/default_static.yaml.j2` configure bare metal node networking during installation -- they already support dual-interface configs with a persistent management route (`nmstate_mgmt_route_destination`/`nmstate_mgmt_route_gateway`), which is the exact pattern needed for DPU dual-homing. |

### Phase 3: Set Up the Environment

**Current status:** Deployment started on `hypershift1.nerc.mghpcc.org` in namespace `ybettan`. Most pods are running but there are two blockers.

| # | Step |
|---|------|
| 14 | ~~Provision an OpenShift 4.17+ hub cluster with cluster-admin access~~ **DONE** -- cluster is `hypershift1.nerc.mghpcc.org`, using impersonation (`--as system:admin`) for cluster-scoped operations |
| 15 | ~~Run `scripts/setup.sh` with `MCE_SERVICE=true`~~ **DONE** -- prerequisites installed, AAP bootstrap completed, most pods running |
| 16 | ~~Create kustomize overlay~~ **DONE** -- `overlays/ybettan/` exists with `license.zip`, `quay-pull-secret.json`, and configuration |
| 17 | **FIX BLOCKER 1 -- `ca-bundle` ConfigMap missing:** The `ca-bundle` Bundle CR is cluster-scoped and currently targets namespace `osac-iskornya` (another user overwrote it). Fix: `oc patch bundle ca-bundle --type=merge --as system:admin -p '{"spec":{"target":{"namespaceSelector":{"matchExpressions":[{"key":"kubernetes.io/metadata.name","operator":"In","values":["ybettan","osac-iskornya"]}]}}}}'` -- this makes trust-manager sync the CA cert to both namespaces. Multiple pods are stuck on this (`fulfillment-controller`, `authorino`, `fulfillment-grpc-server`, `fulfillment-rest-gateway`). |
| 18 | **FIX BLOCKER 2 -- `fulfillment-controller-credentials` secret missing:** The fulfillment-controller pod needs an OAuth2 client credentials secret with keys `client-id` and `client-secret` (used to authenticate the controller with Keycloak). Create a Keycloak client for the controller, then: `oc create secret generic fulfillment-controller-credentials --from-literal=client-id=<KEYCLOAK_CLIENT_ID> --from-literal=client-secret=<KEYCLOAK_CLIENT_SECRET> -n ybettan --as system:admin` |
| 19 | After fixing blockers, verify baseline: create a Tenant, VirtualNetwork + Subnet, and a ClusterOrder using the default backend to confirm end-to-end hosted cluster creation |

### Phase 4: Understand DPU/DPF and Where It Fits

**DPF operator status:** NOT installed on the cluster. Only the GPU operator is present (`gpu-operator-certified` in `nvidia-gpu-operator` namespace). No DPF/DPU-related CRDs exist.

| # | Step |
|---|------|
| 20 | Install the DPF operator on the cluster following NVIDIA's DPF operator installation guide (it is not currently installed -- only the GPU operator is present) |
| 21 | Apply a basic DPUServiceConfiguration CR to one DPU to learn the CRD schema and observe how it changes the DPU's forwarding behavior |
| 22 | Identify the specific DPF CR fields that control VLAN assignment and VRF routing on the DPU -- these are what you'll set per-tenant |

### Phase 5: Build the DPF Backend in OSAC

| # | Step |
|---|------|
| 23 | Create a new Ansible collection `dpf.steps` following the same structure as `nico.steps` -- implement `cluster_infra` and `external_access` roles |
| 24 | In `dpf.steps.cluster_infra/create.yaml`: identify available DPU agents, create DPUServiceConfiguration CRs to set tenant VLAN/VRF, wait for agents, label and approve them for the NodePool |
| 25 | In `dpf.steps.external_access/create.yaml`: wait for hosted cluster API, configure DNS, set up ingress (MetalLB + BGP) |
| 26 | Create a cluster template role (`ocp_4_17_dpu`) or extend `ocp_4_17_small` via the hook system to use the DPF backend |
| 27 | Add DPF-specific environment variables to AAP configuration: DPF API endpoint, tenant VLAN mappings, DPU resource class names, management interface name |
| 28 | Add corresponding `group_vars/all/dpf.yaml` defaults with `lookup('env', ...)` patterns |

### Phase 6: Implement Tenant-Isolated DPU Worker Provisioning

| # | Step |
|---|------|
| 29 | Extend the Tenant CRD (or use annotations) to carry DPU isolation parameters: target VLAN ID, VRF name, tenant network CIDR |
| 30 | In `dpf.steps.cluster_infra` create tasks, after selecting agents, apply a DPUServiceConfiguration CR per DPU worker that routes the data interface to the tenant's VLAN/VRF |
| 31 | Update the NMStateConfig template for DPU workers to configure dual-homing: management interface gets a static IP on the hub network, data interface joins the tenant VLAN |
| 32 | In `dpf.steps.cluster_infra` delete tasks: remove DPUServiceConfiguration CRs, restore DPU default routing, detach agents, clean up labels |
| 33 | Register the new template with AAP by adding `meta/osac.yaml` and running `playbook_osac_config_as_code.yml` |

### Phase 7: Address the Hub Connectivity Loss Problem

> **Root cause:** When the DPF operator reconfigures the DPU's route, the worker's IP/default-route changes and the hub (HyperShift control plane) can no longer reach the worker's kubelet.
>
> **Three channels that must survive:**
> - kubelet API (hub -> worker)
> - Konnectivity tunnel (worker -> hub)
> - Ignition config (hub -> worker during bootstrap)

| # | Step |
|---|------|
| 34 | **RECOMMENDED:** dual-homing with management VRF -- configure the DPU to keep a dedicated management interface in a separate VRF that always has a route back to the hub; only the data interface joins the tenant network |
| 35 | In the DPUServiceConfiguration CR, scope changes to data interfaces only -- do NOT touch the management representor port |
| 36 | In the NMStateConfig template, add a persistent management route (using the existing `nmstate_mgmt_route_destination` / `nmstate_mgmt_route_gateway` pattern) that survives DPU data-path reconfiguration |
| 37 | **SEQUENCING:** apply DPF tenant isolation only AFTER the worker has joined the hosted cluster and the Konnectivity tunnel is established -- the tunnel persists over the management interface |
| 38 | Add a readiness check after DPF reconfiguration: verify hub can still reach the worker's kubelet and the node shows Ready in the hosted cluster before proceeding to the next worker |

> **Alternative (if dual-homing isn't possible):** Deploy a gateway node dual-homed between hub and tenant networks that NATs/proxies HyperShift control traffic.

### Phase 8: Test with NVIDIA Air

| # | Step |
|---|------|
| 39 | Sign up for NVIDIA Air and create a simulation topology: one hub node, 2+ workers with simulated BlueField DPUs, leaf-spine switches |
| 40 | Install DPF operator in the simulation and apply DPUServiceConfiguration CRs to verify VLAN/VRF reconfiguration works |
| 41 | Simulate the connectivity loss: reconfigure a worker's DPU to a tenant VLAN and verify the hub loses connectivity -- confirms the problem exists |
| 42 | Apply your fix (dual-homing / management VRF) and verify the hub maintains connectivity after DPU reconfiguration |
| 43 | Run the full end-to-end: create a Tenant + ClusterOrder through the fulfillment API, verify the hosted cluster comes up with all workers Ready and tenant-isolated |

### Phase 9: Integration Testing

| # | Step |
|---|------|
| 44 | Create a ClusterOrder with `NETWORK_STEPS_COLLECTION=dpf.steps`, verify the hosted cluster reaches Ready with workers in the correct tenant VLAN |
| 45 | Test scale-up/down: add/remove workers and verify DPF CRs are created/cleaned up correctly |
| 46 | Test cluster deletion: verify all DPF CRs, DNS records, and agent labels are fully cleaned up |
| 47 | Test multi-tenant isolation: create two clusters in different tenants from the same worker pool and verify workers in tenant A cannot reach workers in tenant B |

---

## Critical Files

| File | Role |
|------|------|
| `base/osac-aap/.../osac/service/roles/cluster_infra/tasks/create.yaml` | Backend delegation point -- where `network_steps_collection` routes to the correct backend |
| `base/osac-aap/.../osac/templates/roles/ocp_4_17_small/tasks/install.yaml` | 7-step cluster creation pipeline (extend via hooks or duplicate for DPU) |
| `base/osac-aap/.../osac/service/roles/nmstate_config/templates/default_static.yaml.j2` | NMStateConfig template -- adapt for DPU dual-homing |
| `base/osac-aap/.../nico/steps/roles/cluster_infra/tasks/create.yaml` | NICo backend -- reference pattern for building the DPF backend |
| `base/osac-aap/group_vars/all/configuration.yaml` | Central config where `network_steps_collection` is defined -- extend with DPF vars |
| `base/osac-operator/api/v1alpha1/tenant_types.go` | Tenant CRD -- may need DPU isolation fields |
| `docs/network-backend.md` | Network backend docs -- add DPF section |
| `scripts/aap-configuration.sh` | AAP config script -- add DPF env var handling |

---

## Verification

1. Deploy OSAC with the new DPF backend on a cluster with DPU nodes (or NVIDIA Air simulation)
2. Create a tenant via `osac create tenant`
3. Create a cluster order via `osac create cluster-order` targeting the DPF-backed template
4. Verify the hosted cluster control plane comes up on the hub
5. Verify DPU workers join the hosted cluster with tenant-isolated networking
6. Verify hub maintains connectivity to workers throughout the process
7. Verify workers from different tenants cannot communicate at L2/L3
8. Verify clean deletion of all resources
