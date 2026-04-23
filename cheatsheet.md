# VM Network Attachment Cheatsheet — OCP 4.17 -> 4.21

Quick-reference for consultants advising on OpenShift Virtualization networking.
Covers what to use, when, and which constraints to watch for.

---

## Three VM Personas


| Persona                | Description                                                                                                                   | Examples                                     |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| **Normal VM**          | Workload VM needing a simple IP on one or more VLANs, no trunk, no 802.1Q tags                                                | App servers, databases, web frontends        |
| **VPC-like Tenant VM** | VM in a multi-tenant environment needing namespace isolation, NetworkPolicy, central IPAM, live migration with persistent IPs | SaaS tenant workloads, dev/test environments |
| **Network Appliance**  | Firewall, router, or load balancer expecting a raw 802.1Q trunk NIC with multiple VLAN sub-interfaces                         | pfSense, VyOS, F5, Palo Alto                 |


---

## Master Constraint & Capability Table


| Dimension                 | Linux-bridge NAD                            | CUDN Localnet                       | UDN Layer2                                         | SR-IOV                                    | macvlan NAD                    | ipvlan NAD                     |
| ------------------------- | ------------------------------------------- | ----------------------------------- | -------------------------------------------------- | ----------------------------------------- | ------------------------------ | ------------------------------ |
| **API Resource**          | `NetworkAttachmentDefinition`               | `ClusterUserDefinedNetwork`         | `UserDefinedNetwork` / `ClusterUserDefinedNetwork` | `SriovNetwork` + `SriovNetworkNodePolicy` | `NetworkAttachmentDefinition`  | `NetworkAttachmentDefinition`  |
| **Scope**                 | Namespace (or default for all)              | Cluster (`namespaceSelector`)       | Namespace (UDN) or Cluster (CUDN)                  | Namespace (auto-created NAD)              | Namespace (or default for all) | Namespace (or default for all) |
| **Role**                  | Secondary only                              | Secondary only                      | Primary or Secondary                               | Secondary only                            | Secondary only                 | Secondary only                 |
| **Topology**              | Physical underlay (bridged)                 | Physical underlay (OVN-managed OVS) | Overlay (Geneve tunnel)                            | Physical (VF passthrough)                 | Physical underlay              | Physical underlay (shared MAC) |
| **Needs physical NIC**    | Yes (linux-bridge NNCP)                     | Yes (OVS bridge + bridge-mapping)   | No (pure overlay)                                  | Yes (SR-IOV NIC with VFs)                 | Yes (host NIC or bridge)       | Yes (host NIC or bridge)       |
| **L2 underlay access**    | Yes (secondary NICs only)                   | Yes                                 | No (overlay)                                       | Yes                                       | Yes                            | Yes                            |
| **VLAN support**          | Access (`"vlan": N`) or Trunk (`"vlan": 0`) | Access only (`vlan.mode: Access`)   | No (overlay)                                       | Yes                                       | Via host sub-iface             | Via host sub-iface             |
| **802.1Q trunk to guest** | **Yes** (`"vlan": 0`)                       | **No**                              | No                                                 | Yes (VF trunk)                            | No                             | No                             |
| **Per-VM VLAN filtering** | No                                          | Yes (`namespaceSelector`)           | N/A                                                | Yes (hardware VF)                         | No                             | No                             |
| **NetworkPolicy**         | **No**                                      | **Yes** (OVN)                       | **Yes** (OVN)                                      | **No**                                    | **No**                         | **No**                         |
| **MultiNetworkPolicy**    | No                                          | Yes (`ipBlock` only)                | Yes (L2 secondary)                                 | No                                        | No                             | No                             |
| **MAC spoof filtering**   | Optional                                    | Always on                           | Always on                                          | Configurable                              | No                             | N/A                            |
| **Live migration**        | Supported                                   | Supported                           | Supported (persistent IPs)                         | **Not supported**                         | Supported                      | Supported                      |
| **Hot-plug**              | Yes (bridge + VirtIO)                       | Yes (bridge)                        | Yes                                                | Hot-plug yes, unplug **no**               | No                             | No                             |
| **Persistent IPs**        | No                                          | Yes (`ipam.lifecycle: Persistent`)  | Yes (Layer2 + Persistent)                          | No                                        | No                             | No                             |
| **Services / Routes**     | No                                          | No (secondary)                      | Yes (if primary)                                   | No                                        | No                             | No                             |
| **VM IPAM**               | Manual (cloud-init)                         | Disabled (cloud-init)               | OVN-managed or manual                              | Manual                                    | Whereabouts / static           | Whereabouts / static           |
| **Performance**           | Good (kernel bridge)                        | Good (OVS flow cache)               | Moderate (Geneve encap)                            | **Best** (HW offload)                     | Very good                      | Very good                      |
| **Can talk to host**      | Yes                                         | Yes                                 | No (overlay, NAT)                                  | Yes                                       | **No**                         | **No**                         |


