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

| # | Step |
|---|------|
| 1 | Read the OSAC installer README to understand the three core components (fulfillment-service, operator, AAP) and the installation flow |
| 2 | Read `OSAC-CLI-HOWTO.md` to understand how users order clusters and VMs through the CLI |
| 3 | Read the osac-operator's `CLAUDE.md` to learn the dual-controller pattern and the CRD list (ClusterOrder, Tenant, VirtualNetwork, etc.) |
| 4 | Read the osac-aap `CLAUDE.md` to learn the playbook structure, template roles, and the `network_steps_collection` pluggable backend pattern |
| 5 | Read NVIDIA's HyperShift docs to understand how the control plane runs as pods on the hub while workers run elsewhere |
| 6 | Read NVIDIA BlueField DPU docs to understand the ARM processor on the NIC, how it sits in the data path, and how the DPF operator controls it via CRDs |
| 7 | Read the DPF Operator docs focusing on the CRDs: BFB (boot image), DPUSet (grouping), DPUServiceConfiguration (network config) |

### Phase 2: Understand the Current Codebase

| # | Step |
|---|------|
| 8 | Trace the cluster creation flow: `ClusterOrder` CRD -> operator controller -> AAP job `osac-create-hosted-cluster` -> template role `ocp_4_17_small` |
| 9 | Read the `ocp_4_17_small` template install tasks to see the 7-step pipeline: pre-install, create hosted cluster, create cluster infra, configure external access, retrieve kubeconfig, wait for operators, post-install |
| 10 | Read `cluster_infra/tasks/create.yaml` to see how `{{ network_steps_collection }}.cluster_infra` delegates to the selected backend |
| 11 | Read the NICo backend (`nico.steps`) as the reference implementation -- it shows VPC creation, instance provisioning, agent matching, and MetalLB setup |
| 12 | Read the Tenant CRD types and controller to understand how tenants map to namespaces + storage classes with phase tracking |
| 13 | Read the NMStateConfig templates to see how bare metal node network interfaces are configured (dual-interface with management route preservation) |

### Phase 3: Set Up the Environment

| # | Step |
|---|------|
| 14 | Provision an OpenShift 4.17+ hub cluster with cluster-admin access |
| 15 | Run `scripts/setup.sh` with `MCE_SERVICE=true` to install all prerequisites (cert-manager, Keycloak, MCE/HyperShift, AAP) |
| 16 | Create your kustomize overlay (`overlays/<name>/`) by copying `overlays/development` and updating namespace, AAP URL, and secrets |
| 17 | Deploy OSAC and verify baseline works: create a Tenant, create a VirtualNetwork + Subnet, create a ClusterOrder using the default backend |

### Phase 4: Understand DPU/DPF and Where It Fits

| # | Step |
|---|------|
| 18 | Install the DPF operator on a cluster with BlueField DPUs (or use NVIDIA Air for simulation -- see Phase 8) |
| 19 | Apply a basic DPUServiceConfiguration CR to one DPU to learn the CRD schema and observe how it changes the DPU's forwarding behavior |
| 20 | Identify the specific DPF CR fields that control VLAN assignment and VRF routing on the DPU -- these are what you'll set per-tenant |

### Phase 5: Build the DPF Backend in OSAC

| # | Step |
|---|------|
| 21 | Create a new Ansible collection `dpf.steps` following the same structure as `nico.steps` -- implement `cluster_infra` and `external_access` roles |
| 22 | In `dpf.steps.cluster_infra/create.yaml`: identify available DPU agents, create DPUServiceConfiguration CRs to set tenant VLAN/VRF, wait for agents, label and approve them for the NodePool |
| 23 | In `dpf.steps.external_access/create.yaml`: wait for hosted cluster API, configure DNS, set up ingress (MetalLB + BGP) |
| 24 | Create a cluster template role (`ocp_4_17_dpu`) or extend `ocp_4_17_small` via the hook system to use the DPF backend |
| 25 | Add DPF-specific environment variables to AAP configuration: DPF API endpoint, tenant VLAN mappings, DPU resource class names, management interface name |
| 26 | Add corresponding `group_vars/all/dpf.yaml` defaults with `lookup('env', ...)` patterns |

