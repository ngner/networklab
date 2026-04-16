# Linux Networking & KubeVirt VLAN Trunk Lab Plan

## Goal

Build hands-on knowledge of Linux networking constructs (linux bridge,
macvlan, ipvlan) and OVN-Kubernetes abstractions (UDN, Localnet CUDN) so you
can consult on the best network architecture for KubeVirt VMs — specifically
firewall VMs with VLAN trunks — in OpenShift environments. The workshop
covers four deployment models, each suited to different constraints around
NIC count, VLAN scale, appliance compatibility, and policy requirements.

## Lab Environment

- **Fedora lab VM**: fresh install, single NIC (`eth0`). All Phase 1–3
  exercises run here using network namespaces to simulate guests. No nested
  VMs required — namespaces are faster to iterate with and expose the same
  kernel datapath.
- **OpenShift 4.21 compact cluster**: 3-node (combined control plane +
  worker). OVN-Kubernetes default CNI, Multus included. Used for Phase 4–5
  (Kubernetes-level constructs, KubeVirt).

Throughout this plan, network namespaces stand in for "guests." Every namespace
gets a veth pair — one end in the namespace (the "guest NIC"), one end plugged
into the bridge under test. This is the same model Kubernetes uses for pods.

A `dummy0` interface acts as the simulated physical uplink so we don't
interfere with the VM's real connectivity on `eth0`.

### Bootstrap the Fedora Lab VM

```bash
dnf install -y iproute bridge-utils iperf3 tcpdump nftables

# Create a dummy interface to act as the "physical uplink"
# (avoids touching eth0 which carries your SSH session)
ip link add dummy0 type dummy
ip link set dummy0 up
```

---

## Phase 1: Linux Networking Primitives

The Linux kernel has built-in virtual networking constructs — bridges, macvlan,
ipvlan — that have been stable for over a decade. They require no extra
packages; they're compiled into the kernel and configured with `ip link` and
`bridge` commands. On an OpenShift node, these are what sit behind the
**bridge CNI plugin** when you create a Multus `NetworkAttachmentDefinition`.
CNAO (ClusterNetworkAddonOperator part of OpenShift) uses them to give Pods or KubeVirt VMs direct
L2 access to physical networks, **bypassing the OVN-Kubernetes overlay
entirely**.

Understanding these primitives matters because they're the alternative to OVS
for secondary networks. In Phase 2 you'll learn OVS — which is also a
software switch, but programmable, with flow tables, and the datapath that
OVN-Kubernetes controls. The key consulting question is always: *do I need
native bridge simplicity and raw kernel performance, or OVS programmability
and central management?* This phase gives you the baseline for that comparison.

### 1a. veth Pairs + Network Namespaces

A **veth** (virtual ethernet) pair is a kernel object that acts like a cable
with a connector on each end — any frame sent into one end immediately appears
at the other. The two ends can live in different network namespaces, which is
how the kernel provides network isolation between processes. A **network
namespace** is a lightweight isolation boundary: it has its own interfaces,
routing table, iptables rules, and ARP cache, completely independent from the
host and from other namespaces.

Together they model what happens in Kubernetes: the container runtime creates a
namespace for each pod, creates a veth pair, moves one end into the pod
namespace (this becomes `eth0` inside the pod), and plugs the other end into a
bridge or OVS port on the host. Every exercise below uses this same pattern —
namespaces are "guests," veth pairs are their "NICs."

```bash
# Create two "guests"
ip netns add guest-a
ip netns add guest-b

# Create veth pairs
ip link add veth-a type veth peer name veth-a-br
ip link add veth-b type veth peer name veth-b-br

# Move one end into each namespace
ip link set veth-a netns guest-a
ip link set veth-b netns guest-b

# Assign IPs inside the namespaces
ip netns exec guest-a ip addr add 10.0.0.1/24 dev veth-a
ip netns exec guest-a ip link set veth-a up
ip netns exec guest-a ip link set lo up

ip netns exec guest-b ip addr add 10.0.0.2/24 dev veth-b
ip netns exec guest-b ip link set veth-b up
ip netns exec guest-b ip link set lo up

# The veth -br ends are up but not bridged — guests cannot reach each other yet
ip netns exec guest-a ping -c 2 10.0.0.2  # fails: no path between the two pairs
```

The `-br` ends stay in the host namespace — these plug into bridges below.
Without a bridge connecting `veth-a-br` and `veth-b-br`, the two namespaces
are completely isolated even though they have the same subnet addresseses etc.

### 1b. Linux Bridge — VLAN-Unaware (one bridge per VLAN)

The simplest model. Each VLAN gets its own bridge. Guests on the same bridge
see each other; guests on different bridges are isolated.

```bash
# Create two bridges, one per "VLAN"
ip link add br-100 type bridge
ip link set br-100 up
ip link add br-200 type bridge
ip link set br-200 up

# Plug guest-a into br-100, guest-b into br-200
ip link set veth-a-br master br-100
ip link set veth-a-br up
ip link set veth-b-br master br-200
ip link set veth-b-br up

# Test: guest-a cannot reach guest-b (different bridges)
ip netns exec guest-a ping -c 2 10.0.0.2  # fails

# Add guest-c to br-100 to prove same-bridge connectivity
ip netns add guest-c
ip link add veth-c type veth peer name veth-c-br
ip link set veth-c netns guest-c
ip netns exec guest-c ip addr add 10.0.0.3/24 dev veth-c
ip netns exec guest-c ip link set veth-c up
ip link set veth-c-br master br-100  # same as guest-a
ip link set veth-c-br up

ip netns exec guest-a ping -c 2 10.0.0.3  # succeeds
```

Understand the model: a trunk "firewall VM" needs one NIC per VLAN (one per
bridge). For 4 VLANs that's 4 NICs, each carrying untagged traffic. Firewall
appliances that expect a single 802.1Q trunk interface cannot work this way.

```bash
# Cleanup
ip netns del guest-a; ip netns del guest-b; ip netns del guest-c
ip link del br-100; ip link del br-200
```

### 1c. Linux Bridge — VLAN-Aware (single bridge, per-port filtering)

This is what the **Cluster Network Addons Operator (CNAO)** — deployed as part
of OpenShift — uses under the hood when you create a
`NetworkAttachmentDefinition` with the `bridge` CNI plugin. In OVN-Kubernetes
terms, this is a **secondary network** attached via Multus, bypassing the OVN
overlay and giving the VM direct L2 access to a node-local bridge. One bridge
carries all VLANs; per-port rules control which VLANs each guest sees.

By default, a Linux bridge is **VLAN-unaware** — it forwards all frames
regardless of 802.1Q tags, behaving like a dumb hub for tagged traffic. Setting
`vlan_filtering 1` activates the bridge's **per-port VLAN table**, turning it
into something closer to a managed switch. Each port on the bridge now has an
explicit list of allowed VLAN IDs. Frames tagged with a VLAN not in the port's
list are dropped at ingress. Ports can be configured as:

- **Trunk**: carries multiple VLANs, frames remain 802.1Q tagged
- **Access** (`pvid untagged`): strips the VLAN tag on egress so the guest
  sees untagged frames, and tags untagged ingress frames with the PVID

The kernel implements this in the `br_vlan_filter()` path — it's a fast
in-kernel lookup, no userspace overhead.

