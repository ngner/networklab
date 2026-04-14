# Linux Networking & KubeVirt VLAN Trunk Lab Plan

## Goal

Build hands-on knowledge of native Linux networking constructs (linux bridge,
macvlan, ipvlan, OVS, OVN) so you can consult on the best network architecture
for KubeVirt VMs — specifically firewall VMs with VLAN trunks — in
OVN-Kubernetes environments (Multus, UDN).

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

## Phase 2: Open vSwitch (OVS)

OVS is a programmable software switch that replaces (or sits alongside) Linux
bridges. On its own it's useful — trunk ports, mirrors, flow-based forwarding —
but the real reason to learn it here is that **OVS is the datapath for
OVN-Kubernetes**, which is the default CNI in OpenShift.

On every OCP node, OVN-Kubernetes creates an OVS bridge called `br-int`
(integration bridge) and programs OpenFlow rules into it to implement pod
networking, NetworkPolicy, and services. When you run `ovs-ofctl dump-flows
br-int` on an OCP node, you're looking at the same flow tables you'll learn
to read in this phase.

The connection to what comes later in Phase 5:

- **Multus secondary networks** that use the OVS CNI plugin create ports on
  an OVS bridge on the node — the same `ovs-vsctl add-port` with `tag=` or
  `trunks=` you'll use below.
- **UDN (User Defined Networks)** with **localnet topology** maps an OVN
  logical switch to a physical network by creating a `localnet` port that
  bridges OVN's overlay onto a node-local OVS bridge. That bridge has a
  physical NIC (or VLAN subinterface) as its uplink — the exact pattern you
  build in this phase with `ovsbr0` and `dummy0`.
- **OVN** (Phase 4) adds the logical control plane on top: logical switches,
  routers, and ACLs that get compiled down into OVS flows. Understanding OVS
  flows first means you can debug OVN-Kubernetes problems by reading the
  datapath directly.

Everything in this phase maps 1:1 to real OCP node networking — the bridge
name and scale differ, but the mechanics are identical.

### 2a. Install and Basic Bridge

```bash
dnf install -y openvswitch libibverbs
systemctl enable --now openvswitch

ovs-vsctl add-br ovsbr0
ovs-vsctl add-port ovsbr0 dummy0
```

### 2b. OVS VLAN Ports with Namespaces

```bash
# Create namespaces and veth pairs
for ns in ovs-a ovs-b ovs-c; do
  ip netns add $ns
  ip link add veth-${ns} type veth peer name veth-${ns}-br
  ip link set veth-${ns} netns $ns
  ip link set veth-${ns}-br up
done

# Access port: VLAN 100
ovs-vsctl add-port ovsbr0 veth-ovs-a-br -- set port veth-ovs-a-br tag=100
ip netns exec ovs-a ip addr add 10.0.100.1/24 dev veth-ovs-a
ip netns exec ovs-a ip link set veth-ovs-a up

# Access port: VLAN 200
ovs-vsctl add-port ovsbr0 veth-ovs-b-br -- set port veth-ovs-b-br tag=200
ip netns exec ovs-b ip addr add 10.0.200.1/24 dev veth-ovs-b
ip netns exec ovs-b ip link set veth-ovs-b up

# Trunk port: VLANs 100 + 200 (firewall guest)
ovs-vsctl add-port ovsbr0 veth-ovs-c-br -- set port veth-ovs-c-br trunks=100,200
ip netns exec ovs-c ip link set veth-ovs-c up
ip netns exec ovs-c ip link add link veth-ovs-c name veth-ovs-c.100 type vlan id 100
ip netns exec ovs-c ip addr add 10.0.100.254/24 dev veth-ovs-c.100
ip netns exec ovs-c ip link set veth-ovs-c.100 up
ip netns exec ovs-c ip link add link veth-ovs-c name veth-ovs-c.200 type vlan id 200
ip netns exec ovs-c ip addr add 10.0.200.254/24 dev veth-ovs-c.200
ip netns exec ovs-c ip link set veth-ovs-c.200 up

# Test: access guest on VLAN 100 can reach trunk guest's .100 sub-interface
ip netns exec ovs-a ping -c 2 10.0.100.254

# Test: access guest on VLAN 200 can reach trunk guest's .200 sub-interface
ip netns exec ovs-b ping -c 2 10.0.200.254

# Test: VLAN 100 guest cannot reach VLAN 200 guest directly
ip netns exec ovs-a ping -c 2 10.0.200.1  # fails
```