### Phase 6: Implement Tenant-Isolated DPU Worker Provisioning

| # | Step |
|---|------|
| 27 | Extend the Tenant CRD (or use annotations) to carry DPU isolation parameters: target VLAN ID, VRF name, tenant network CIDR |
| 28 | In `dpf.steps.cluster_infra` create tasks, after selecting agents, apply a DPUServiceConfiguration CR per DPU worker that routes the data interface to the tenant's VLAN/VRF |
| 29 | Update the NMStateConfig template for DPU workers to configure dual-homing: management interface gets a static IP on the hub network, data interface joins the tenant VLAN |
| 30 | In `dpf.steps.cluster_infra` delete tasks: remove DPUServiceConfiguration CRs, restore DPU default routing, detach agents, clean up labels |
| 31 | Register the new template with AAP by adding `meta/osac.yaml` and running `playbook_osac_config_as_code.yml` |

### Phase 7: Address the Hub Connectivity Loss Problem

> **Root cause:** When the DPF operator reconfigures the DPU's route, the worker's IP/default-route changes and the hub (HyperShift control plane) can no longer reach the worker's kubelet.
>
> **Three channels that must survive:**
> - kubelet API (hub -> worker)
> - Konnectivity tunnel (worker -> hub)
> - Ignition config (hub -> worker during bootstrap)

| # | Step |
|---|------|
| 32 | **RECOMMENDED:** dual-homing with management VRF -- configure the DPU to keep a dedicated management interface in a separate VRF that always has a route back to the hub; only the data interface joins the tenant network |
| 33 | In the DPUServiceConfiguration CR, scope changes to data interfaces only -- do NOT touch the management representor port |
| 34 | In the NMStateConfig template, add a persistent management route (using the existing `nmstate_mgmt_route_destination` / `nmstate_mgmt_route_gateway` pattern) that survives DPU data-path reconfiguration |
| 35 | **SEQUENCING:** apply DPF tenant isolation only AFTER the worker has joined the hosted cluster and the Konnectivity tunnel is established -- the tunnel persists over the management interface |
| 36 | Add a readiness check after DPF reconfiguration: verify hub can still reach the worker's kubelet and the node shows Ready in the hosted cluster before proceeding to the next worker |

> **Alternative (if dual-homing isn't possible):** Deploy a gateway node dual-homed between hub and tenant networks that NATs/proxies HyperShift control traffic.

### Phase 8: Test with NVIDIA Air

| # | Step |
|---|------|
| 37 | Sign up for NVIDIA Air and create a simulation topology: one hub node, 2+ workers with simulated BlueField DPUs, leaf-spine switches |
| 38 | Install DPF operator in the simulation and apply DPUServiceConfiguration CRs to verify VLAN/VRF reconfiguration works |
| 39 | Simulate the connectivity loss: reconfigure a worker's DPU to a tenant VLAN and verify the hub loses connectivity -- confirms the problem exists |
| 40 | Apply your fix (dual-homing / management VRF) and verify the hub maintains connectivity after DPU reconfiguration |
| 41 | Run the full end-to-end: create a Tenant + ClusterOrder through the fulfillment API, verify the hosted cluster comes up with all workers Ready and tenant-isolated |

### Phase 9: Integration Testing

| # | Step |
|---|------|
| 42 | Create a ClusterOrder with `NETWORK_STEPS_COLLECTION=dpf.steps`, verify the hosted cluster reaches Ready with workers in the correct tenant VLAN |
| 43 | Test scale-up/down: add/remove workers and verify DPF CRs are created/cleaned up correctly |
| 44 | Test cluster deletion: verify all DPF CRs, DNS records, and agent labels are fully cleaned up |
| 45 | Test multi-tenant isolation: create two clusters in different tenants from the same worker pool and verify workers in tenant A cannot reach workers in tenant B |

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