```bash
ip link add br-trunk type bridge vlan_filtering 1
ip link set br-trunk up

# Uplink: allow VLANs 100 and 200 tagged
ip link set dummy0 master br-trunk
bridge vlan add vid 100 dev dummy0
bridge vlan add vid 200 dev dummy0
#   "vid 100" means: this port accepts/sends frames tagged with VLAN 100.
#   Note it has no "pvid" or "untagged" flags hence frames stay 802.1Q tagged in both directions.
#   This is a trunk-style entry.

# guest-a: trunk port, VLANs 100 + 200 (receives tagged 802.1Q frames)
ip netns add guest-a
ip link add veth-a type veth peer name veth-a-br
ip link set veth-a netns guest-a
ip link set veth-a-br master br-trunk
ip link set veth-a-br up
bridge vlan del vid 1 dev veth-a-br
#   Every port starts with VLAN 1 as the default PVID. Delete it so only
#   explicitly added VLANs are allowed — otherwise untagged traffic would
#   be classified into VLAN 1 and leak.
bridge vlan add vid 100 dev veth-a-br
bridge vlan add vid 200 dev veth-a-br
#   Note no "pvid" or "untagged" flags hence tagged trunk interface for veth. guest-a will see raw 802.1Q
#   frames and must create sub-interfaces (veth-a.100, veth-a.200) to
#   decapsulate them — exactly how a firewall appliance consumes a trunk.

# Inside guest-a, create VLAN sub-interfaces (as a firewall would)
ip netns exec guest-a ip link set veth-a up
ip netns exec guest-a ip link add link veth-a name veth-a.100 type vlan id 100
ip netns exec guest-a ip addr add 10.0.100.1/24 dev veth-a.100
ip netns exec guest-a ip link set veth-a.100 up
ip netns exec guest-a ip link add link veth-a name veth-a.200 type vlan id 200
ip netns exec guest-a ip addr add 10.0.200.1/24 dev veth-a.200
ip netns exec guest-a ip link set veth-a.200 up

# guest-b: access port, VLAN 100 only (receives untagged)
ip netns add guest-b
ip link add veth-b type veth peer name veth-b-br
ip link set veth-b netns guest-b
ip link set veth-b-br master br-trunk
ip link set veth-b-br up
bridge vlan del vid 1 dev veth-b-br
bridge vlan add vid 100 dev veth-b-br pvid untagged
#   Two things happen with "pvid untagged":
#     pvid    — Port VLAN ID. Untagged frames arriving on this port are
#               classified into VLAN 100 (ingress tagging).
#     untagged — Frames leaving this port on VLAN 100 have their 802.1Q
#                tag stripped (egress untagging).
#   Together they make this an access port: guest-b sees plain ethernet
#   frames with no VLAN awareness needed — it just uses a flat IP on the
#   interface. Compare to guest-a which receives tagged frames and must
#   create sub-interfaces.

ip netns exec guest-b ip addr add 10.0.100.2/24 dev veth-b
ip netns exec guest-b ip link set veth-b up

# Test: guest-b (access VLAN 100) can reach guest-a's VLAN 100 sub-interface
ip netns exec guest-b ping -c 2 10.0.100.1  # succeeds

# Verify VLAN table
bridge vlan show
# shows all the above in a nice summary.
```

Key observations:
- Guest-a sees tagged frames on a single NIC — this matches how firewall
  appliances expect trunk delivery
- Guest-b sees untagged VLAN 100 — standard access port
- `bridge vlan` commands are **not persisted** across reboot — you need additional config 
   openshift uses nmstate operator for applying and persisting the host network configurations.

```bash
# Cleanup
ip netns del guest-a; ip netns del guest-b
ip link del br-trunk
```

### 1d. macvlan

```bash
# Bridge mode — sub-interfaces can talk to each other
ip link add macvlan0 link dummy0 type macvlan mode bridge
ip link add macvlan1 link dummy0 type macvlan mode bridge

# Move into namespaces
ip netns add mv-a
ip netns add mv-b
ip link set macvlan0 netns mv-a
ip link set macvlan1 netns mv-b

ip netns exec mv-a ip addr add 10.0.50.1/24 dev macvlan0
ip netns exec mv-a ip link set macvlan0 up
ip netns exec mv-b ip addr add 10.0.50.2/24 dev macvlan1
ip netns exec mv-b ip link set macvlan1 up

# Test: mv-a and mv-b can communicate (bridge mode)
ip netns exec mv-a ping -c 2 10.0.50.2

# Key learning: host CANNOT reach macvlan sub-interfaces
ping -c 2 10.0.50.1  # fails — this is by design
```

Also try VEPA mode (traffic forced through external switch) and private mode
(complete isolation between sub-interfaces):

```bash
ip link add macvlan-vepa link dummy0 type macvlan mode vepa
ip link add macvlan-priv link dummy0 type macvlan mode private
```

macvlan sub-interfaces **cannot communicate with the parent interface**. This
is critical for KubeVirt networking decisions — a VM on macvlan cannot talk to
services on the host.

```bash
ip netns del mv-a; ip netns del mv-b
```

### 1e. ipvlan

```bash
ip netns add iv-a
ip netns add iv-b

# L2 mode — similar to macvlan but shares parent's MAC address
ip link add ipvlan0 link dummy0 type ipvlan mode l2
ip link add ipvlan1 link dummy0 type ipvlan mode l2
ip link set ipvlan0 netns iv-a
ip link set ipvlan1 netns iv-b

ip netns exec iv-a ip addr add 10.0.60.1/24 dev ipvlan0
ip netns exec iv-a ip link set ipvlan0 up
ip netns exec iv-b ip addr add 10.0.60.2/24 dev ipvlan1
ip netns exec iv-b ip link set ipvlan1 up

# Verify: both share the same MAC as dummy0
ip netns exec iv-a ip link show ipvlan0
ip netns exec iv-b ip link show ipvlan1
ip link show dummy0
```