### 2c. OVS Flows and Debugging

```bash
# See all flows
ovs-ofctl dump-flows ovsbr0

# Trace a specific packet through the pipeline
ovs-appctl ofproto/trace ovsbr0 \
  "in_port=veth-ovs-c-br,dl_vlan=100,dl_src=aa:bb:cc:dd:ee:01,dl_dst=ff:ff:ff:ff:ff:ff"

# Show port configuration
ovs-vsctl list port veth-ovs-c-br
```

```bash
# Cleanup
for ns in ovs-a ovs-b ovs-c; do ip netns del $ns; done
ovs-vsctl del-br ovsbr0
```

---

## Phase 3: Trunk-to-Guest — OVS vs Bridge Side-by-Side

This is the core comparison for KubeVirt firewall VM consultation. Build both
approaches with the **same heterogeneous guest scenario** and compare.

### Test Scenario: Four Guests, Different VLAN Sets

| Guest | Role | Allowed VLANs | Type |
|---|---|---|---|
| `fw-dmz` | DMZ firewall | 100, 200 | Trunk |
| `fw-internal` | Internal firewall | 123, 150 | Trunk |
| `monitor` | IDS/tap | 100, 123, 150, 200 | Read-only mirror |
| `tenant-a` | Tenant workload | 100 | Access (untagged) |

### 3a. Helper: Create Namespaces and veth Pairs

Run this once — both the bridge and OVS setups use the same namespaces.

```bash
for ns in fw-dmz fw-internal monitor tenant-a; do
  ip netns add $ns
done
```

For each test (bridge then OVS), create fresh veth pairs, run the exercises,
then clean up the veths before switching to the other datapath.

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

### 3d. OVS Setup

```bash
ovs-vsctl add-br ovsbr0
ovs-vsctl add-port ovsbr0 dummy0

# --- fw-dmz: trunk VLANs 100, 200 ---
ip link add veth-dmz type veth peer name veth-dmz-br
ip link set veth-dmz netns fw-dmz
ip link set veth-dmz-br up
ovs-vsctl add-port ovsbr0 veth-dmz-br -- set port veth-dmz-br trunks=100,200

ip netns exec fw-dmz ip link set veth-dmz up
ip netns exec fw-dmz ip link add link veth-dmz name veth-dmz.100 type vlan id 100
ip netns exec fw-dmz ip addr add 10.0.100.1/24 dev veth-dmz.100
ip netns exec fw-dmz ip link set veth-dmz.100 up
ip netns exec fw-dmz ip link add link veth-dmz name veth-dmz.200 type vlan id 200
ip netns exec fw-dmz ip addr add 10.0.200.1/24 dev veth-dmz.200
ip netns exec fw-dmz ip link set veth-dmz.200 up

# --- fw-internal: trunk VLANs 123, 150 ---
ip link add veth-int type veth peer name veth-int-br
ip link set veth-int netns fw-internal
ip link set veth-int-br up
ovs-vsctl add-port ovsbr0 veth-int-br -- set port veth-int-br trunks=123,150

ip netns exec fw-internal ip link set veth-int up
ip netns exec fw-internal ip link add link veth-int name veth-int.123 type vlan id 123
ip netns exec fw-internal ip addr add 10.0.123.1/24 dev veth-int.123
ip netns exec fw-internal ip link set veth-int.123 up
ip netns exec fw-internal ip link add link veth-int name veth-int.150 type vlan id 150
ip netns exec fw-internal ip addr add 10.0.150.1/24 dev veth-int.150
ip netns exec fw-internal ip link set veth-int.150 up

# --- monitor: trunk all VLANs ---
ip link add veth-mon type veth peer name veth-mon-br
ip link set veth-mon netns monitor
ip link set veth-mon-br up
ovs-vsctl add-port ovsbr0 veth-mon-br \
  -- set port veth-mon-br trunks=100,123,150,200

ip netns exec monitor ip link set veth-mon up
for vid in 100 123 150 200; do
  ip netns exec monitor ip link add link veth-mon name veth-mon.${vid} type vlan id $vid
  ip netns exec monitor ip addr add 10.0.${vid}.254/24 dev veth-mon.${vid}
  ip netns exec monitor ip link set veth-mon.${vid} up
done

# --- tenant-a: access port, VLAN 100 ---
ip link add veth-tena type veth peer name veth-tena-br
ip link set veth-tena netns tenant-a
ip link set veth-tena-br up
ovs-vsctl add-port ovsbr0 veth-tena-br -- set port veth-tena-br tag=100

ip netns exec tenant-a ip addr add 10.0.100.10/24 dev veth-tena
ip netns exec tenant-a ip link set veth-tena up

# --- Verify ---
ovs-vsctl show

# tenant-a (access VLAN 100) reaches fw-dmz's VLAN 100 sub-interface
ip netns exec tenant-a ping -c 2 10.0.100.1
```