---

## Scenario Decision Matrix

### Scenario 1: Normal VM


| Requirement                           | Best choice                            | Why                                                                           |
| ------------------------------------- | -------------------------------------- | ----------------------------------------------------------------------------- |
| Simple L2 on a VLAN, no policy needed | **Linux-bridge NAD** with `"vlan": N`  | Simplest: NNCP + NAD + VM                                                     |
| L2 on a VLAN + NetworkPolicy          | **CUDN Localnet** (access mode)        | Simple creation and networkpolicy (ipblock only though)                       |
| No physical underlay (cloud/overlay)  | **UDN Layer2** (secondary)             | Full Network Policy with labels etc. No NIC config needed                     |
| Live migration with persistent IP     | **UDN Layer2** (primary, `Persistent`) | Full K8s network services with LB, policy, etc IPs preserved across migration |
| Maximum performance                   | **SR-IOV**                             | Hardware passthrough (no live migration)                                      |


### Scenario 2: VPC-like Tenant Isolation


| Requirement                       | Best choice                                     | Why                                              |
| --------------------------------- | ----------------------------------------------- | ------------------------------------------------ |
| Tenant-per-namespace isolation    | **UDN Layer2** (primary, `Persistent`)          | Replaces default pod network; built-in isolation |
| Multi-namespace shared network    | **CUDN Layer2** (primary) + `namespaceSelector` | Single network spans tenant namespaces           |
| Per-VLAN physical access + policy | **CUDN Localnet** (secondary) per VLAN          | `namespaceSelector` controls access; OVN policy  |
| East-west micro-segmentation      | **NetworkPolicy** on CUDN/UDN                   | OVN ACLs in the datapath                         |


### Scenario 3: Network Appliance with Trunk


| Requirement                   | Best choice                              | Why                                               |
| ----------------------------- | ---------------------------------------- | ------------------------------------------------- |
| 802.1Q trunk (all VLANs)      | **Linux-bridge trunk NAD** (`"vlan": 0`) | Only remaining trunk on OCP 4.17+                 |
| Trunk + per-VM VLAN filtering | **SR-IOV** with VF trunk config          | Hardware VLAN filtering; replaces removed OVS CNI |
| Appliance supports multi-NIC  | **CUDN Localnet** (one per VLAN)         | True isolation; OVN-managed                       |


---

## Critical Constraints (with documentation references)