Key difference from macvlan: single MAC address (the parent's). Useful when
the upstream switch has MAC-per-port limits or you want L3-only isolation.
Avoids MAC table exhaustion on large KubeVirt clusters.

Also try **L3 mode** — the kernel routes packets by IP instead of bridging by
MAC. No ARP, no broadcast, no multicast. Scales well, but breaks anything
relying on L2 adjacency (DHCP, gratuitous ARP, firewall HA clustering).

```bash
ip link add ipvlan-l3 link dummy0 type ipvlan mode l3
```

```bash
ip netns del iv-a; ip netns del iv-b
```

---

## Phase 2: OVS & OVN Background

You do not configure OVS directly on OpenShift nodes. OVN-Kubernetes owns the
OVS datapath — it creates `br-int` (integration bridge) and `br-ex` (external
bridge) on every node and programs OpenFlow rules to implement pod networking,
NetworkPolicy, and services.

What matters for this workshop:

- **Localnet UDN** maps an OVN logical switch to a physical network by
  creating a `localnet` port on an **OVS bridge** configured via NMState
  `bridge-mappings`. OVN handles VLAN tagging (access mode) and all
  forwarding logic — you declare a `ClusterUserDefinedNetwork` and OVN
  programs the datapath.
- **Bridge CNI** (`vlanTrunk`) uses a **Linux bridge** — the same kernel
  construct from Phase 1. It does not touch OVS at all.
- For debugging OVN-programmed flows on a node:

```bash
oc debug node/<node> -- chroot /host ovs-ofctl dump-flows br-int
oc debug node/<node> -- chroot /host ovs-vsctl show
```

---

## Phase 3: Trunk-to-Guest — Linux Bridge VLAN Filtering

This is the core hands-on section for KubeVirt firewall VM consultation. The
VLAN-aware Linux bridge with per-port filtering is the kernel primitive behind
the **Bridge CNI `vlanTrunk`** feature used on OpenShift (Phase 5). Build the
scenario below and understand how per-port VLAN allow-lists work before moving
to the Kubernetes abstractions.

### Test Scenario: Four Guests, Different VLAN Sets

| Guest | Role | Allowed VLANs | Type |
|---|---|---|---|
| `fw-dmz` | DMZ firewall | 100, 200 | Trunk |
| `fw-internal` | Internal firewall | 123, 150 | Trunk |
| `monitor` | IDS/tap | 100, 123, 150, 200 | Read-only mirror |
| `tenant-a` | Tenant workload | 100 | Access (untagged) |

### 3a. Helper: Create Namespaces and veth Pairs

Run this once — the bridge setups below reuse the same namespaces.

```bash
for ns in fw-dmz fw-internal monitor tenant-a; do
  ip netns add $ns
done
```

For each test, create fresh veth pairs, run the exercises, then clean up.

### 3b. VLAN-Unaware Bridge (per-bridge model)

Each guest gets one veth per VLAN, one bridge per VLAN.

```bash
for vid in 100 123 150 200; do
  ip link add br-${vid} type bridge
  ip link set br-${vid} up
done

# fw-dmz: VLANs 100, 200 → two veths
ip link add veth-dmz-100 type veth peer name veth-dmz-100-br
ip link set veth-dmz-100 netns fw-dmz
ip link set veth-dmz-100-br master br-100 && ip link set veth-dmz-100-br up
ip netns exec fw-dmz ip addr add 10.0.100.1/24 dev veth-dmz-100
ip netns exec fw-dmz ip link set veth-dmz-100 up

ip link add veth-dmz-200 type veth peer name veth-dmz-200-br
ip link set veth-dmz-200 netns fw-dmz
ip link set veth-dmz-200-br master br-200 && ip link set veth-dmz-200-br up
ip netns exec fw-dmz ip addr add 10.0.200.1/24 dev veth-dmz-200
ip netns exec fw-dmz ip link set veth-dmz-200 up

# monitor: all 4 VLANs → four veths (!)
# (This is where the model breaks down for real appliances)
```

Observe: `fw-dmz` has 2 interfaces, `monitor` needs 4. A real firewall
appliance expecting `eth0.100` and `eth0.200` sub-interfaces on a single
trunk NIC **cannot work** — it sees discrete untagged NICs instead.

Adding VLAN 300 to `fw-dmz` means: create `br-300`, create a new veth pair,
move one end into the namespace, assign an IP, bring it up. 5+ steps, and the
"guest" must be reconfigured to use the new interface.

```bash
# Cleanup
for vid in 100 123 150 200; do ip link del br-${vid} 2>/dev/null; done
```

### 3c. VLAN-Aware Bridge Setup

```bash
ip link add br-trunk type bridge vlan_filtering 1
ip link set br-trunk up
ip link set dummy0 master br-trunk
for vid in 100 123 150 200; do
  bridge vlan add vid $vid dev dummy0
done

# --- fw-dmz: trunk, VLANs 100 + 200 ---
ip link add veth-dmz type veth peer name veth-dmz-br
ip link set veth-dmz netns fw-dmz
ip link set veth-dmz-br master br-trunk && ip link set veth-dmz-br up
bridge vlan del vid 1 dev veth-dmz-br
bridge vlan add vid 100 dev veth-dmz-br
bridge vlan add vid 200 dev veth-dmz-br

ip netns exec fw-dmz ip link set veth-dmz up
ip netns exec fw-dmz ip link add link veth-dmz name veth-dmz.100 type vlan id 100
ip netns exec fw-dmz ip addr add 10.0.100.1/24 dev veth-dmz.100
ip netns exec fw-dmz ip link set veth-dmz.100 up
ip netns exec fw-dmz ip link add link veth-dmz name veth-dmz.200 type vlan id 200
ip netns exec fw-dmz ip addr add 10.0.200.1/24 dev veth-dmz.200
ip netns exec fw-dmz ip link set veth-dmz.200 up

# --- fw-internal: trunk, VLANs 123 + 150 ---
ip link add veth-int type veth peer name veth-int-br
ip link set veth-int netns fw-internal
ip link set veth-int-br master br-trunk && ip link set veth-int-br up
bridge vlan del vid 1 dev veth-int-br
bridge vlan add vid 123 dev veth-int-br
bridge vlan add vid 150 dev veth-int-br

ip netns exec fw-internal ip link set veth-int up
ip netns exec fw-internal ip link add link veth-int name veth-int.123 type vlan id 123
ip netns exec fw-internal ip addr add 10.0.123.1/24 dev veth-int.123
ip netns exec fw-internal ip link set veth-int.123 up
ip netns exec fw-internal ip link add link veth-int name veth-int.150 type vlan id 150
ip netns exec fw-internal ip addr add 10.0.150.1/24 dev veth-int.150
ip netns exec fw-internal ip link set veth-int.150 up

# --- monitor: trunk, all VLANs ---
ip link add veth-mon type veth peer name veth-mon-br
ip link set veth-mon netns monitor
ip link set veth-mon-br master br-trunk && ip link set veth-mon-br up
bridge vlan del vid 1 dev veth-mon-br
for vid in 100 123 150 200; do
  bridge vlan add vid $vid dev veth-mon-br
done

ip netns exec monitor ip link set veth-mon up
for vid in 100 123 150 200; do
  ip netns exec monitor ip link add link veth-mon name veth-mon.${vid} type vlan id $vid
  ip netns exec monitor ip addr add 10.0.${vid}.254/24 dev veth-mon.${vid}
  ip netns exec monitor ip link set veth-mon.${vid} up
done

# --- tenant-a: access port, VLAN 100 (untagged) ---
ip link add veth-tena type veth peer name veth-tena-br
ip link set veth-tena netns tenant-a
ip link set veth-tena-br master br-trunk && ip link set veth-tena-br up
bridge vlan del vid 1 dev veth-tena-br
bridge vlan add vid 100 dev veth-tena-br pvid untagged

ip netns exec tenant-a ip addr add 10.0.100.10/24 dev veth-tena
ip netns exec tenant-a ip link set veth-tena up

# --- Verify ---
bridge vlan show

# tenant-a (access VLAN 100) reaches fw-dmz's VLAN 100 sub-interface
ip netns exec tenant-a ping -c 2 10.0.100.1
```

**Read-only monitor** requires a separate subsystem (nftables bridge
filtering) because the Linux bridge has no concept of port direction:

```bash
nft add table bridge filter
nft add chain bridge filter forward '{ type filter hook forward priority 0; }'
nft add rule bridge filter forward ibrname "veth-mon-br" drop
```

```bash
# Cleanup
ip link del br-trunk 2>/dev/null
nft delete table bridge filter 2>/dev/null
```

### 3d. Lab Exercises

Rebuild namespaces between each test using section 3c's VLAN-aware bridge
setup.

**Exercise 1 — Baseline connectivity.** Verify all four guests have the
correct connectivity: `tenant-a` reaches `fw-dmz` on VLAN 100 only, `fw-dmz`
and `fw-internal` are isolated from each other, `monitor` can see all VLANs.

**Exercise 2 — Day-2 VLAN change.** Add VLAN 300 to `fw-dmz`:

```bash
bridge vlan add vid 300 dev veth-dmz-br
```

Then inside fw-dmz:

```bash
ip netns exec fw-dmz ip link add link veth-dmz name veth-dmz.300 type vlan id 300
ip netns exec fw-dmz ip addr add 10.0.300.1/24 dev veth-dmz.300
ip netns exec fw-dmz ip link set veth-dmz.300 up
```

Note: `bridge vlan` changes are live but **not persisted** across reboot.
On OpenShift, NMState + Bridge CNI NADs handle persistence declaratively.

**Exercise 3 — Prove VLAN isolation.** From `fw-dmz`, send a tagged frame on
VLAN 123 (not in its allowed set). Verify it never reaches `fw-internal`.

```bash
ip netns exec fw-internal tcpdump -c 5 -i veth-int &
ip netns exec fw-dmz ip link add link veth-dmz name veth-dmz.123 type vlan id 123
ip netns exec fw-dmz ip addr add 10.0.123.99/24 dev veth-dmz.123
ip netns exec fw-dmz ip link set veth-dmz.123 up
ip netns exec fw-dmz ping -c 3 10.0.123.1
# tcpdump on fw-internal shows nothing — the bridge drops the frame
```

**Exercise 4 — Passive monitor.** Generate traffic between `tenant-a` and
`fw-dmz` on VLAN 100. Verify `monitor` sees it on `veth-mon.100`. Then try
to inject a frame from `monitor` and verify it's dropped by the nftables
rule from section 3c.

**Exercise 5 — Asymmetric expansion.** Give `fw-internal` access to VLAN 100
in addition to 123/150:

```bash
bridge vlan add vid 100 dev veth-int-br
```

Inside the namespace:

```bash
ip netns exec fw-internal ip link add link veth-int name veth-int.100 type vlan id 100
ip netns exec fw-internal ip addr add 10.0.100.2/24 dev veth-int.100
ip netns exec fw-internal ip link set veth-int.100 up
```

With the per-bridge model this would require adding a new veth pair to br-100
and reconfiguring the guest.

---

## Phase 4: OVN → Kubernetes Concept Mapping

OVN is the logical control plane on top of OVS. On OpenShift, OVN-Kubernetes
programs OVN automatically — you interact with it through Kubernetes resources
(UDN, CUDN, NetworkPolicy), not `ovn-nbctl`. This table maps the OVN concepts
to their Kubernetes equivalents:

| OVN Concept | Kubernetes Equivalent |
|---|---|
| Logical Switch | Namespace network / UDN L2 segment |
| Logical Router | UDN L3 topology / cluster default gateway |
| Logical Switch Port | Pod network interface |
| ACLs | NetworkPolicy / AdminNetworkPolicy |
| Localnet port | CUDN with `topology: Localnet` (maps to OVS bridge via `bridge-mappings`) |

For debugging OVN on an OCP node:

```bash
oc debug node/<node> -- chroot /host ovn-nbctl show
oc debug node/<node> -- chroot /host ovn-sbctl show
```

---

## Phase 5: OpenShift 4.21 — Kubernetes-Level Constructs

Switch from the Fedora lab VM to the 3-node OCP 4.21 compact cluster. OCP 4.21
ships OVN-Kubernetes as the default CNI and Multus for secondary networks.

### 5a. Prereqs on the Cluster

```bash
# Install the OpenShift Virtualization operator (provides KubeVirt + CNAO)
# Via OperatorHub in the console, or:
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  channel: stable
  name: kubevirt-hyperconverged
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for the operator, then create the HyperConverged CR
cat <<'EOF' | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec: {}
EOF
```

Verify Multus is running (it ships by default on OCP):

```bash
oc get pods -n openshift-multus
```

### 5b. Prepare Node Network for Secondary Networks

On each OCP node, ensure there's a NIC or bridge available for secondary
network attachment. Use NMState (ships with OCP) to configure it declaratively:

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: br-secondary
spec:
  desiredState:
    interfaces:
      - name: br-secondary
        type: linux-bridge
        state: up
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ens4  ## Change to suitable interface `oc debug node/{someworker} -- chroot /host ip -o link show`
    # If you need VLAN-aware filtering on the bridge:
    # (alternative: let Multus/CNI handle VLAN tagging)
```

### 5c. Multus + Bridge CNI

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vlan100-bridge
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "vlan100-bridge",
      "type": "bridge",
      "bridge": "br-secondary",
      "vlan": 100,
      "ipam": {}
    }
```

For a trunk (no VLAN stripping — pass tagged frames to the pod/VM):

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: trunk-bridge
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "trunk-bridge",
      "type": "bridge",
      "bridge": "br-secondary",
      "vlan": 0,
      "ipam": {}
    }