**Read-only monitor** — same flow table as forwarding (no separate subsystem):

```bash
ovs-ofctl add-flow ovsbr0 "priority=100,in_port=veth-mon-br,actions=drop"
```

Or as a proper SPAN mirror:

```bash
ovs-vsctl -- --id=@p get port veth-mon-br \
  -- --id=@m create mirror name=all-vlans \
     select-vlan=100,123,150,200 \
     output-port=@p
```

```bash
# Cleanup
for ns in fw-dmz fw-internal monitor tenant-a; do ip netns del $ns; done
ovs-vsctl del-br ovsbr0
```

### 3e. Lab Exercises (Run Against Both Setups)

Rebuild namespaces between each test. Run each exercise on the VLAN-aware
bridge first, then OVS, and note the differences.

**Exercise 1 — Baseline connectivity.** Verify all four guests have the
correct connectivity: `tenant-a` reaches `fw-dmz` on VLAN 100 only, `fw-dmz`
and `fw-internal` are isolated from each other, `monitor` can see all VLANs.

**Exercise 2 — Day-2 VLAN change.** Add VLAN 300 to `fw-dmz`:

```bash
# OVS: one atomic, persisted command — no guest-side change
ovs-vsctl set port veth-dmz-br trunks=100,200,300

# VLAN-aware bridge: live but NOT persisted across reboot
bridge vlan add vid 300 dev veth-dmz-br

# VLAN-unaware bridge: create br-300, new veth pair, new namespace
# interface — disruptive, guest must be reconfigured
```

Then inside fw-dmz (same for both bridge and OVS):

```bash
ip netns exec fw-dmz ip link add link veth-dmz name veth-dmz.300 type vlan id 300
ip netns exec fw-dmz ip addr add 10.0.300.1/24 dev veth-dmz.300
ip netns exec fw-dmz ip link set veth-dmz.300 up
```

Reboot the Fedora VM and check: OVS config survives (OVSDB). Bridge config
is gone.

**Exercise 3 — Prove VLAN isolation.** From `fw-dmz`, send a tagged frame on
VLAN 123 (not in its allowed set). Verify it never reaches `fw-internal`.