1. **OVS CNI (`"type": "ovs"`) removed in OCP 4.17+.** Binary not shipped; pods fail with `failed to find plugin "ovs"`.
  Absent from [§2.1 Secondary networks](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/multiple_networks/index#secondary-networks-ocp); absent from [Table 10.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-networking-overview).
2. **Localnet = `ClusterUserDefinedNetwork` only.** `UserDefinedNetwork` supports Layer2/Layer3 only.
  [Tables 1.2/2.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/multiple_networks/index#nw-udn-nad-support-matrix): "Localnet topology is unavailable for use with the `UserDefinedNetwork` CR."
   [§3.1.5.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/multiple_networks/index#creating-cluster-udn-localnet-cr-cli).
3. **CUDN Localnet VLAN is access-mode only.** `vlan: {mode: Access, access: {id: N}}`. No 802.1Q trunk passthrough.
  [§3.1.7](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/multiple_networks/index#additional-configuration-details-udn): `vlan.mode` accepts only `Access`.
   [Table 10.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-networking-overview): "Layer 2 trunk access: Yes (bridge), No (localnet)."
4. **Primary UDN requires `k8s.ovn.org/primary-user-defined-network` namespace label at creation.** Cannot be added later.
  [§10.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-connecting-vm-to-primary-udn).
   [§3.1.5.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/multiple_networks/index#best-practices-cudn): "This label cannot be updated."
5. **Primary UDN VMs lose `virtctl ssh`, `oc port-forward`, and headless services.**
  [§10.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-connecting-vm-to-primary-udn): "You cannot use the `virtctl ssh` command..."
6. **No IPAM for VMs on linux-bridge NADs.** "Configuring IPAM in a NAD for virtual machines is not supported." Use cloud-init.
  [§10.7.2/§10.7.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-connecting-vm-to-linux-bridge) (Warning).
   [§10.10](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-connecting-vm-to-ovn-secondary-network) (same).
7. **CUDN Localnet IPAM for VMs must be `Disabled`.** "The required value is `Disabled`. OpenShift Virtualization does not support configuring IPAM for virtual machines."
  [§10.4.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-connecting-vm-to-secondary-localnet-udn).
8. **SR-IOV: no live migration, no hot-unplug.**
  [§10.11](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-hot-plugging-network-interfaces): "Hot unplugging is not supported for SR-IOV interfaces."
   SR-IOV uses `vfio-pci` (§10.8.1) which is PCI-passthrough incompatible with migration.
9. **Linux-bridge cannot attach to the default machine network directly.**
  [§10.1.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-networking-overview): "You cannot directly attach to the default machine network when using Linux bridge networks."
10. **Hot-plug limits: 4 PCI slots total (including existing interfaces).** q35 may limit to 1 additional PCIe device.
  [§10.11.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-hot-plugging-network-interfaces): "32 slots available... reserves up to four slots for hot plugging."
11. **Linux-bridge bonding modes 0, 5, 6 are not supported.**
  [§10.7](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-connecting-vm-to-linux-bridge): "OpenShift Virtualization does not support Linux bridge bonding modes 0, 5, and 6."
12. **MultiNetworkPolicy on secondary networks: `ipBlock` only for VMs.** Pod/namespace selectors not supported.
  [§10.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-connecting-vm-to-secondary-localnet-udn): "You must use the `ipBlock` attribute."
13. **Default pod network traffic interrupted during live migration.**
  [§10.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-connecting-vm-to-default-pod-network): "Traffic passing through network interfaces to the default pod network is interrupted during live migration."

---

## Hybrid Two-Bridge Architecture

When all three personas coexist in one cluster:

```
  NIC 2 (enp7s0) --> br-secondary (linux-bridge)
    |-- Bridge CNI NADs: trunk, per-VLAN, macvlan, ipvlan
    |-- Used by: Network appliances (trunk), simple VMs (VLAN access)

  NIC 3 (enp8s0) --> ovs-br1 (OVS bridge, OVN-managed)
    |-- CUDN Localnet: per-VLAN access-mode networks
    |-- Used by: Tenant VMs (with NetworkPolicy + isolation)

  Primary overlay (no extra NIC needed):
    |-- UDN Layer2/Layer3 (primary or secondary)
    |-- Used by: VPC-like tenant isolation, live migration
```

Both secondary NICs connect to the same upstream host bridge (`br-lab`), so
VLAN traffic flows between paradigms -- a firewall on `br-secondary` (VLAN 100
trunk) can reach a tenant VM on `ovs-br1` (VLAN 100 CUDN localnet).

---

## One-Line Summary Per Mechanism

- **Linux-bridge NAD** -- Simplest physical underlay access. No policy. Good for appliances and simple VMs.
- **CUDN Localnet** -- OVN-managed physical underlay. NetworkPolicy. Per-VLAN isolation. Recommended for VMs by Red Hat.
- **UDN Layer2 overlay** -- No physical NIC needed. Persistent IPs. Live migration. Best for VPC-style tenant isolation.
- **SR-IOV** -- Maximum performance. Hardware VLAN filtering. No live migration. For telco/NFV.
- **macvlan** -- Lightweight L2 passthrough. Cannot talk to host. Niche.
- **ipvlan** -- Like macvlan but shares MAC. Even more niche.
- **OVS CNI** -- Removed in OCP 4.17+. Do not use.

---

## Reference Documentation (OCP 4.21)

- [Virtualization Networking](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking)
- [Multiple Networks](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/multiple_networks/index)
- [Kubernetes NMState](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/kubernetes_nmstate/index)
- [OVN-Kubernetes Network Plugin](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/ovn-kubernetes_network_plugin/index)