```

### 5d. Multus + macvlan / ipvlan CNI

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: macvlan-net
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "ens4",
      "mode": "bridge",
      "ipam": { "type": "whereabouts", "range": "10.0.100.0/24" }
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ipvlan-net
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "ipvlan",
      "master": "ens4",
      "mode": "l2",
      "ipam": { "type": "whereabouts", "range": "10.0.100.0/24" }
    }
```

Test with plain pods first (not KubeVirt) to verify each NAD:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-macvlan
  annotations:
    k8s.v1.cni.cncf.io/networks: macvlan-net
spec:
  containers:
    - name: test
      image: registry.access.redhat.com/ubi9/ubi-minimal
      command: ["sleep", "infinity"]
```

```bash
oc exec test-macvlan -- ip addr show
```

### 5e. UDN (User Defined Networks)

OCP 4.21 with OVN-Kubernetes supports UDN natively. UDN replaces many Multus
use cases with OVN-managed networks.

**L2 topology** — flat network, like a bridge/VLAN segment:

```yaml
apiVersion: k8s.ovn.org/v1
kind: UserDefinedNetwork
metadata:
  name: tenant-blue
  namespace: tenant-blue
spec:
  topology: Layer2
  layer2:
    role: Primary
    subnets:
      - cidr: 10.100.0.0/16
```

**L3 topology** — routed network with per-node subnets:

```yaml
apiVersion: k8s.ovn.org/v1
kind: UserDefinedNetwork
metadata:
  name: tenant-green
  namespace: tenant-green
spec:
  topology: Layer3
  layer3:
    role: Primary
    subnets:
      - cidr: 10.200.0.0/16
        hostSubnet: 24
```

**Localnet topology** — maps a CUDN to a physical VLAN via an OVS bridge.
Requires NMState `bridge-mappings` on each node (see section 5e-2):

```yaml
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: cudn-vlan100
spec:
  namespaceSelector:
    matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values: ["tenant-a"]
  network:
    topology: Localnet
    localnet:
      role: Secondary
      physicalNetworkName: localnet-trunk
      vlan:
        mode: Access
        access:
          id: 100
      ipam:
        mode: Disabled
```

The `physicalNetworkName` maps to an OVS bridge mapping configured via
NMState. This is how OVN-Kubernetes exposes physical VLANs to pods/VMs.
Only `vlan.mode: Access` is supported in OCP 4.21 — one VLAN per CUDN.

### 5e-1. Bridge CNI `vlanTrunk` — Per-VM VLAN Filtering

The bridge CNI trunk NAD in 5c passes *all* VLANs to every attached pod/VM.
For firewall VMs that need different VLAN subsets on the same bridge, use
the `vlanTrunk` parameter of the **bridge CNI plugin**. This gives each
pod/VM its own per-port VLAN allow-list on a Linux bridge — the same
`bridge vlan` filtering from Phase 3.

> **Note:** The `ovs-cni` plugin (`"type": "ovs"`) is **unsupported** on
> OpenShift since 4.14. Bridge CNI `vlanTrunk` is the supported replacement
> for per-port VLAN filtering.

**Prereq — VLAN-aware Linux bridge on each node.** Use NMState:

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: br-secondary
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  desiredState:
    interfaces:
      - name: br-secondary
        type: linux-bridge
        state: up
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ens4
              vlan:
                mode: trunk
                trunk-tags:
                  - id: 100
                  - id: 123
                  - id: 150
                  - id: 200
```

Verify on a node:

```bash
oc debug node/<node> -- chroot /host bridge vlan show
```

You should see `br-secondary` with the configured VLANs on `ens4`.

**NAD: DMZ firewall trunk — VLANs 100, 200**

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: trunk-dmz
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "trunk-dmz",
      "type": "bridge",
      "bridge": "br-secondary",
      "vlanTrunk": [
        { "id": 100 },
        { "id": 200 }
      ]
    }
```

**NAD: Internal firewall trunk — VLANs 123, 150**

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: trunk-internal
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "trunk-internal",
      "type": "bridge",
      "bridge": "br-secondary",
      "vlanTrunk": [
        { "id": 123 },
        { "id": 150 }
      ]
    }
```

**NAD: Full trunk (all VLANs) — for a monitor port**

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: trunk-all
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "trunk-all",
      "type": "bridge",
      "bridge": "br-secondary",
      "vlanTrunk": [
        { "minID": 1, "maxID": 4094 }
      ]
    }
```

Each pod/VM gets its own veth pair whose bridge-side end has per-port VLAN
filtering — the same `bridge vlan` model from Phase 3. The `vlanTrunk`
array supports individual IDs (`{ "id": 100 }`) and ranges
(`{ "minID": 300, "maxID": 399 }`).

**Test with a plain pod before using KubeVirt:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-bridge-trunk
  annotations:
    k8s.v1.cni.cncf.io/networks: trunk-dmz
spec:
  containers:
    - name: test
      image: registry.access.redhat.com/ubi9/ubi-minimal
      command: ["sleep", "infinity"]
```

```bash
oc exec test-bridge-trunk -- ip -d link show
# Expect net1 interface — create VLAN sub-interfaces inside:
oc exec test-bridge-trunk -- ip link add link net1 name net1.100 type vlan id 100
oc exec test-bridge-trunk -- ip addr add 10.0.100.50/24 dev net1.100
oc exec test-bridge-trunk -- ip link set net1.100 up
```

Verify on the host that the bridge has the correct per-port VLAN config:

```bash
oc debug node/<node> -- chroot /host bridge vlan show
```

### 5e-2. Localnet UDN — Per-VLAN Access Networks

Localnet UDN maps an OVN logical switch directly to a physical network via
an OVS bridge. Each `ClusterUserDefinedNetwork` (CUDN) with `topology:
Localnet` represents **one VLAN in access mode**. The VM gets one untagged
NIC per CUDN — no trunk tagging inside the guest.

> **Important:** Localnet UDN supports only `vlan.mode: Access` in OCP 4.21.
> There is no `Trunk` mode. The OCP 4.21 Virtualization docs (Table 10.1)
> explicitly confirm: "Layer 2 trunk access: OVN-Kubernetes localnet = **No**."

**Step 1 — OVS bridge with bridge-mapping** (required for localnet).
Use NMState to create a dedicated OVS bridge on a secondary NIC and map it:

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ovs-bridge-trunk
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  desiredState:
    interfaces:
      - name: ovs-bridge-trunk
        type: ovs-bridge
        state: up
        bridge:
          allow-extra-patch-ports: true
          options:
            stp: false
          port:
            - name: ens4
    ovn:
      bridge-mappings:
        - localnet: localnet-trunk
          bridge: ovs-bridge-trunk
          state: present
```

Verify the mapping:

```bash
oc get nns <node> -o jsonpath='{.status.currentState.ovn.bridge-mappings}' | jq .
```

**Step 2 — One CUDN per VLAN:**

```yaml
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: cudn-vlan100
spec:
  namespaceSelector:
    matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values: ["firewall-vms", "tenant-a"]
  network:
    topology: Localnet
    localnet:
      role: Secondary
      physicalNetworkName: localnet-trunk
      vlan:
        mode: Access
        access:
          id: 100
      ipam:
        mode: Disabled
---
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: cudn-vlan200
spec:
  namespaceSelector:
    matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values: ["firewall-vms", "tenant-b"]
  network:
    topology: Localnet
    localnet:
      role: Secondary
      physicalNetworkName: localnet-trunk
      vlan:
        mode: Access
        access:
          id: 200
      ipam:
        mode: Disabled