```bash
# OVS: prove without generating traffic
ovs-appctl ofproto/trace ovsbr0 \
  "in_port=veth-dmz-br,dl_vlan=123,dl_src=aa:bb:cc:dd:ee:01,dl_dst=ff:ff:ff:ff:ff:ff"
# Output shows: dropped

# Bridge: must use tcpdump — run on the fw-internal side and check for absence
ip netns exec fw-internal tcpdump -c 5 -i veth-int &
ip netns exec fw-dmz ip link add link veth-dmz name veth-dmz.123 type vlan id 123
ip netns exec fw-dmz ip addr add 10.0.123.99/24 dev veth-dmz.123
ip netns exec fw-dmz ip link set veth-dmz.123 up
ip netns exec fw-dmz ping -c 3 10.0.123.1
# tcpdump shows nothing — but absence of evidence is not evidence of absence
```

**Exercise 4 — Passive monitor.** Generate traffic between `tenant-a` and
`fw-dmz` on VLAN 100. Verify `monitor` sees it on `veth-mon.100`. Then try
to inject a frame from `monitor` and verify it's dropped by the ingress flow
(OVS) or nftables rule (bridge).

**Exercise 5 — Asymmetric expansion.** Give `fw-internal` access to VLAN 100
in addition to 123/150:

```bash
# OVS
ovs-vsctl set port veth-int-br trunks=100,123,150

# VLAN-aware bridge
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

### 3f. Performance Testing

```bash
dnf install -y iperf3 sockperf
```

**Throughput** (expect near-identical at small scale):

```bash
# In one namespace (server):
ip netns exec tenant-a iperf3 -s

# In another (client on same VLAN):
ip netns exec fw-dmz iperf3 -c 10.0.100.1 -t 30 -P 4
# (use fw-dmz's 10.0.100.x address to stay on VLAN 100)
```

Run for: VLAN-aware bridge, then OVS. Compare.

**Latency** (more revealing — OVS has marginally higher per-packet cost from
flow table lookup):

```bash
ip netns exec tenant-a sockperf server --tcp
ip netns exec fw-dmz sockperf ping-pong -i 10.0.100.10 --tcp -t 30
```

**Flow table scaling** (OVS megaflow cache vs bridge MAC FDB):

```bash
ovs-dpctl dump-flows              # OVS datapath flows
bridge fdb show dev br-trunk      # bridge forwarding DB
```

### 3g. Operational Tooling Comparison

**SPAN/mirror a VLAN for debugging:**

```bash
# OVS: native, one command, no traffic disruption
ovs-vsctl -- set bridge ovsbr0 mirrors=@m \
  -- --id=@m create mirror name=vlan100-mirror \
     select-vlan=100 output-port=@p \
  -- --id=@p get port veth-mon-br _uuid

# Linux bridge: tc mirred (fragile, separate subsystem)
tc qdisc add dev br-trunk ingress
tc filter add dev br-trunk parent ffff: protocol 802.1q \
  u32 match u16 0x0064 0x0fff at -2 \
  action mirred egress mirror dev veth-mon-br
```

**Rate limiting per guest:**

```bash
# OVS: first-class port policing
ovs-vsctl set interface veth-dmz-br ingress_policing_rate=1000000
ovs-vsctl set interface veth-dmz-br ingress_policing_burst=100000

# Linux bridge: tc
tc qdisc add dev veth-dmz-br root tbf rate 1gbit burst 100kb latency 10ms
```

**Packet tracing:**

```bash
# OVS: full pipeline simulation without generating traffic
ovs-appctl ofproto/trace ovsbr0 \
  "in_port=veth-dmz-br,dl_vlan=100,dl_src=aa:bb:cc:dd:ee:01,dl_dst=ff:ff:ff:ff:ff:ff"

# Linux bridge: tcpdump at each hop is the only option
```

---

## Phase 4: OVN (Control Plane for OVS)

Still on the Fedora lab VM. OVN adds a logical networking layer on top of OVS.

### 4a. Install Standalone OVN

```bash
dnf install -y ovn ovn-central ovn-host
systemctl enable --now ovn-northd ovsdb-server-nb ovsdb-server-sb ovn-controller
```

### 4b. Create Logical Topology

```bash
# Logical switch (like a VLAN segment or UDN L2 network)
ovn-nbctl ls-add tenant1

