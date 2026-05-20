# Plan: DPU Workers in OCP, Then Tenant-Isolated Cluster-as-a-Service in OSAC

## Context

**Problem:** OSAC currently provisions hosted clusters on bare metal using ESI or Netris network backends. We want to add a new backend for servers equipped with NVIDIA BlueField DPUs in **Zero Trust mode** -- where the DPU (not the switch or a software gateway) becomes the enforcement point for tenant network isolation. The host is restricted and cannot bypass or reconfigure the network. A [Red Hat blog post](https://developers.redhat.com/articles/2025/03/20/dpu-enabled-networking-openshift-and-nvidia-dpf) demonstrates that the DPF operator can automate DPU provisioning with OpenShift (using Kamaji for hosted control planes), but **this has never been done in OSAC or with HyperShift specifically.** We need to solve this fundamental problem first before addressing multi-tenancy.

**Environment (provided, not deployed):** The environment will be given to us pre-deployed. It consists of:
- **Management cluster** (x86): Runs the HyperShift hosted control planes -- the "master nodes" of the DPU cluster run as containers on this cluster. Also hosts the DPF operator and supporting infrastructure.
- **DPU machine(s)**: Bare metal servers with NVIDIA BlueField DPUs in Zero Trust mode. These are supposed to become worker nodes in the hosted cluster, connecting back to the HyperShift control plane on the management cluster.

**Milestone 1 — DPU machine as OCP worker (this comes first):**
- Take a bare metal machine with a BlueField DPU from the provided environment
- Join it as a worker node to the HyperShift hosted cluster running on the management cluster
- The control plane can reach kubelet on the worker

**Milestone 2 — Multi-tenant isolation (only after Milestone 1 works):**
- Each worker's DPU is configured via DPUServiceConfiguration CRs to enforce per-tenant VLAN/VRF/EVPN VXLAN isolation
- Workers from different tenants cannot communicate, even if they share a physical worker pool

**Key challenges:**
- **(Milestone 1) Hub connectivity:** In Zero Trust mode, the host's only network interface (PF0) passes through the DPU. The 1G BMC/OOB port is for DPU management only, NOT host management. Sharon's lab testing confirmed that reverse NAT fails when trying to route ZT host traffic to ACM through the high-speed switch. A dual-homing or gateway solution is required.
- **(Milestone 2) No NAT/LB edge service:** Unlike Netris (which has SoftGates for NAT/LB at the fabric edge), the DPU architecture has no equivalent. External access design is an open problem.

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
| **DPF Operator** | NVIDIA operator (v25.10.0, deployed via Helm from NGC registry) that manages the full DPU lifecycle in Zero Trust mode. Key CRDs: DPFOperatorConfig, DPUCluster, DPUFlavor, BFB, DPUSet, DPUDeployment, DPUService, DPUServiceChain, DPUServiceConfiguration, DPUServiceIPAM |
| **DPUDeployment** | Top-level orchestration CR -- ties together BFB image, DPU flavor, services, and service chains into a single deployable unit |
| **DPUServiceConfiguration** | Per-DPU VLAN/VRF/BGP configuration via hostname pattern matching -- this is the CR that enforces per-tenant network isolation. Uses `hostnamePattern` with DPU serial numbers in `perDPUValuesYAML` |
| **DPUServiceIPAM** | IP address pool management for tenant networks -- allocates per-DPU /29 subnets from a tenant's CIDR |
| **DMS** | DPU Management Service -- agent pod that runs on each DPU host to flash BFB images and configure initial host-DPU networking (br-dpu bridge, rshim interface) |
| **Kamaji** | Lightweight hosted control plane project -- used in the Red Hat blog demo; our environment uses HyperShift instead, but both serve the same architectural role (running control plane as containers on the management cluster) |
| **HBN** | Host-Based Networking -- FRRouting-based BGP router running as a DaemonSet on DPU nodes; turns each DPU into a BGP peer with the ToR switch for EVPN VXLAN routing |
| **BareMetalPool / HostLease** | OSAC mechanism for allocating bare-metal workers -- cluster_infra acquires a HostLease from a BareMetalPool, same as existing backends |
| **SFC** | Service Function Chaining -- DPF mechanism to chain network services on the DPU in a defined pipeline order via DPUServiceChain CRs (e.g. OVN -> HBN -> physical uplinks) |
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
| **Out-of-band (OOB) / BMC port** | A 1G management port on the DPU used for DPU lifecycle management only -- Redfish API discovery, BFB image flashing, power cycling. This is NOT a host network interface and cannot carry kubelet or application traffic |
| **OVN-K DPU mode** | OVN-Kubernetes running on the DPU ARM cores instead of the host -- offloads overlay networking (Geneve tunnels, pod-to-pod traffic) to the DPU; workers need OVS disabled and the `k8s.ovn.org/dpu-host` label |
| **SR-IOV (`externallyManaged`)** | SR-IOV configured with `externallyManaged: true` so VF lifecycle is delegated to DPF rather than the SR-IOV operator -- pods use VFs on the host, DPU uses VF representors to manage their traffic |
| **rshim** | Host-side interface to the DPU ARM cores -- used for initial provisioning, flashing BFB images, and management communication between host and DPU |
| **br-dpu bridge** | OVS bridge created via NMState on the management NIC to provide connectivity between host and DPU during provisioning and ongoing management |
| **EVPN VXLAN** | Overlay tunneling protocol used by HBN to extend L2/L3 tenant networks across DPUs -- each tenant gets unique L2 VNI and L3 VNI (VXLAN Network Identifiers) so traffic from different tenants is isolated even when sharing the same physical fabric |
| **PF0** | The host's physical function (NIC) -- in Zero Trust mode, ALL host traffic passes through PF0 into the DPU; the host cannot see or change VLAN tags, which are managed by HBN inside the DPU |

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
| 5 | **HyperShift (Red Hat):** A Red Hat OpenShift feature that decouples the cluster control plane from workers -- the control plane (API server, etcd, controllers) runs as pods on the hub cluster, while worker nodes can be bare metal machines anywhere, connected back to the hub via Konnectivity tunnels. |
| 6 | **NVIDIA BlueField DPU:** An ARM-based processor embedded on a network card that intercepts all traffic between the host and the network switch -- it runs its own OS and can enforce networking policies (VLANs, VRFs, firewalling) in hardware without the host CPU knowing, making it the enforcement point for tenant isolation. |
| 7 | **DPF Operator (Zero Trust):** NVIDIA's Kubernetes operator (v25.10.0) for managing BlueField DPUs in Zero Trust mode. Key CRDs: DPUDeployment (top-level orchestration), DPUServiceConfiguration (per-DPU VLAN/VRF/BGP config), DPUServiceIPAM (IP pools), DPUService/DPUServiceChain (service deployment and chaining). DPU provisioning is multi-phase: Initialized -> BFBReady -> FWConfigured -> OSInstalled -> Rebooted -> Ready. See the [Red Hat blog](https://developers.redhat.com/articles/2025/03/20/dpu-enabled-networking-openshift-and-nvidia-dpf) and [NVIDIA DPF Zero Trust RDG](https://docs.nvidia.com/networking/display/public/sol/rdg+for+dpf+zero+trust+(dpf-zt)+with+hbn+dpu+service) for reference. |

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

### Phase 3: Connect to the Environment

**The environment is provided pre-deployed.** No cluster installation or OSAC deployment is needed. The environment consists of a management cluster (x86, running HyperShift control planes) and DPU machine(s) to be joined as workers.

| # | Step |
|---|------|
| 14 | **Obtain access credentials:** Get kubeconfig or login credentials for the management cluster. Verify access with `oc get nodes` and `oc get pods -A`. |
| 15 | **Map the environment architecture:** Identify the two logical clusters: (a) the management cluster running HyperShift hosted control planes + DPF operator, and (b) the hosted cluster whose workers will be DPU machines. Document access to both (kubeconfigs, API endpoints). |
| 16 | **Inventory existing DPF resources:** Check what DPF CRDs are already deployed: `oc get dpfoperatorconfigs,dpuclusters,dpuflavors,bfbs,dpusets,dpuservices,dpuservicechains -A`. Document the current state -- are DPUs already provisioned? Is a DPUCluster already running? |
| 17 | **Verify the DPU joining process (from blog prior art):** The Red Hat blog documents the automated flow: DPUSet specifies target hosts by label -> DPF operator creates DPU objects -> DMS pods flash BFB images -> host-DPU networking configured (br-dpu bridge, rshim) -> hosts and DPUs rebooted -> DPUs join the hosted cluster. Verify which of these steps have already occurred in the environment. |
| 18 | **Verify baseline cluster health:** Check that the management cluster's control plane pods are running, HyperShift operator is healthy, and if a hosted cluster already exists, check its status with `oc get hostedclusters -A`. |

---

## ===== MILESTONE 1: DPU Machine as OCP Worker =====

### Prior Art

A [Red Hat blog post](https://developers.redhat.com/articles/2025/03/20/dpu-enabled-networking-openshift-and-nvidia-dpf) ("DPU-Enabled Networking with OpenShift and NVIDIA DPF") documents a working DPU+OpenShift deployment with the same "tale of two clusters" architecture:
- **Management cluster** (x86): runs application workloads + DPF operator + hosted control plane (Kamaji in the blog; we use HyperShift)
- **DPU cluster**: runs on the 16 ARM Cortex-A78 cores of each BlueField-3 DPU, dedicated to networking services (OVN-K in DPU mode, HBN, SFC)
- The DPF operator automates the full lifecycle: BFB image flashing via DMS pods, host-DPU networking (br-dpu bridge, rshim), reboot, and automatic joining of DPUs to the hosted cluster as worker nodes
- Workers in the management cluster have OVS disabled and use SR-IOV VFs for networking, with `externallyManaged: true` delegating VF management to DPF
- Achieved near-line-rate performance: 383 Gb/sec RDMA, 355 Gb/sec TCP on dual 200GbE BlueField-3 ports

### Phase 4: Validate Architecture Against Our Environment

The blog confirms DPU+OpenShift works end-to-end, but uses Kamaji for hosted control planes. Our environment uses HyperShift. This phase validates assumptions and identifies differences.

| # | Step |
|---|------|
| 19 | **ANSWERED: Can a DPU machine join OCP as a worker?** YES. The Red Hat blog demonstrates the full flow with DPF operator automation. Our environment follows the same "tale of two clusters" pattern but uses HyperShift instead of Kamaji for the hosted control plane. |
| 20 | **Identify HyperShift vs. Kamaji differences:** The blog uses Kamaji's `TenantControlPlane` CR. Our environment uses HyperShift's `HostedCluster` CR. Both run control planes as containers on the management cluster. Investigate: does `DPFOperatorConfig` support HyperShift as a `hostedClusterType`? If not, what adaptation is needed? |
| 21 | **Map DPU network topology in our environment:** In Zero Trust mode, the host sees only PF0 -- all traffic passes through the DPU. **Before tenant isolation, PF0 traffic flows through the DPU in default routing mode and reaches the management network normally** -- the host CAN talk to the control plane at this stage. The 1G BMC/OOB port is for **DPU lifecycle management only** (Redfish discovery, BFB flashing, power cycling) -- it is NOT a host network interface and cannot carry kubelet traffic. Verify rshim connectivity and br-dpu bridge state. |
| 22 | **Understand hub connectivity constraint (CRITICAL):** Sharon's lab testing confirmed: reverse NAT fails when trying to route ZT host traffic to ACM through the high-speed switch. The worker's only interface (PF0) gets placed into a tenant VLAN/VRF with no route back to the management/ACM network. A dual-homing or gateway solution is required before any tenant isolation can work. See Sharon's lab doc for details. |
| 23 | **Check DPF operator status and version:** Verify the DPF operator (v25.10.0) is installed on the management cluster and confirm the CRDs match the expected API surface: DPFOperatorConfig, DPUCluster, DPUFlavor, BFB, DPUSet, DPUDeployment, DPUService, DPUServiceChain, DPUServiceConfiguration, DPUServiceIPAM. |

### Phase 5: Manual POC — DPU Machine as OCP Worker

Do everything manually (no OSAC, no automation) to prove the concept works in our environment.

| # | Step |
|---|------|
| 24 | **Identify the DPU machine(s) in the environment:** Document the hardware: NIC model (BlueField-3 expected), number of ports, OOB management port, host-visible interfaces. Check if DPUs are already flashed or need BFB provisioning. |
| 25 | **Use the management cluster's HyperShift control plane:** Create a HostedCluster + NodePool on the management cluster (or use an existing one) as the target for the DPU worker to join. |
| 26 | **Install OCP worker on the DPU machine:** Try the most straightforward method first (assisted installer discovery ISO). If that doesn't work, try PXE or manual RHCOS install. Document what works and what doesn't. |
| 27 | **Join the worker to the hosted cluster:** Get the DPU machine to register and join as a worker node of the HyperShift hosted cluster. Verify it shows up as a Node. |
| 28 | **Verify kubelet reachability:** Confirm the control plane can reach the kubelet on the worker via the OOB port. Test `oc get nodes`, `oc debug node/<dpu-node>`, pod scheduling on the DPU worker. |
| 29 | **Document the working setup:** Record the exact network topology, interface names, routes, and any special configuration needed. This becomes the blueprint for OSAC integration. |

### Phase 6: Integrate DPU Workers into OSAC

Only after the manual POC succeeds. Build the `dpf.steps` backend to automate what was done manually — **no tenant isolation yet.**

| # | Step |
|---|------|
| 30 | Create a new Ansible collection `dpf.steps` following the same structure as `nico.steps` -- implement `cluster_infra` and `external_access` roles |
| 31 | In `dpf.steps.cluster_infra/create.yaml`: allocate workers via BareMetalPool/HostLease (same as existing backends), discover DPU serial numbers for each worker (via BMC Redfish query), automate DPU provisioning via DPUSet CRs (label-based host matching), BFB image flashing via DMS, NMStateConfig for br-dpu bridge and DPU interfaces, agent labeling and approval for the NodePool |
| 32 | In `dpf.steps.external_access/create.yaml`: wait for hosted cluster API, configure DNS, set up ingress |
| 33 | Create a cluster template role (`ocp_4_17_dpu`) or extend `ocp_4_17_small` via the hook system to use the DPF backend |
| 34 | Add DPF-specific environment variables to AAP configuration and `group_vars` |
| 35 | In `dpf.steps.cluster_infra` delete tasks: detach agents, clean up labels, remove DPUSet/BFB CRs and any DPU-specific configuration |
| 36 | Register the new template with AAP by adding `meta/osac.yaml` and running `playbook_osac_config_as_code.yml` |
| 37 | Test end-to-end through OSAC: `osac create cluster-order` with the DPF backend, verify the hosted cluster comes up with DPU workers |

---

## ===== MILESTONE 2: Multi-Tenant DPU Isolation =====

### Phase 7: Add Tenant-Isolated DPU Worker Provisioning

Only after Milestone 1 is complete. Layer per-tenant network isolation on top of the working DPU backend.

**Sub-phase 7a: Learn DPF operator CRDs**

| # | Step |
|---|------|
| 38 | Install the DPF operator on the cluster (if not already installed) -- v25.10.0 via Helm chart from NGC registry |
| 39 | Apply a basic DPUServiceConfiguration CR to one DPU to learn per-tenant config: VLAN ID, VRF name, L2/L3 VNI, BGP AS number, IPAM pool. Also apply DPUService (deploys OVN-K, HBN) and DPUServiceChain (ensures all traffic traverses HBN) to understand the service chaining model. |
| 40 | Validate the DPUServiceConfiguration schema against NVIDIA's DPF Zero Trust RDG. Key fields: `hostnamePattern` for DPU targeting, `perDPUValuesYAML` for per-DPU serial number matching, VLAN/VRF/VNI assignment. Also understand DPUServiceIPAM for per-DPU /29 IPAM allocations. |

**Sub-phase 7b: Implement tenant isolation**

| # | Step |
|---|------|
| 41 | Extend the Tenant CRD (or use annotations) to carry DPU isolation parameters: VLAN ID, VRF name, L2 VNI, L3 VNI, BGP AS number, tenant network CIDR, DPUServiceIPAM pool reference |
| 42 | In `dpf.steps.cluster_infra` create tasks, after workers join, create/update a DPUServiceConfiguration CR per tenant -- uses `hostnamePattern` to target specific DPUs by serial number (discovered via BMC Redfish) and `perDPUValuesYAML` for per-DPU config. This routes the data interface (PF0) to the tenant's VLAN/VRF with EVPN VXLAN encapsulation. |
| 43 | Update the NMStateConfig template for DPU workers to configure dual-homing: management interface gets a static IP on the hub network (via br-dpu bridge), data interface joins the tenant VLAN |
| 44 | In `dpf.steps.cluster_infra` delete tasks: remove DPUServiceConfiguration CRs for the tenant, restore DPU to default/unassigned state, release workers back to BareMetalPool |

**Sub-phase 7c: Address the hub connectivity loss problem**

> **Root cause:** Before tenant isolation, the host communicates normally via PF0 -> DPU -> physical network (default routing mode). But when the DPF operator applies a DPUServiceConfiguration to enforce tenant isolation, PF0 gets placed into a tenant VLAN/VRF which does NOT have routing back to the management/ACM network. The hub (HyperShift control plane) can no longer reach the worker's kubelet.
>
> **IMPORTANT:** The host has NO separate management NIC. The 1G BMC/OOB port is for DPU lifecycle management only (Redfish, BFB flashing, power cycling) -- it cannot carry kubelet traffic. All host traffic goes through PF0 -> DPU, so the solution must work within that path.
>
> **Sharon's lab findings:** Tried adding a VRF on the high-speed switch with route leaking (import RED VRF routes into default VRF). Ping from DPU to ACM hypervisor worked. SNAT worked outbound, but **reverse NAT FAILED** -- reply packets did not get reverse-SNATed back to the overlay IP. **BLOCKER: "No success to connect to ACM through high speed ZT host".**
>
> **Three channels that must survive:**
> - kubelet API (hub -> worker)
> - Konnectivity tunnel (worker -> hub)
> - Ignition config (hub -> worker during bootstrap)

| # | Step |
|---|------|
| 45 | **RECOMMENDED:** dual-homing with management VRF -- configure the DPU to keep a dedicated management interface in a separate VRF that always has a route back to the hub; only the data interface joins the tenant network. **Key question:** Can HBN support multiple VRFs on a single DPU -- one management, one tenant? |
| 46 | In the DPUServiceConfiguration CR, scope changes to data interfaces only -- do NOT touch the management representor port. **Key question:** Does DPUServiceConfiguration allow scoping to specific interfaces without touching management? |
| 47 | In the NMStateConfig template, add a persistent management route (using the existing `nmstate_mgmt_route_destination` / `nmstate_mgmt_route_gateway` pattern) that survives DPU data-path reconfiguration |
| 48 | **SEQUENCING:** apply DPF tenant isolation only AFTER the worker has joined the hosted cluster and the Konnectivity tunnel is established -- the tunnel persists over the management interface |
| 49 | Add a readiness check after DPF reconfiguration: verify hub can still reach the worker's kubelet and the node shows Ready in the hosted cluster before proceeding to the next worker |

> **Alternative (if dual-homing isn't possible):** Deploy a gateway node dual-homed between hub and tenant networks that NATs/proxies HyperShift control traffic.

### Phase 8: Test Basic DPU Worker Integration (Milestone 1)

| # | Step |
|---|------|
| 50 | Create a ClusterOrder with `NETWORK_STEPS_COLLECTION=dpf.steps`, verify the hosted cluster reaches Ready with DPU workers |
| 51 | Test scale-up/down: add/remove DPU workers and verify agents are managed correctly |
| 52 | Test cluster deletion: verify all resources are cleaned up |

### Phase 9: Test Multi-Tenant Isolation (Milestone 2)

| # | Step |
|---|------|
| 53 | Create a ClusterOrder with `NETWORK_STEPS_COLLECTION=dpf.steps` and tenant VLAN/VRF parameters, verify workers join with correct isolation |
| 54 | Create two clusters in different tenants from the same DPU worker pool, verify workers in tenant A cannot reach workers in tenant B at L2/L3 |
| 55 | Test tenant deletion: verify DPUServiceConfiguration CRs are removed, DPU restored to default state, workers released back to BareMetalPool, all resources cleaned up |

---

## Known Blockers and Gaps

| # | Blocker | Severity | Details |
|---|---------|----------|---------|
| B1 | **Hub connectivity in Zero Trust mode** | CRITICAL | Sharon's lab confirmed reverse NAT fails. ZT hosts have no separate management NIC -- the 1G BMC/OOB is for DPU only. Dual-homing or gateway solution required before any tenant isolation works. |
| B2 | **No NAT/LB edge service** | HIGH | Netris has SoftGates for NAT/LB at fabric edge. DPU architecture has no equivalent. Options: (a) ToR switch NAT (limited Cumulus support), (b) dedicated SNAT node/pod, (c) external firewall (pfSense), (d) dedicated L4LB at fabric edge. Must be designed. |
| B3 | **DPF operator not installed** | MEDIUM | No DPF CRDs exist in the environment yet. Cannot validate CR schemas until deployed (v25.10.0 via Helm from NGC). |
| B4 | **Manual steps in DPU provisioning** | MEDIUM | DPU provisioning requires manual host power cycle after DPU reboot AND manual annotation to proceed past the NodeEffect hold point. May require IPMI/BMC integration for automation. |
| B5 | **DPUServiceConfiguration schema unvalidated** | MEDIUM | Exact fields for per-DPU VLAN/VRF assignment documented in NVIDIA RDG but not validated in our environment. Experimental learning step required. |
| B6 | **DPU serial number discovery** | LOW | Need mapping from worker/HostLease to DPU serial number for `hostnamePattern` matching in DPUServiceConfiguration. Likely via BMC Redfish query. |

---

## Critical Files

| File | Role |
|------|------|
| `base/osac-aap/.../osac/service/roles/cluster_infra/tasks/create.yaml` | Backend delegation point -- where `network_steps_collection` routes to the correct backend |
| `base/osac-aap/.../osac/templates/roles/ocp_4_17_small/tasks/install.yaml` | 7-step cluster creation pipeline (extend via hooks or duplicate for DPU) |
| `base/osac-aap/.../osac/service/roles/nmstate_config/templates/default_static.yaml.j2` | NMStateConfig template -- adapt for DPU dual-homing |
| `base/osac-aap/.../nico/steps/roles/cluster_infra/tasks/create.yaml` | NICo backend -- reference pattern for building the DPF backend |
| `base/osac-aap/group_vars/all/configuration.yaml` | Central config where `network_steps_collection` is defined -- extend with DPF vars |
| `base/osac-operator/api/v1alpha1/tenant_types.go` | Tenant CRD -- may need DPU isolation fields (Milestone 2) |
| `docs/network-backend.md` | Network backend docs -- add DPF section |
| `scripts/aap-configuration.sh` | AAP config script -- add DPF env var handling |

---

## Verification

**Milestone 1 — DPU machine as OCP worker:**
1. A DPU-equipped bare metal machine joins the HyperShift hosted cluster as a worker node
2. `oc get nodes` shows the DPU node as Ready
3. The control plane can reach kubelet on the worker (hub connectivity solution working)
4. Pods can be scheduled and run on the DPU worker
5. OSAC can provision a hosted cluster with DPU workers via `osac create cluster-order`

**Milestone 2 — Multi-tenant isolation:**
6. DPU workers are configured with per-tenant VLAN/VRF/EVPN VXLAN via DPUServiceConfiguration CRs
7. Hub maintains connectivity to workers after DPU reconfiguration (blocker B1 resolved)
8. Workers from different tenants cannot communicate at L2/L3
9. External access works (API ingress, app ingress, egress SNAT) -- blocker B2 resolved
10. Clean deletion of all resources (DPUServiceConfiguration CRs, DNS, agents, workers released to BareMetalPool)

---

## Reference Links

| Link | Description |
|------|-------------|
| [NVIDIA DPF Zero Trust RDG](https://docs.nvidia.com/networking/display/public/sol/rdg+for+dpf+zero+trust+(dpf-zt)+with+hbn+dpu+service) | Official NVIDIA reference deployment guide for DPF Zero Trust with HBN |
| [Red Hat DPU Blog](https://developers.redhat.com/articles/2025/03/20/dpu-enabled-networking-openshift-and-nvidia-dpf) | "DPU-Enabled Networking with OpenShift and NVIDIA DPF" -- working reference deployment |
| [Jira Epic OSAC-1](https://redhat.atlassian.net/browse/OSAC-1) | DPU Network Class tracking epic |
| [Sharon's ZT + VRF Config](https://docs.google.com/document/d/11Y4hqc9zQZ6uOss3UcQo-nXO8EiAubDST0M8TsG0YtM) | Sharon's lab findings on Zero Trust + VRF configuration (reverse NAT failure) |
| [NVIDIA AIR Lab (Shahar)](https://docs.google.com/document/d/1ezce3uvtJtEThxtf1ap0l0GAwOzxU-sV4e-SvdYfL-E) | NVIDIA AIR simulation lab setup |
| [EVPN Lab (Fede)](https://github.com/fedepaol/evpnlab/tree/main/09_clab_multitenant) | EVPN multi-tenant lab using containerlab |
| [Netris CaaS Networking](https://github.com/osac-project/docs/blob/2a2402f/features/netris-caas-networking.md) | Netris backend reference for comparison |