---
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: cudn-vlan123
spec:
  namespaceSelector:
    matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values: ["firewall-vms"]
  network:
    topology: Localnet
    localnet:
      role: Secondary
      physicalNetworkName: localnet-trunk
      vlan:
        mode: Access
        access:
          id: 123
      ipam:
        mode: Disabled
```

Heterogeneous VLAN assignment comes from which CUDNs you attach to each VM:
`fw-dmz` gets `cudn-vlan100` + `cudn-vlan200`; `fw-internal` gets
`cudn-vlan123`. No trunk tagging inside the VM — each interface arrives
untagged on its VLAN.

**Trade-off: Bridge CNI `vlanTrunk` vs Localnet per-VLAN**

| | Bridge CNI `vlanTrunk` | Localnet per-VLAN |
|---|---|---|
| VM sees | One NIC, tagged 802.1Q frames | One NIC per VLAN, untagged |
| Firewall appliance compat | Best — matches physical trunk model | Requires appliance to support multi-NIC |
| VLAN add/remove | Edit NAD + restart pod/VM | Create new CUDN + restart VM |
| NetworkPolicy | Not enforced (bypasses OVN) | Enforced by OVN per-CUDN |
| Bridge type on node | Linux bridge | OVS bridge |
| Central management | Multus NADs | OVN northbound DB, Kubernetes API |
| Live migration | Supported | Supported (OVN port binding migrates) |

For firewall VMs that expect a standard 802.1Q trunk, **Bridge CNI `vlanTrunk`
is the right choice**. Localnet-per-VLAN is better when the VM doesn't need to
see VLAN tags or when you want OVN NetworkPolicy enforcement on each VLAN.

### 5f. KubeVirt VMs with Network Attachments

**Firewall VM with Bridge CNI `vlanTrunk` — DMZ (VLANs 100, 200):**

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fw-dmz
  namespace: default
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: trunk
              bridge: {}
        resources:
          requests:
            memory: 2Gi
      networks:
        - name: default
          pod: {}
        - name: trunk
          multus:
            networkName: trunk-dmz
```

**Firewall VM with Bridge CNI `vlanTrunk` — Internal (VLANs 123, 150):**

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fw-internal
  namespace: default
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: trunk
              bridge: {}
        resources:
          requests:
            memory: 2Gi
      networks:
        - name: default
          pod: {}
        - name: trunk
          multus:
            networkName: trunk-internal
```

Both VMs get a single trunk NIC (`eth1` inside the guest). The VLAN allow-list
is enforced by the Linux bridge on the host via per-port `vlan_filtering`.
Inside each VM:

```bash
# fw-dmz
virtctl console fw-dmz
ip link add link eth1 name eth1.100 type vlan id 100
ip addr add 10.0.100.1/24 dev eth1.100
ip link set eth1.100 up
ip link add link eth1 name eth1.200 type vlan id 200
ip addr add 10.0.200.1/24 dev eth1.200
ip link set eth1.200 up

# fw-internal
virtctl console fw-internal
ip link add link eth1 name eth1.123 type vlan id 123
ip addr add 10.0.123.1/24 dev eth1.123
ip link set eth1.123 up
ip link add link eth1 name eth1.150 type vlan id 150
ip addr add 10.0.150.1/24 dev eth1.150
ip link set eth1.150 up
```

Verify VLAN filtering on the host:

```bash
oc debug node/<node> -- chroot /host bridge vlan show
```

**Day-2: Add VLAN 300 to fw-dmz.** Edit the NAD and restart the VM (bridge
CNI reads the NAD at pod creation time, not live):

```bash
oc edit nad trunk-dmz
# Add { "id": 300 } to the vlanTrunk array
# Then restart the VM:
virtctl restart fw-dmz
```

Then inside `fw-dmz`:

```bash
ip link add link eth1 name eth1.300 type vlan id 300
ip addr add 10.0.300.1/24 dev eth1.300
ip link set eth1.300 up
```

`fw-internal` is unaffected — its bridge port still only allows VLANs 123 and 150.

**Tenant VM with Localnet CUDN (physical VLAN via OVN):**

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: tenant-vm
  namespace: tenant-a
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: vlan100
              bridge: {}
        resources:
          requests:
            memory: 2Gi
      networks:
        - name: default
          pod: {}
        - name: vlan100
          multus:
            networkName: cudn-vlan100
```

**Firewall VM with multiple Localnet CUDNs (one untagged NIC per VLAN):**

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fw-dmz-localnet
  namespace: firewall-vms
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: vlan100
              bridge: {}
            - name: vlan200
              bridge: {}
        resources:
          requests:
            memory: 2Gi
      networks:
        - name: default
          pod: {}
        - name: vlan100
          multus:
            networkName: cudn-vlan100
        - name: vlan200
          multus:
            networkName: cudn-vlan200
```

This VM gets `eth1` on VLAN 100 and `eth2` on VLAN 200 — both untagged. No
VLAN sub-interfaces needed inside the guest. Useful when the appliance supports
multiple discrete NICs, or when you want OVN NetworkPolicy to apply per-VLAN.

#### Choosing between the approaches

| Approach | When to use |
|---|---|
| Bridge CNI `vlanTrunk` | Firewall VMs expecting 802.1Q trunks with per-VM VLAN allow-lists. Uses a Linux bridge. |
| Localnet CUDN per-VLAN | VMs that don't need 802.1Q tags; you want OVN NetworkPolicy on each VLAN. Uses an OVS bridge. |

### 5g. OCP Exercises

**Exercise 1 — NAD matrix.** Create NADs for bridge, macvlan, and ipvlan
CNI. Attach plain pods to each. Document: interface name inside the pod,
MAC address, whether the pod can reach the host, whether pods on different
nodes can reach each other.

**Exercise 2 — UDN vs Multus.** Create the same L2 segment as both a Multus
bridge NAD and a UDN Layer2. Attach pods to each. Compare: how is IPAM
handled, how does NetworkPolicy apply, what shows up in `ovn-nbctl show`.

**Exercise 3 — Bridge CNI `vlanTrunk` pod.** Deploy `test-bridge-trunk` from
section 5e-1. Verify the bridge has per-port VLAN filtering:

```bash
oc debug node/<node> -- chroot /host bridge vlan show
```

Create VLAN sub-interfaces inside the pod and confirm connectivity on allowed
VLANs. Then try to send traffic on a disallowed VLAN and verify it's dropped.

**Exercise 4 — KubeVirt firewall VMs with bridge trunk.** Deploy both `fw-dmz`
(trunk-dmz NAD, VLANs 100/200) and `fw-internal` (trunk-internal NAD, VLANs
123/150) from section 5f. Inside each VM, create VLAN sub-interfaces and
verify:

```bash
# From fw-dmz: confirm VLAN 100 and 200 work
virtctl console fw-dmz
ping -c 3 10.0.100.10    # peer on VLAN 100
ping -c 3 10.0.200.10    # peer on VLAN 200