# Logical ports (like pod interfaces)
ovn-nbctl lsp-add tenant1 port1
ovn-nbctl lsp-set-addresses port1 "aa:bb:cc:dd:ee:01 10.0.0.1"
ovn-nbctl lsp-add tenant1 port2
ovn-nbctl lsp-set-addresses port2 "aa:bb:cc:dd:ee:02 10.0.0.2"

# Logical router (like a UDN L3 topology or cluster gateway)
ovn-nbctl lr-add router1
ovn-nbctl lrp-add router1 rtr-tenant1 aa:bb:cc:dd:ee:ff 10.0.0.254/24

# Connect router to switch
ovn-nbctl lsp-add tenant1 tenant1-rtr
ovn-nbctl lsp-set-type tenant1-rtr router
ovn-nbctl lsp-set-addresses tenant1-rtr router
ovn-nbctl lsp-set-options tenant1-rtr router-port=rtr-tenant1

# ACLs (like NetworkPolicy)
ovn-nbctl acl-add tenant1 to-lport 1000 'outport == "port1" && ip4.src == 10.0.0.2' allow
ovn-nbctl acl-add tenant1 to-lport 900 'outport == "port1"' drop

# Inspect
ovn-nbctl show
ovn-sbctl show
```

### 4c. OVN → OVN-Kubernetes Concept Mapping

| OVN Concept | Kubernetes Equivalent |
|---|---|
| Logical Switch | Namespace network / UDN L2 segment |
| Logical Router | UDN L3 topology / cluster default gateway |
| Logical Switch Port | Pod network interface |
| ACLs | NetworkPolicy / AdminNetworkPolicy |
| Localnet port | Physical network attachment (VLAN trunk to node NIC) |

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
            - name: ens4
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

**Localnet topology** — maps UDN to a physical VLAN (the OVN equivalent of
Multus bridge CNI, but managed centrally via OVN):

```yaml
apiVersion: k8s.ovn.org/v1
kind: UserDefinedNetwork
metadata:
  name: phys-vlan100
  namespace: default
spec:
  topology: Localnet
  localnet:
    role: Secondary
    subnets:
      - cidr: 10.0.100.0/24
    physicalNetworkName: physnet1
```

The `physicalNetworkName` maps to an OVS bridge mapping configured on the
nodes. This is how OVN-Kubernetes exposes physical VLANs to pods/VMs.

### 5f. KubeVirt VMs with Network Attachments

**Firewall VM with trunk via Multus bridge CNI:**

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
            networkName: trunk-bridge
```

Inside the VM, create VLAN sub-interfaces just like in Phase 1:

```bash
ip link add link eth1 name eth1.100 type vlan id 100
ip link add link eth1 name eth1.200 type vlan id 200
```

**VM with UDN localnet (physical VLAN via OVN):**

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: tenant-vm
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
            - name: physnet
              bridge: {}
        resources:
          requests:
            memory: 2Gi
      networks:
        - name: default
          pod: {}
        - name: physnet
          multus:
            networkName: phys-vlan100