# From fw-internal: confirm VLAN 123 and 150 work
virtctl console fw-internal
ping -c 3 10.0.123.10
ping -c 3 10.0.150.10
```

Verify isolation from the host — check that `fw-dmz`'s bridge port only
allows VLANs 100 and 200:

```bash
oc debug node/<node> -- chroot /host bridge vlan show
```

**Exercise 5 — Day-2 VLAN change on OCP.** Add VLAN 300 to `fw-dmz` only.
Compare the two approaches:

| Approach | Steps | VM restart? |
|---|---|---|
| Bridge CNI `vlanTrunk` | `oc edit nad trunk-dmz` — add `{ "id": 300 }` to the `vlanTrunk` array. Then restart the VM. | Yes |
| Localnet CUDN | Create a new `cudn-vlan300` CUDN. Add it to `fw-dmz-localnet` VM spec. | Yes (VM spec change) |

After the bridge CNI change and VM restart, verify on the host:

```bash
oc debug node/<node> -- chroot /host bridge vlan show
```

Confirm `fw-internal` is unaffected — its port still shows only VLANs 123, 150.

**Exercise 6 — Localnet multi-VLAN VM.** Deploy `fw-dmz-localnet` from
section 5f with `cudn-vlan100` and `cudn-vlan200`. Verify the VM gets two
separate NICs (eth1, eth2), each untagged on its respective VLAN. Compare the
operational model with the bridge trunk approach from Exercise 4.

**Exercise 7 — Full comparison matrix.** After completing exercises 3–6, fill
in a comparison table with your observations:

| | Bridge CNI `vlanTrunk` | Localnet CUDN per-VLAN |
|---|---|---|
| Per-VM VLAN filtering | | |
| VLAN add without restart | | |
| NetworkPolicy enforced | | |
| Appliance compatibility | | |
| Bridge type on node | | |

---

## Comparison Matrix: OCP 4.21 Secondary Network Approaches

| Dimension | Bridge CNI `vlanTrunk` | Localnet CUDN (Access) |
|---|---|---|
| Bridge type | Linux bridge (`vlan_filtering`) | OVS bridge (`bridge-mappings`) |
| VM sees | One NIC, tagged 802.1Q frames | One NIC per VLAN, untagged |
| Per-VM VLAN selection | `vlanTrunk` array in NAD | Which CUDNs attached to VM |
| Guest NICs for 2-VLAN trunk | 1 | 2 |
| Firewall appliance compat | Good (802.1Q trunk) | Requires multi-NIC support |
| Add VLAN to one VM | Edit NAD + restart VM | New CUDN + restart VM |
| NetworkPolicy | Not enforced (bypasses OVN) | Enforced by OVN per-CUDN |
| Central management | Multus NADs | Kubernetes API (CUDN) |
| Live migration | Supported | Supported (OVN port binding migrates) |
| Packet tracing | `tcpdump` + `bridge vlan show` | `tcpdump` + `ovn-trace` |

---

## Consulting Decision Framework

| Use Case | Best Construct | Why |
|---|---|---|
| Firewall routing between internal VLANs and external trunk (few internal VLANs) | Model 4: Localnet CUDN (primary) + Bridge CNI `vlanTrunk` (secondary) | Clear int/ext boundary; NetworkPolicy on internal. Limited by NIC-per-VLAN on the firewall. |
| Firewall VM, 802.1Q trunk (single NIC only) | Bridge CNI `vlanTrunk` | Per-port VLAN allow-list; single trunk NIC for appliance |
| Tenant VM, per-VLAN access | Localnet CUDN (Access mode) | OVN NetworkPolicy; Kubernetes-native management |
| VM needing direct L2 to physical network | macvlan (bridge mode) via Multus | Lowest overhead, direct L2 (can't talk to host) |
| VM with many NICs, switch MAC limits | ipvlan L2 via Multus | Single MAC shared across sub-interfaces |
| Tenant isolation (namespace-scoped) | UDN Layer2 or Layer3 | Native OVN-K8s, built-in NetworkPolicy |
| High-performance SR-IOV passthrough | SR-IOV CNI + Multus | Bypasses kernel; needed for telco/NFV |
| East-west micro-segmentation | OVN ACLs via NetworkPolicy | Stateful firewall in OVS datapath |
| Live migration | UDN L2 or bridge | Requires L2 adjacency |

### The Punchline

> **There is no single "best" model — choose based on your constraints.**
>
> Each model trades off NIC count, VLAN scale, appliance compatibility,
> and policy enforcement. Ask three questions:
>
> 1. **How many free NICs/bonds per node?** (1 or 2)
> 2. **Does the firewall appliance require an 802.1Q trunk NIC?**
> 3. **How many internal VLANs does the firewall need to participate in?**
>
> Decision tree:
>
> - **1 NIC, appliance supports multi-NIC** → **Model 1: All Localnet
>   CUDN.** Simplest. One OVS bridge. NetworkPolicy on everything. Each
>   VLAN = one NIC on the firewall, so impractical above ~8 VLANs.
> - **1 NIC, appliance requires 802.1Q trunk** → **Model 2: All Bridge
>   CNI.** Linux bridge with `vlan_filtering`. No OVN NetworkPolicy on
>   secondary networks. Scales to many VLANs on a single trunk NIC.
> - **2 NICs, firewall trunks external + tenants on separate bridge** →
>   **Model 3: Hybrid.** Bridge CNI trunk for firewalls, Localnet CUDN
>   for tenants. Both as secondary networks alongside the default
>   cluster network.
> - **2 NICs, clear internal/external split, few internal VLANs** →
>   **Model 4: Internal/External Boundary.** Firewall uses a primary
>   Localnet CUDN (internal) + Bridge CNI trunk (external). Clean
>   security boundary. Limited by NIC-per-internal-VLAN on the firewall.

### Deployment Models

#### Model 1: All Localnet CUDN

Single OVS bridge, one NIC/bond. All VMs — firewall and tenant — attach via
Localnet CUDNs. The firewall gets multiple discrete NICs instead of a trunk.
Good fallback when only one NIC is available and the appliance supports
multi-NIC.

```
  ┌─────────────────────────────────────────────────────────┐
  │                    OCP Node                             │
  │                                                         │
  │  ┌─────────────┐   ┌─────────────┐   ┌──────────────┐  │
  │  │  fw-dmz VM  │   │ tenant-a VM │   │ tenant-b VM  │  │
  │  │  (firewall) │   │ (workload)  │   │ (workload)   │  │
  │  │             │   │             │   │              │  │
  │  │ eth1: VLAN  │   │ eth1: VLAN  │   │ eth1: VLAN   │  │
  │  │  100 untag  │   │  100 untag  │   │  200 untag   │  │
  │  │ eth2: VLAN  │   │             │   │              │  │
  │  │  200 untag  │   │             │   │              │  │
  │  └──────┬──────┘   └──────┬──────┘   └──────┬───────┘  │
  │         │                 │                  │          │
  │    cudn-vlan100      cudn-vlan100       cudn-vlan200   │
  │    cudn-vlan200                                        │
  │         │                 │                  │          │
  │  ┌──────┴─────────────────┴──────────────────┴───────┐  │
  │  │             ovs-bridge-trunk                      │  │
  │  │         (OVS bridge, bridge-mappings)             │  │
  │  └──────────────────────┬────────────────────────────┘  │
  │                         │                               │
  │                       ens4                              │
  │                  (physical uplink)                      │
  └─────────────────────────┴───────────────────────────────┘
```

#### Model 2: All Bridge CNI

Single Linux bridge, one NIC/bond. Firewall gets `vlanTrunk` NAD (802.1Q
trunk NIC). Tenant VMs get bridge CNI with `"vlan": <id>` (access ports).
No OVN NetworkPolicy on secondary networks.

#### Model 3: Hybrid (Two NICs Required)

Bridge CNI `vlanTrunk` on Linux bridge (NIC-A) for firewall trunks. Localnet
CUDN on OVS bridge (NIC-B) for tenant per-VLAN access with NetworkPolicy.

> **Critical constraint:** A physical NIC can only belong to one bridge at a
> time (Red Hat KB 7107272). Bridge CNI requires a Linux bridge; Localnet
> requires an OVS bridge. The hybrid model therefore requires **two NICs or
> bonds**, with the physical switch handling L2 forwarding between them.

```
  ┌───────────────────────────────────────────────────────────────────────┐
  │                         OCP Node                                     │
  │                                                                       │
  │  ┌─────────────┐            ┌─────────────┐   ┌──────────────┐       │
  │  │  fw-dmz VM  │            │ tenant-a VM │   │ tenant-b VM  │       │
  │  │  (firewall) │            │ (workload)  │   │ (workload)   │       │
  │  │ eth1: trunk │            │ eth1: VLAN  │   │ eth1: VLAN   │       │
  │  │  100,200    │            │  100 untag  │   │  200 untag   │       │
  │  └──────┬──────┘            └──────┬──────┘   └──────┬───────┘       │
  │         │                          │                  │               │
  │   Bridge CNI                  cudn-vlan100       cudn-vlan200        │
  │   vlanTrunk NAD                    │                  │               │
  │         │                          │                  │               │
  │  ┌──────┴──────────┐    ┌──────────┴──────────────────┴───────────┐  │
  │  │  br-secondary   │    │            ovs-bridge-trunk             │  │
  │  │  (Linux bridge) │    │            (OVS bridge)                 │  │
  │  └───────┬─────────┘    └────────────────┬────────────────────────┘  │
  │          │                               │                           │
  │       NIC-A                           NIC-B                          │
  │      (enp1s0)                        (enp2s0)                        │
  └──────────┼───────────────────────────────┼───────────────────────────┘
             │                               │
        ┌────┴───────────────────────────────┴────┐
        │          Physical Switch                 │
        │    (trunk ports, same VLANs)             │
        └──────────────────────────────────────────┘
```

Traffic between `fw-dmz` (VLAN 100 on Linux bridge) and `tenant-a` (VLAN 100
on OVS bridge) flows: Linux bridge → NIC-A → switch → NIC-B → OVS bridge →
OVN localnet port → tenant VM. The switch handles L2 forwarding on the shared
VLAN.

**Why this hybrid matters:** The hybrid model keeps firewall and tenant
traffic on separate bridge types, but the firewall is "just another VM with
a trunk NIC" — it doesn't participate in OVN's policy model. Model 4
improves on this by giving the firewall a primary Localnet CUDN so it
*also* lives inside the OVN-managed domain.

| | Firewall VM | Tenant workload VM |
|---|---|---|
| What the VM expects | Single 802.1Q trunk NIC | Simple untagged NIC |
| Attachment | Bridge CNI `vlanTrunk` NAD | Localnet CUDN |
| Bridge type | Linux bridge | OVS bridge |
| VLAN filtering | Per-NAD `vlanTrunk` array | Per-CUDN `vlan.access.id` |
| NetworkPolicy | Not enforced (bypasses OVN) | Enforced by OVN |
| Policy enforcement point | The firewall appliance itself | OVN ACLs + the firewall |

NetworkPolicy applies to the **tenant side**, not the firewall trunk. Traffic
between tenant VMs on different VLANs must traverse the firewall — it's the
firewall that decides what crosses VLAN boundaries, not OVN. OVN's role is
east-west micro-segmentation *within* each VLAN.

**Exercise — Hybrid deployment (Model 3).** Deploy all three VMs:

1. Create the Linux bridge (`br-secondary`) via NMState NNCP (section 5e-1).

2. Create the OVS bridge (`ovs-bridge-trunk`) with bridge-mappings (section 5e-2).

3. Create the Bridge CNI `vlanTrunk` NAD for the firewall:

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: trunk-dmz
  namespace: firewall-vms
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "trunk-dmz",
      "type": "bridge",
      "bridge": "br-secondary",
      "vlanTrunk": [
        { "id": 100 },
        { "id": 200 }
      ]
    }
```

4. Create Localnet CUDNs for each tenant VLAN (section 5e-2).

5. Deploy the firewall VM (Bridge CNI trunk) and two tenant VMs (Localnet CUDN):

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fw-dmz
  namespace: firewall-vms
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: trunk
              bridge: {}
        resources:
          requests:
            memory: 2Gi
      networks:
        - name: default
          pod: {}
        - name: trunk
          multus:
            networkName: firewall-vms/trunk-dmz
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: app-vm
  namespace: tenant-a
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: vlan100
              bridge: {}
        resources:
          requests:
            memory: 1Gi
      networks:
        - name: default
          pod: {}
        - name: vlan100
          multus:
            networkName: cudn-vlan100
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: db-vm
  namespace: tenant-b
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: vlan200
              bridge: {}
        resources:
          requests:
            memory: 1Gi
      networks:
        - name: default
          pod: {}
        - name: vlan200
          multus:
            networkName: cudn-vlan200
```

6. Verify bridge CNI VLAN filtering and OVS localnet ports:

```bash
oc debug node/<node> -- chroot /host bridge vlan show
oc debug node/<node> -- chroot /host ovs-vsctl show
```

7. Verify the firewall sees tagged trunk frames:

```bash
virtctl console fw-dmz
ip link add link eth1 name eth1.100 type vlan id 100
ip addr add 10.0.100.254/24 dev eth1.100
ip link set eth1.100 up
tcpdump -e -i eth1   # should see 802.1Q tags
```

8. Verify tenant VMs see untagged frames and have NetworkPolicy:

```bash
virtctl console app-vm
ip addr show eth1     # untagged VLAN 100, no VLAN sub-interfaces needed
```

9. Confirm that `app-vm` (VLAN 100) and `db-vm` (VLAN 200) cannot reach each
   other directly — they're on different VLANs. Cross-VLAN traffic must go
   through `fw-dmz` via the physical switch.

#### Model 4: Internal/External Boundary

A hybrid approach that combines Localnet CUDN and Bridge CNI `vlanTrunk`
into a clear **internal/external security boundary**, with the firewall VM
as the routing point between the two domains.

> **Scalability caveat:** Because Localnet UDN only supports Access mode
> (one VLAN per CUDN), each internal VLAN the firewall participates in
> requires a separate NIC on the VM. This works well with 2–5 internal
> VLANs but becomes impractical at scale. If the firewall needs 10+
> internal VLANs, consider Model 2 or Model 3 with a Bridge CNI trunk
> for the internal side as well.

**Core idea:**

- **Bond A → OVS bridge** — carries all *internal* tenant VLANs via
  Localnet CUDNs. OVN-Kubernetes manages these networks: NetworkPolicy,
  port security, and central visibility all apply. Every tenant VM and the
  firewall itself attach to this domain.
- **Bond B → Linux bridge** — carries the *external* physical network
  trunk via Bridge CNI `vlanTrunk`. Only the firewall VM has an interface
  here. This is the path to the upstream physical network (WAN, DMZ, data
  centre backbone).
- **The firewall VM** has a **primary Localnet CUDN** (replacing the
  default cluster network) for internal connectivity, plus additional
  secondary Localnet CUDNs for each internal VLAN, and a **secondary
  Bridge CNI `vlanTrunk`** interface for the external trunk.

The firewall routes between internal (OVN-managed, policy-enforced) and
external (physical trunk) networks. Tenant VMs never touch the external
bridge — they only see Localnet CUDNs. Cross-VLAN and external traffic
must traverse the firewall.

```
  ┌────────────────────────────────────────────────────────────────────────────────┐
  │                                  OCP Node                                     │
  │                                                                               │
  │  ┌──────────────────────────────────┐  ┌──────────────┐   ┌──────────────┐    │
  │  │         fw-dmz VM (firewall)     │  │ tenant-a VM  │   │ tenant-b VM  │    │
  │  │                                  │  │  (workload)  │   │  (workload)  │    │
  │  │ PRIMARY: cudn-vlan100            │  │              │   │              │    │
  │  │   eth0: VLAN 100 untagged        │  │ eth1: VLAN   │   │ eth1: VLAN   │    │
  │  │                                  │  │  100 untag   │   │  200 untag   │    │
  │  │ SECONDARY (internal):            │  │              │   │              │    │
  │  │   eth1: VLAN 200 untagged        │  │              │   │              │    │
  │  │   (cudn-vlan200)                 │  │              │   │              │    │
  │  │                                  │  │              │   │              │    │
  │  │ SECONDARY (external):            │  │              │   │              │    │
  │  │   eth2: 802.1Q trunk (300,400)   │  │              │   │              │    │
  │  │   (Bridge CNI vlanTrunk NAD)     │  │              │   │              │    │
  │  └─────┬───────────┬────────┬───────┘  └──────┬───────┘   └──────┬───────┘    │
  │        │           │        │                  │                  │            │
  │        │ Internal  │        │ External         │ Internal         │ Internal   │
  │        │ (primary) │        │ (trunk)          │                  │            │
  │   cudn-vlan100  cudn-vlan200│            cudn-vlan100       cudn-vlan200      │
  │        │           │        │                  │                  │            │
  │  ┌─────┴───────────┴────────┼──────────────────┴──────────────────┴─────────┐  │
  │  │         ovs-bridge-internal (OVS bridge, bridge-mappings)               │  │
  │  │         Bond A — all internal/tenant VLANs                              │  │
  │  └─────────────────┬───────────────────────────────────────────────────────┘  │
  │                    │        │                                                  │
  │                    │  ┌─────┴──────────────────┐                               │
  │                    │  │  br-external           │                               │
  │                    │  │  (Linux bridge)        │                               │
  │                    │  │  Bond B — external     │                               │
  │                    │  │  physical trunk         │                               │
  │                    │  └──────────┬──────────────┘                               │
  │                    │             │                                              │
  │                 Bond A        Bond B                                            │
  │                (enp1s0f0)    (enp2s0f0)                                         │
  └────────────────────┼─────────────┼─────────────────────────────────────────────┘
                       │             │
                  ┌────┴─────────────┴────┐
                  │    Physical Switch     │
                  │  (VLANs on both bonds) │
                  └───────────────────────┘
```

**Advantages of this approach:**

| Dimension | Model 4 advantage |
|---|---|
| Security boundary | Clear internal/external split. Tenant VMs never touch the external bridge. |
| Tenant simplicity | Tenants only see Localnet CUDNs — untagged NICs, no VLAN awareness. |
| NetworkPolicy | Applies on all internal VLANs (OVN-managed). External trunk is the firewall's domain. |
| Firewall visibility | Firewall has a primary UDN inside the OVN domain — OVN sees it as a first-class citizen. |
| External trunk | Standard 802.1Q trunk to the physical network — works with any upstream switch/router. |
| Scalability | Add external VLANs: edit the trunk NAD. Add internal VLANs: create new CUDNs — but each adds a NIC to the firewall VM (practical limit ~5–8). |
| Live migration | Supported on both sides — OVN port binding migrates (internal), bridge CNI migrates (external). |

**Implementation:**

**Step 1 — Namespace with primary UDN label** (must be set at creation time):

```bash
oc create namespace firewall-vms --dry-run=client -o yaml | \
  oc label --local -f - \
    k8s.ovn.org/primary-user-defined-network="" \
    --dry-run=client -o yaml | oc apply -f -