```

### 5g. OCP Exercises

**Exercise 1 — NAD matrix.** Create NADs for bridge, macvlan, and ipvlan.
Attach plain pods to each. Document: interface name inside the pod, MAC
address, whether the pod can reach the host, whether pods on different nodes
can reach each other.

**Exercise 2 — UDN vs Multus.** Create the same L2 segment as both a Multus
bridge NAD and a UDN Layer2. Attach pods to each. Compare: how is IPAM
handled, how does NetworkPolicy apply, what shows up in `ovn-nbctl show`.

**Exercise 3 — KubeVirt firewall VM.** Deploy the `fw-dmz` VM above. Verify
trunk delivery: `virtctl console fw-dmz`, then inside the VM run
`tcpdump -e -i eth1` and confirm tagged frames arrive.

**Exercise 4 — Heterogeneous trunks on OCP.** Deploy `fw-dmz` (VLANs
100,200) and `fw-internal` (VLANs 123,150) as KubeVirt VMs. Each uses a
different NAD. Verify isolation between them — traffic on VLAN 123 from
`fw-internal` must not appear on `fw-dmz`.

**Exercise 5 — Day-2 on OCP.** Add VLAN 300 to `fw-dmz`. With bridge CNI
this means editing the NAD or creating a new one. With OVS/OVN localnet this
means updating the bridge mapping. Compare the operational workflow.

---

## Comparison Matrix: Heterogeneous Trunk-to-Guest

| Dimension | Bridge (per-VLAN) | Bridge (VLAN-aware) | OVS |
|---|---|---|---|
| Per-guest VLAN selection | Which bridges attached | `bridge vlan` per port | `trunks=X,Y,Z` per port |
| Guest NICs for 2-VLAN trunk | 2 | 1 | 1 |
| Guest NICs for 4-VLAN trunk | 4 | 1 | 1 |
| Firewall appliance compat | Poor (discrete NICs) | Good (802.1Q trunk) | Good (802.1Q trunk) |
| Add VLAN to one guest | New bridge + NIC (disruptive) | `bridge vlan add` (live, not persisted) | `ovs-vsctl set port` (live, persisted) |
| Persistence across reboot | nmcli/libvirt (natural) | Requires external scripting | OVSDB (native) |
| Read-only mirror port | Not possible | nftables (separate subsystem) | Native mirror or drop flow |
| Prove isolation without traffic | Not possible | Not possible | `ofproto/trace` |
| SPAN/mirror | `tc mirred` (fragile) | `tc mirred` (fragile) | Native `ovs-vsctl mirror` |
| QoS | `tc` | `tc` | Native per-port policing |
| Packet tracing | `tcpdump` only | `tcpdump` + `bridge vlan show` | `ofproto/trace` (full pipeline) |
| Central management | None | None | OVN northbound DB / OVN-K8s |
| Scale (100s of VMs) | Bridge sprawl | Single bridge, reasonable | Best — flow caching, OVN |

---

## Consulting Decision Framework

| Use Case | Best Construct | Why |
|---|---|---|
| Firewall VM, static VLANs | VLAN-aware Linux bridge + bridge CNI | Simplest, lowest latency |
| Firewall VM, dynamic/heterogeneous VLANs | OVS trunk ports + OVS CNI or OVN localnet | Declarative, persisted, verifiable per-port trunk lists |
| VM needing direct L2 to physical network | macvlan (bridge mode) via Multus | Lowest overhead, direct L2 (can't talk to host) |
| VM with many NICs, switch MAC limits | ipvlan L2 via Multus | Single MAC shared across sub-interfaces |
| Tenant isolation (namespace-scoped) | UDN Layer2 or Layer3 | Native OVN-K8s, built-in NetworkPolicy |
| High-performance SR-IOV passthrough | SR-IOV CNI + Multus | Bypasses kernel; needed for telco/NFV |
| East-west micro-segmentation | OVN ACLs via NetworkPolicy | Stateful firewall in OVS datapath |
| Live migration | UDN L2 or bridge | Requires L2 adjacency |

### The Punchline

> **Will different VMs need different VLAN subsets, and will those subsets
> change over time?**
>
> - **No** → VLAN-aware Linux bridge with bridge CNI. Simplest, lowest latency.
> - **Yes** → OVS. Per-port trunk lists are declarative, persistent, atomically
>   updatable, and verifiable without generating traffic. The marginal latency
>   cost is irrelevant next to the operational cost of managing heterogeneous
>   VLAN assignments with `bridge vlan` commands and custom persistence scripts.
> - **At scale with OVN-Kubernetes** → OVS is non-negotiable. UDN with
>   `localnet` topology exposes physical VLANs to KubeVirt VMs through OVN
>   logical ports, giving trunk capability + NetworkPolicy + central management
>   through the Kubernetes API.