```

**Step 2 — Primary Localnet CUDN for the firewall's internal network:**

```yaml
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: cudn-internal-100
spec:
  namespaceSelector:
    matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values: ["firewall-vms", "tenant-a"]
  network:
    topology: Localnet
    localnet:
      role: Primary
      physicalNetworkName: internal-net
      vlan:
        mode: Access
        access:
          id: 100
      ipam:
        mode: Disabled
```

**Step 3 — Secondary Localnet CUDN for additional internal VLANs:**

```yaml
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: cudn-internal-200
spec:
  namespaceSelector:
    matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values: ["firewall-vms", "tenant-b"]
  network:
    topology: Localnet
    localnet:
      role: Secondary
      physicalNetworkName: internal-net
      vlan:
        mode: Access
        access:
          id: 200
      ipam:
        mode: Disabled
```

**Step 4 — External Linux bridge + Bridge CNI trunk NAD:**

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: br-external
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  desiredState:
    interfaces:
      - name: br-external
        type: linux-bridge
        state: up
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: enp2s0f0
              vlan:
                mode: trunk
                trunk-tags:
                  - id: 300
                  - id: 400
                  - id: 500
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: trunk-external
  namespace: firewall-vms
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "trunk-external",
      "type": "bridge",
      "bridge": "br-external",
      "vlanTrunk": [
        { "id": 300 },
        { "id": 400 },
        { "id": 500 }
      ]
    }
```

**Step 5 — OVS bridge with bridge-mappings for internal VLANs:**

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ovs-bridge-internal
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  desiredState:
    interfaces:
      - name: ovs-bridge-internal
        type: ovs-bridge
        state: up
        bridge:
          allow-extra-patch-ports: true
          options:
            stp: false
          port:
            - name: enp1s0f0
    ovn:
      bridge-mappings:
        - localnet: internal-net
          bridge: ovs-bridge-internal
          state: present
```

**Step 6 — Firewall VM:**

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fw-dmz
  namespace: firewall-vms
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: internal-100
              bridge: {}
            - name: internal-200
              bridge: {}
            - name: external-trunk
              bridge: {}
        resources:
          requests:
            memory: 4Gi
      networks:
        - name: internal-100
          pod: {}
        - name: internal-200
          multus:
            networkName: cudn-internal-200
        - name: external-trunk
          multus:
            networkName: firewall-vms/trunk-external
```

The firewall VM gets three interfaces:

- **eth0** — Primary Localnet CUDN (VLAN 100, untagged). This replaces
  the default cluster network. The firewall is a first-class OVN citizen
  on this VLAN, visible to NetworkPolicy.
- **eth1** — Secondary Localnet CUDN (VLAN 200, untagged). Another
  internal VLAN the firewall can route for.
- **eth2** — Bridge CNI `vlanTrunk` (VLANs 300, 400, 500 as 802.1Q
  trunk). The external physical network. The firewall creates
  sub-interfaces (`eth2.300`, `eth2.400`, `eth2.500`) to handle each
  external VLAN.

**Step 7 — Tenant VMs** (only internal — no external access):

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: app-vm
  namespace: tenant-a
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: vlan100
              bridge: {}
        resources:
          requests:
            memory: 1Gi
      networks:
        - name: default
          pod: {}
        - name: vlan100
          multus:
            networkName: cudn-internal-100
```

Tenant VMs attach only to internal Localnet CUDNs. They have no interface
on the external bridge. To reach external networks (VLAN 300, 400, 500)
they must route through `fw-dmz`.

**Step 8 — Verification:**

```bash
# Internal side — OVN port bindings
oc debug node/<node> -- chroot /host ovs-vsctl show
oc debug node/<node> -- chroot /host ovn-nbctl show

# External side — Linux bridge VLAN filtering
oc debug node/<node> -- chroot /host bridge vlan show

# Inside fw-dmz — configure external sub-interfaces
virtctl console fw-dmz
ip link add link eth2 name eth2.300 type vlan id 300
ip addr add 10.0.300.1/24 dev eth2.300
ip link set eth2.300 up

# Verify internal connectivity
ip addr show eth0    # VLAN 100 untagged (primary)
ip addr show eth1    # VLAN 200 untagged (secondary)

# Enable routing between internal and external
sysctl -w net.ipv4.ip_forward=1
# Add nftables/iptables rules as needed for the firewall policy
```

**Step 9 — Confirm tenant isolation:**

```bash
# From tenant-a: can reach fw-dmz on VLAN 100 (internal)
virtctl console app-vm
ping -c 3 <fw-dmz-eth0-ip>

# From tenant-a: cannot reach external VLANs directly
# (no interface on br-external, no route to 10.0.300.0/24)
# Must go through fw-dmz as the default gateway
```

**Exercise — Model 4 deployment.** Deploy the full stack:

1. Create namespaces: `firewall-vms` (with primary UDN label), `tenant-a`,
   `tenant-b`.
2. Create OVS bridge with bridge-mappings for internal VLANs (NNCP).
3. Create Linux bridge for external trunk (NNCP).
4. Create Localnet CUDNs for internal VLANs 100 and 200.
5. Create Bridge CNI `vlanTrunk` NAD for external VLANs 300, 400, 500.
6. Deploy `fw-dmz` with primary CUDN + secondary CUDN + external trunk.
7. Deploy tenant VMs with internal CUDNs only.
8. Verify: firewall sees both domains; tenants see only internal; cross-VLAN
   traffic goes through the firewall.

---

## Key Learnings

### `ovs-cni` is unsupported on OpenShift 4.14+

The `ovs-cni` plugin (`"type": "ovs"`) is not shipped with OpenShift since
the deprecation of OpenShift SDN. The binary does not exist on nodes. Use
**Bridge CNI `vlanTrunk`** for per-port VLAN filtering instead.

### Localnet UDN does NOT support trunk mode

The OCP 4.21 `ClusterUserDefinedNetwork` / `UserDefinedNetwork` Localnet
API only supports `vlan.mode: Access` (single VLAN per CUDN). There is no
`Trunk` mode, no trunk array, and no VLAN allow list.

**Sources:**
- OKD 4.21 REST API: `VLANMode` enum is `[Access]`
- Red Hat OCP 4.21 Network API docs: "Allowed value is 'Access'"
- OCP 4.21 Virtualization docs Table 10.1: "Layer 2 trunk access:
  Linux bridge CNI = Yes, OVN-Kubernetes localnet = **No**"
- Upstream OVN-Kubernetes OKEP-5085: Only describes Access VLAN config

### Bridge CNI and Localnet UDN use different bridge types

- **Bridge CNI** (`vlanTrunk`) operates on a **Linux bridge** with
  `vlan_filtering`. Configured via NMState NNCP (`type: linux-bridge`).
- **Localnet UDN** operates on an **OVS bridge** configured via NMState
  `bridge-mappings`. OVN-Kubernetes programs the OVS flows.
- A physical NIC can only belong to one bridge at a time (Red Hat KB 7107272).
- Therefore, the hybrid model (Model 3) requires two physical NICs or bonds.

### Multi-VLAN access for a single VM

To give a VM access to multiple VLANs:
- **Bridge CNI `vlanTrunk`:** Single trunk NIC carrying 802.1Q tagged frames.
  The VM creates VLAN sub-interfaces. One NAD per VLAN subset.
- **Localnet CUDN:** Multiple discrete untagged NICs, one per VLAN. The VM
  sees each as a separate interface. One CUDN per VLAN.

### Model selection

| Constraint | Suitable Model(s) |
|---|---|
| 1 NIC, appliance supports multi-NIC | Model 1 (All Localnet CUDN) |
| 1 NIC, appliance requires 802.1Q trunk | Model 2 (All Bridge CNI) |
| 2 NICs, firewall needs trunk + tenants need policy | Model 3 (Hybrid) or Model 4 (Internal/External Boundary) |
| 2 NICs, clear int/ext split, few internal VLANs (≤5) | Model 4 (Internal/External Boundary) |
| 2 NICs, many internal VLANs (10+) | Model 3 (Hybrid) — trunk scales better than NIC-per-VLAN |
| Need OVN NetworkPolicy per VLAN | Model 1, Model 3, or Model 4 |
| Only one free NIC on nodes | Model 1 or Model 2 (cannot do Model 3 or 4) |
| No firewall needed, just tenant isolation | Model 1 (All Localnet CUDN) |
