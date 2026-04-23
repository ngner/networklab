# VM Networking on OpenShift: A Consultant's Lab Guide

## How to Use This Guide

This lab builds knowledge bottom-up — from Linux bridge primitives to
OVN-Kubernetes — so you can advise customers on the right network
architecture for KubeVirt VMs on OpenShift 4.17+.

**The three VM personas** frame every decision in this guide:

| Persona | Description | Examples |
|---|---|---|
| **Normal VM** | Workload VM needing a simple IP on one or more VLANs | App servers, databases, web frontends |
| **VPC-like Tenant VM** | Namespace-isolated VM with NetworkPolicy and persistent IPs | SaaS tenants, dev/test environments |
| **Network Appliance** | Firewall/router/LB expecting a raw 802.1Q trunk NIC | pfSense, VyOS, F5, Palo Alto |

**Companion materials:**

- **[cheatsheet.md](cheatsheet.md)** — standalone 2-page printable
  constraint/decision reference. Pull this out during engagements.
- **[slides.html](slides.html)** — Reveal.js visual explainer deck.

### Lab Environment

- **Fedora lab VM**: fresh install, single NIC (`eth0`). All Phase 1–3
  exercises run here using network namespaces to simulate guests. No nested
  VMs required — namespaces are faster to iterate with and expose the same
  kernel datapath.
- **OpenShift 4.21 cluster**: SNO + 2 workers. OVN-Kubernetes default CNI,
  Multus included. Used for Phase 5 (Kubernetes-level constructs, KubeVirt).

Throughout this plan, network namespaces stand in for "guests." Every namespace
gets a veth pair — one end in the namespace (the "guest NIC"), one end plugged
into the bridge under test. This is the same model Kubernetes uses for pods.

A `dummy0` interface acts as the simulated physical uplink so we don't
interfere with the VM's real connectivity on `eth0`.

### Bootstrap the Fedora Lab VM

```bash
dnf install -y iproute bridge-utils iperf3 tcpdump nftables

ip link add dummy0 type dummy
ip link set dummy0 up
```

---

## Phase 1: Linux Networking Primitives — This Is How Kubernetes Works

The Linux kernel has built-in virtual networking constructs — bridges, macvlan,
ipvlan — that have been stable for over a decade. They require no extra
packages; they're compiled into the kernel and configured with `ip link` and
`bridge` commands. On an OpenShift node, these are what sit behind the
**bridge CNI plugin** when you create a Multus `NetworkAttachmentDefinition`.
CNAO (ClusterNetworkAddonOperator, part of OpenShift) uses them to give Pods
or KubeVirt VMs direct L2 access to physical networks, **bypassing the
OVN-Kubernetes overlay entirely**.

Understanding these primitives matters because they are the mechanism behind
the **linux-bridge NAD** — the recommended attachment for Normal VMs and
Network Appliances. In Phase 2 you'll learn OVS — which is also a software
switch, but programmable, with flow tables, and the datapath that
OVN-Kubernetes controls for the **CUDN Localnet** and **UDN Layer2**
attachments used by VPC-like Tenant VMs.

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
ip netns add guest-a
ip netns add guest-b

ip link add veth-a type veth peer name veth-a-br
ip link add veth-b type veth peer name veth-b-br

ip link set veth-a netns guest-a
ip link set veth-b netns guest-b

ip netns exec guest-a ip addr add 10.0.0.1/24 dev veth-a
ip netns exec guest-a ip link set veth-a up
ip netns exec guest-a ip link set lo up

ip netns exec guest-b ip addr add 10.0.0.2/24 dev veth-b
ip netns exec guest-b ip link set veth-b up
ip netns exec guest-b ip link set lo up

# The -br ends are up but not bridged — guests cannot reach each other yet
ip netns exec guest-a ping -c 2 10.0.0.2  # fails: no path between the two pairs
```

The `-br` ends stay in the host namespace — these plug into bridges below.
Without a bridge connecting `veth-a-br` and `veth-b-br`, the two namespaces
are completely isolated even though they have the same subnet addresses.

### 1b. Linux Bridge — VLAN-Unaware (one bridge per VLAN)

The simplest model. Each VLAN gets its own bridge. Guests on the same bridge
see each other; guests on different bridges are isolated.

```bash
ip link add br-100 type bridge
ip link set br-100 up
ip link add br-200 type bridge
ip link set br-200 up

ip link set veth-a-br master br-100
ip link set veth-a-br up
ip link set veth-b-br master br-200
ip link set veth-b-br up

# Different bridges — no connectivity
ip netns exec guest-a ping -c 2 10.0.0.2  # fails

# Add guest-c to br-100 to prove same-bridge connectivity
ip netns add guest-c
ip link add veth-c type veth peer name veth-c-br
ip link set veth-c netns guest-c
ip netns exec guest-c ip addr add 10.0.0.3/24 dev veth-c
ip netns exec guest-c ip link set veth-c up
ip link set veth-c-br master br-100
ip link set veth-c-br up

ip netns exec guest-a ping -c 2 10.0.0.3  # succeeds
```

**Persona impact**: A Network Appliance expecting a single 802.1Q trunk
interface cannot work with this model — it sees discrete untagged NICs instead
of tagged frames on a single NIC.

```bash
ip netns del guest-a; ip netns del guest-b; ip netns del guest-c
ip link del br-100; ip link del br-200
```

### 1c. Linux Bridge — VLAN-Aware (single bridge, per-port filtering)

This is what the **bridge CNI plugin** uses under the hood when you create a
`NetworkAttachmentDefinition` on OpenShift. One bridge carries all VLANs;
per-port rules control which VLANs each guest sees.

By default, a Linux bridge is **VLAN-unaware** — it forwards all frames
regardless of 802.1Q tags. Setting `vlan_filtering 1` activates the bridge's
**per-port VLAN table**. Each port now has an explicit list of allowed VLAN IDs.
Frames tagged with a VLAN not in the port's list are dropped at ingress.
Ports can be configured as:

- **Trunk**: carries multiple VLANs, frames remain 802.1Q tagged
- **Access** (`pvid untagged`): strips the VLAN tag on egress so the guest
  sees untagged frames, and tags untagged ingress frames with the PVID

```bash
ip link add br-trunk type bridge vlan_filtering 1
ip link set br-trunk up

ip link set dummy0 master br-trunk
bridge vlan add vid 100 dev dummy0
bridge vlan add vid 200 dev dummy0

# guest-a: trunk port, VLANs 100 + 200 (receives tagged 802.1Q frames)
ip netns add guest-a
ip link add veth-a type veth peer name veth-a-br
ip link set veth-a netns guest-a
ip link set veth-a-br master br-trunk
ip link set veth-a-br up
bridge vlan del vid 1 dev veth-a-br
bridge vlan add vid 100 dev veth-a-br
bridge vlan add vid 200 dev veth-a-br

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

ip netns exec guest-b ip addr add 10.0.100.2/24 dev veth-b
ip netns exec guest-b ip link set veth-b up

# guest-b (access VLAN 100) can reach guest-a's VLAN 100 sub-interface
ip netns exec guest-b ping -c 2 10.0.100.1  # succeeds

bridge vlan show
```

**Persona impact**: guest-a is a **Network Appliance** — single trunk NIC with
VLAN sub-interfaces. guest-b is a **Normal VM** — untagged access on one VLAN.
On OpenShift, the bridge CNI NAD with `"vlan": 0` delivers this trunk model.

```bash
ip netns del guest-a; ip netns del guest-b
ip link del br-trunk
```

### 1d. macvlan

```bash
ip link add macvlan0 link dummy0 type macvlan mode bridge
ip link add macvlan1 link dummy0 type macvlan mode bridge

ip netns add mv-a
ip netns add mv-b
ip link set macvlan0 netns mv-a
ip link set macvlan1 netns mv-b

ip netns exec mv-a ip addr add 10.0.50.1/24 dev macvlan0
ip netns exec mv-a ip link set macvlan0 up
ip netns exec mv-b ip addr add 10.0.50.2/24 dev macvlan1
ip netns exec mv-b ip link set macvlan1 up

ip netns exec mv-a ping -c 2 10.0.50.2

# Host CANNOT reach macvlan sub-interfaces — by design
ping -c 2 10.0.50.1  # fails
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

ip link add ipvlan0 link dummy0 type ipvlan mode l2
ip link add ipvlan1 link dummy0 type ipvlan mode l2
ip link set ipvlan0 netns iv-a
ip link set ipvlan1 netns iv-b

ip netns exec iv-a ip addr add 10.0.60.1/24 dev ipvlan0
ip netns exec iv-a ip link set ipvlan0 up
ip netns exec iv-b ip addr add 10.0.60.2/24 dev ipvlan1
ip netns exec iv-b ip link set ipvlan1 up

ip netns exec iv-a ip link show ipvlan0
ip netns exec iv-b ip link show ipvlan1
ip link show dummy0
```

Key difference from macvlan: single MAC address (the parent's). Useful when
the upstream switch has MAC-per-port limits. Avoids MAC table exhaustion on
large KubeVirt clusters.

```bash
ip netns del iv-a; ip netns del iv-b
```

### 1f. Exercises

**Exercise 1 — Persona mapping.** Build a VLAN-aware bridge with three guests:
a trunk port (Network Appliance), an access port (Normal VM), and a macvlan
namespace (lightweight L2). Document which persona each represents and why.

**Exercise 2 — Trunk vs access.** Verify that the trunk guest sees 802.1Q
tagged frames while the access guest sees untagged. Use `tcpdump -e` to
confirm.

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

> **Important (OCP 4.17+):** The `ovs-cni` plugin binary that allowed creating
> `"type": "ovs"` NADs is **no longer shipped**. OVN-Kubernetes now manages all
> OVS bridges exclusively. OVS is still the datapath, but pods/VMs attach to it
> via **CUDN Localnet** (Phase 5), not via direct OVS CNI NADs. This phase
> teaches OVS fundamentals so you can debug OVN-Kubernetes flows — not so you
> can create OVS CNI NADs on OCP.

### 2a. Install and Basic Bridge

```bash
dnf install -y openvswitch libibverbs
systemctl enable --now openvswitch

ovs-vsctl add-br ovsbr0
ovs-vsctl add-port ovsbr0 dummy0
```

### 2b. OVS VLAN Ports with Namespaces

```bash
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

ip netns exec ovs-a ping -c 2 10.0.100.254
ip netns exec ovs-b ping -c 2 10.0.200.254
ip netns exec ovs-a ping -c 2 10.0.200.1  # fails — VLAN isolation
```

### 2c. OVS Flows and Debugging

```bash
ovs-ofctl dump-flows ovsbr0

ovs-appctl ofproto/trace ovsbr0 \
  "in_port=veth-ovs-c-br,dl_vlan=100,dl_src=aa:bb:cc:dd:ee:01,dl_dst=ff:ff:ff:ff:ff:ff"

ovs-vsctl list port veth-ovs-c-br
```

```bash
for ns in ovs-a ovs-b ovs-c; do ip netns del $ns; done
ovs-vsctl del-br ovsbr0
```

### 2d. Exercises

**Exercise 1 — OVS trace.** Use `ofproto/trace` to prove that a frame on VLAN
123 from the trunk port is dropped (it's not in the trunk list).

**Exercise 2 — Day-2 VLAN.** Add VLAN 300 to the trunk port with a single
`ovs-vsctl set port` command. Verify the config survives a service restart.

---

## Phase 3: Bridge vs OVS — Side-by-Side

This is the core comparison for KubeVirt VM consultation. Build both
approaches with the **same heterogeneous guest scenario** and compare.

### Test Scenario: Four Guests, Different VLAN Sets

| Guest | Role | Allowed VLANs | Type |
|---|---|---|---|
| `fw-dmz` | DMZ firewall | 100, 200 | Trunk |
| `fw-internal` | Internal firewall | 123, 150 | Trunk |
| `monitor` | IDS/tap | 100, 123, 150, 200 | Read-only mirror |
| `tenant-a` | Tenant workload | 100 | Access (untagged) |

### 3a. Helper: Create Namespaces

```bash
for ns in fw-dmz fw-internal monitor tenant-a; do
  ip netns add $ns
done
```

### 3b. VLAN-Aware Bridge Setup

```bash
ip link add br-trunk type bridge vlan_filtering 1
ip link set br-trunk up
ip link set dummy0 master br-trunk
for vid in 100 123 150 200; do
  bridge vlan add vid $vid dev dummy0
done

# fw-dmz: trunk, VLANs 100 + 200
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

# fw-internal: trunk, VLANs 123 + 150
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

# monitor: trunk, all VLANs
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

# tenant-a: access port, VLAN 100 (untagged)
ip link add veth-tena type veth peer name veth-tena-br
ip link set veth-tena netns tenant-a
ip link set veth-tena-br master br-trunk && ip link set veth-tena-br up
bridge vlan del vid 1 dev veth-tena-br
bridge vlan add vid 100 dev veth-tena-br pvid untagged

ip netns exec tenant-a ip addr add 10.0.100.10/24 dev veth-tena
ip netns exec tenant-a ip link set veth-tena up

bridge vlan show
ip netns exec tenant-a ping -c 2 10.0.100.1
```

Read-only monitor requires nftables (the bridge has no concept of port direction):

```bash
nft add table bridge filter
nft add chain bridge filter forward '{ type filter hook forward priority 0; }'
nft add rule bridge filter forward ibrname "veth-mon-br" drop
```

```bash
ip link del br-trunk 2>/dev/null
nft delete table bridge filter 2>/dev/null
```

### 3c. OVS Setup

```bash
ovs-vsctl add-br ovsbr0
ovs-vsctl add-port ovsbr0 dummy0

# fw-dmz: trunk VLANs 100, 200
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

# fw-internal: trunk VLANs 123, 150
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

# monitor: trunk all VLANs
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

# tenant-a: access port, VLAN 100
ip link add veth-tena type veth peer name veth-tena-br
ip link set veth-tena netns tenant-a
ip link set veth-tena-br up
ovs-vsctl add-port ovsbr0 veth-tena-br -- set port veth-tena-br tag=100

ip netns exec tenant-a ip addr add 10.0.100.10/24 dev veth-tena
ip netns exec tenant-a ip link set veth-tena up

ovs-vsctl show
ip netns exec tenant-a ping -c 2 10.0.100.1
```

Read-only monitor via OVS flow:

```bash
ovs-ofctl add-flow ovsbr0 "priority=100,in_port=veth-mon-br,actions=drop"
```

```bash
for ns in fw-dmz fw-internal monitor tenant-a; do ip netns del $ns; done
ovs-vsctl del-br ovsbr0
```

### 3d. Full Comparison Matrix (Host-Level)

| Dimension | Bridge (per-VLAN) | Bridge (VLAN-aware) | OVS |
|---|---|---|---|
| Guest NICs for 4-VLAN trunk | 4 | 1 | 1 |
| Firewall appliance compat | Poor (discrete NICs) | Good (802.1Q trunk) | Good (802.1Q trunk) |
| Add VLAN to one guest | New bridge + NIC (disruptive) | `bridge vlan add` (live, not persisted) | `ovs-vsctl set port` (live, persisted) |
| Prove isolation w/o traffic | Not possible | Not possible | `ofproto/trace` |
| SPAN/Mirror | Not possible | tc mirred (fragile) | Native mirror |
| Central management | None | None | OVN northbound DB |
| Scale (100s of VMs) | Bridge sprawl | Reasonable | Best — flow caching |

### 3e. Performance Summary

| Metric | VLAN-aware bridge | OVS (cached) | OVS (miss) |
|---|---|---|---|
| Median RTT | ~15–25 µs | ~18–30 µs | ~60–150 µs |
| P99 RTT | ~30–50 µs | ~40–80 µs | ~200–500 µs |
| P99.9 RTT | ~50–80 µs | ~80–200 µs | ~500+ µs |

At typical VM scale (< 50 VMs, < 100 VLANs), throughput and latency
differences are negligible. Choose based on operability, not performance.

### 3f. Lab Exercises

**Exercise 1 — Baseline connectivity.** Verify all four guests have the
correct connectivity.

**Exercise 2 — Day-2 VLAN change.** Add VLAN 300 to `fw-dmz` on both
datapaths. Compare the steps and persistence.

**Exercise 3 — Prove VLAN isolation.** Use `ofproto/trace` on OVS vs
`tcpdump` on bridge. Which gives deterministic proof?

**Exercise 4 — Performance.** Run `iperf3` between `tenant-a` and `fw-dmz` on
both datapaths. Measure throughput and latency side-by-side.

---

## Phase 4: OVN — The Control Plane

OVN adds a logical networking layer on top of OVS. Still on the Fedora lab VM.

### 4a. Install Standalone OVN

```bash
dnf install -y ovn ovn-central ovn-host
systemctl enable --now ovn-northd ovsdb-server-nb ovsdb-server-sb ovn-controller
```

### 4b. Create Logical Topology

```bash
ovn-nbctl ls-add tenant1

ovn-nbctl lsp-add tenant1 port1
ovn-nbctl lsp-set-addresses port1 "aa:bb:cc:dd:ee:01 10.0.0.1"
ovn-nbctl lsp-add tenant1 port2
ovn-nbctl lsp-set-addresses port2 "aa:bb:cc:dd:ee:02 10.0.0.2"

ovn-nbctl lr-add router1
ovn-nbctl lrp-add router1 rtr-tenant1 aa:bb:cc:dd:ee:ff 10.0.0.254/24

ovn-nbctl lsp-add tenant1 tenant1-rtr
ovn-nbctl lsp-set-type tenant1-rtr router
ovn-nbctl lsp-set-addresses tenant1-rtr router
ovn-nbctl lsp-set-options tenant1-rtr router-port=rtr-tenant1

ovn-nbctl acl-add tenant1 to-lport 1000 'outport == "port1" && ip4.src == 10.0.0.2' allow
ovn-nbctl acl-add tenant1 to-lport 900 'outport == "port1"' drop

ovn-nbctl show
ovn-sbctl show
```

### 4c. OVN → Kubernetes Concept Mapping

| OVN Concept | Kubernetes Equivalent |
|---|---|
| Logical Switch | Namespace network / UDN L2 segment |
| Logical Router | UDN L3 topology / cluster default gateway |
| Logical Switch Port | Pod network interface |
| ACLs | NetworkPolicy / AdminNetworkPolicy |
| Localnet port | Physical network attachment (CUDN Localnet → VLAN trunk to node NIC) |

---

## Phase 5: OpenShift 4.21 — The Decision in Practice

Switch to the OCP 4.21 cluster. This phase is the core of the workshop —
every attachment mechanism is evaluated through the three personas.

**Reference documentation:**

- [Virtualization Networking](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking) (Table 10.1, VM attachment guides)
- [Multiple Networks](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/multiple_networks/index) (UDN/CUDN/NAD support matrices)
- [Kubernetes NMState](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/kubernetes_nmstate/index) (NNCPs)
- [OVN-Kubernetes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/ovn-kubernetes_network_plugin/index) (OVN architecture, localnet)

### 5a. Prerequisites (NMState, OpenShift Virtualization, KubeletConfig)

```bash
oc get pods -n openshift-multus  # Multus ships by default
```

Install OpenShift Virtualization operator and create the HyperConverged CR.
Ensure NMState is available for node network configuration.

### 5b. Node Networking (NNCPs: br-secondary, ovs-br1, bridge-mapping)

Two bridges on two NICs — one for each networking paradigm:

**Linux-bridge on NIC 2 (for bridge CNI NADs):**

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
            - name: enp7s0
```

**OVS bridge on NIC 3 (for CUDN Localnet):**

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ovs-br1
spec:
  desiredState:
    interfaces:
      - name: ovs-br1
        type: ovs-bridge
        state: up
        bridge:
          port:
            - name: enp8s0
    ovn:
      bridge-mappings:
        - localnet: physnet1
          bridge: ovs-br1
          state: present
```

Verify:

```bash
oc debug node/<node> -- chroot /host ovs-vsctl show
oc debug node/<node> -- chroot /host ovs-vsctl get Open_vSwitch . external_ids
```

### 5c. Attachment Mechanism Deep-Dive

#### Linux-bridge NAD (bridge CNI)

> **Docs:** [§10.7 Connecting a VM to a Linux bridge network](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-connecting-vm-to-linux-bridge)
> | [Table 10.1 Linux bridge vs OVN-K localnet](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-networking-overview)

Access-mode NAD (VLAN 100, untagged to guest):

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

Access-mode NAD (VLAN 200, untagged to guest):

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vlan200-bridge
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "vlan200-bridge",
      "type": "bridge",
      "bridge": "br-secondary",
      "vlan": 200,
      "ipam": {}
    }
```

Trunk NAD (all VLANs, 802.1Q tagged to guest):

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

Filtered Trunk NAD (802.1Q tagged, restricted VLAN allow-list):

The `vlanTrunk` field provides the **middle ground** between access and full
trunk. The guest receives 802.1Q-tagged frames but **only** for VLANs in the
allow-list — the bridge drops traffic for any VLAN not listed. This is the
linux-bridge equivalent of the removed OVS CNI `"trunk": [{"id": N}]`
per-port filtering.

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: trunk-100-200-bridge
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "filtered-trunk",
      "type": "bridge",
      "bridge": "br-secondary",
      "vlanTrunk": [
        {"id": 100},
        {"id": 200},
        {"minID": 300, "maxID": 399}
      ],
      "ipam": {}
    }
```

Individual VLAN IDs are specified with `{"id": N}`. Ranges use
`{"minID": N, "maxID": M}`. Any VLAN not in the list is silently dropped.

**Constraints:** No IPAM for VMs (use cloud-init). No NetworkPolicy. Cannot
attach to default machine network directly. Bonding modes 0, 5, 6 not
supported.

#### CUDN Localnet (OVN-Kubernetes)

> **Docs:** [§10.4 Connecting a VM to a secondary localnet UDN](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-connecting-vm-to-secondary-localnet-udn)
> | [§3.1.5.3 Creating a CUDN CR for Localnet](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/multiple_networks/index#creating-cluster-udn-localnet-cr-cli)

```yaml
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: phys-vlan100
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
      subnets:
        - "10.0.100.0/24"
      physicalNetworkName: physnet1
      vlan:
        mode: Access
        access:
          id: 100
```

**Constraints:** Localnet requires `ClusterUserDefinedNetwork` (not
`UserDefinedNetwork`). VLAN is access-mode only — no 802.1Q trunk passthrough.
IPAM for VMs must be `Disabled`. MultiNetworkPolicy limited to `ipBlock`.

#### UDN Layer2/Layer3 (OVN overlay)

> **Docs:** [§10.3 Connecting a VM to a primary UDN](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-connecting-vm-to-primary-udn)
> | [§3.1 About user-defined networks](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/multiple_networks/index#about-user-defined-networks)

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
      - "10.100.0.0/16"
```

**Constraints:** Primary UDN requires
`k8s.ovn.org/primary-user-defined-network` namespace label at creation (cannot
be added later). Primary UDN VMs lose `virtctl ssh`, `oc port-forward`, and
headless services.

#### SR-IOV

> **Docs:** [§10.8 Connecting a VM to an SR-IOV network](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-connecting-vm-to-sriov)

Hardware passthrough — maximum performance. Per-VF VLAN filtering replaces
the removed OVS CNI trunk capability at the hardware level.

**Constraints:** No live migration. No hot-unplug.

#### macvlan / ipvlan

> **Docs:** [§2.1 Secondary networks in OCP](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/multiple_networks/index#secondary-networks-ocp)

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
      "master": "br-secondary",
      "mode": "bridge",
      "ipam": { "type": "whereabouts", "range": "10.0.100.0/24" }
    }
```

**Constraints:** Cannot communicate with host. Niche use cases.

### 5d. KubeVirt VM Examples by Persona

> **Docs:** [§10.2 Connecting a VM to default pod network](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-connecting-vm-to-default-pod-network)
> | [§10.11 Hot plugging secondary network interfaces](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking#virt-hot-plugging-network-interfaces)

#### Normal VM — Linux-bridge VLAN access

Simplest attachment. VM gets an untagged NIC on VLAN 100.

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: app-vm
  namespace: tenant-a
spec:
  runStrategy: Always
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
            networkName: vlan100-bridge
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
```

#### Normal VM — CUDN Localnet

Same result as above, but with OVN-managed NetworkPolicy:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: app-vm-localnet
  namespace: tenant-a
spec:
  runStrategy: Always
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
            networkName: phys-vlan100
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
```

#### VPC Tenant VM — Primary UDN Layer2

Replaces the default pod network with a tenant-specific overlay. Persistent
IPs survive live migration.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-blue
  labels:
    k8s.ovn.org/primary-user-defined-network: ""
---
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
      - "10.100.0.0/16"
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vpc-vm
  namespace: tenant-blue
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              bridge: {}
        resources:
          requests:
            memory: 1Gi
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
```

> **Warning:** Primary UDN VMs lose `virtctl ssh`, `oc port-forward`, and
> headless services.

#### Network Appliance — Linux-bridge trunk

Firewall VM gets a single 802.1Q trunk NIC. All VLANs are visible.

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fw-dmz
  namespace: firewall-vms
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: trunk
              bridge: {}
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
        resources:
          requests:
            memory: 2Gi
      networks:
        - name: default
          pod: {}
        - name: trunk
          multus:
            networkName: trunk-bridge
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              user: fedora
              password: fedora
              ssh_pwauth: true
              chpasswd:
                expire: false
```

Inside the VM:

```bash
virtctl console fw-dmz
ip link add link enp2s0 name enp2s0.100 type vlan id 100
ip addr add 10.0.100.1/24 dev enp2s0.100
ip link set enp2s0.100 up
ip link add link enp2s0 name enp2s0.200 type vlan id 200
ip addr add 10.0.200.1/24 dev enp2s0.200
ip link set enp2s0.200 up
```

#### Network Appliance — CUDN Localnet multi-NIC

Alternative: one untagged NIC per VLAN via CUDN Localnet. Requires the
appliance to support multi-NIC configuration.

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fw-dmz-localnet
  namespace: firewall-vms
spec:
  runStrategy: Always
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
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
        resources:
          requests:
            memory: 2Gi
      networks:
        - name: default
          pod: {}
        - name: vlan100
          multus:
            networkName: phys-vlan100
        - name: vlan200
          multus:
            networkName: phys-vlan200
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              user: fedora
              password: fedora
              ssh_pwauth: true
              chpasswd:
                expire: false
```

#### Network Appliance — Filtered trunk with inter-VLAN routing

Firewall VM on a filtered trunk (`vlanTrunk`). Only VLANs 100, 200, and
300-399 are delivered. Cloud-init enables IP forwarding and creates VLAN
sub-interfaces so the VM acts as a router between VLANs 100 and 200.

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fw-filtered
  namespace: default
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: trunk
              bridge: {}
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
        resources:
          requests:
            memory: 2Gi
      networks:
        - name: default
          pod: {}
        - name: trunk
          multus:
            networkName: trunk-100-200-bridge
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              user: fedora
              password: fedora
              ssh_pwauth: true
              chpasswd:
                expire: false
              runcmd:
                - sysctl -w net.ipv4.ip_forward=1
                - ip link add link enp2s0 name enp2s0.100 type vlan id 100
                - ip addr add 10.0.100.1/24 dev enp2s0.100
                - ip link set enp2s0.100 up
                - ip link add link enp2s0 name enp2s0.200 type vlan id 200
                - ip addr add 10.0.200.1/24 dev enp2s0.200
                - ip link set enp2s0.200 up
```

Normal VM on VLAN 100 (access, untagged):

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-vlan100
  namespace: default
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: vlan100
              bridge: {}
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
        resources:
          requests:
            memory: 1Gi
      networks:
        - name: default
          pod: {}
        - name: vlan100
          multus:
            networkName: vlan100-bridge
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              user: fedora
              password: fedora
              ssh_pwauth: true
              chpasswd:
                expire: false
              runcmd:
                - ip addr add 10.0.100.10/24 dev enp2s0
                - ip link set enp2s0 up
                - ip route add 10.0.200.0/24 via 10.0.100.1
```

Normal VM on VLAN 200 (access, untagged):

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-vlan200
  namespace: default
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: vlan200
              bridge: {}
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
        resources:
          requests:
            memory: 1Gi
      networks:
        - name: default
          pod: {}
        - name: vlan200
          multus:
            networkName: vlan200-bridge
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              user: fedora
              password: fedora
              ssh_pwauth: true
              chpasswd:
                expire: false
              runcmd:
                - ip addr add 10.0.200.10/24 dev enp2s0
                - ip link set enp2s0 up
                - ip route add 10.0.100.0/24 via 10.0.200.1
```

### 5e. The Hybrid Architecture (Two-Bridge Model)

When all three personas coexist:

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │                         OCP Node                                    │
  │                                                                     │
  │  ┌───────────────┐       ┌─────────────┐       ┌──────────────┐    │
  │  │  fw-dmz VM    │       │ tenant-a VM │       │ tenant-b VM  │    │
  │  │  (appliance)  │       │ (normal)    │       │ (normal)     │    │
  │  │               │       │             │       │              │    │
  │  │ enp2s0: trunk │       │ enp2s0:VLAN │       │ enp2s0:VLAN  │    │
  │  │  all VLANs    │       │  100 untag  │       │  200 untag   │    │
  │  │  tagged 802.1Q│       │             │       │              │    │
  │  └──────┬────────┘       └──────┬──────┘       └──────┬───────┘    │
  │         │                       │                     │            │
  │    Bridge CNI              CUDN Localnet         CUDN Localnet    │
  │    trunk NAD               phys-vlan100          phys-vlan200     │
  │         │                       │                     │            │
  │  ┌──────┴──────┐  ┌────────────┴─────────────────────┴──────────┐  │
  │  │ br-secondary│  │               ovs-br1                      │  │
  │  │ (linux-     │  │          (OVS bridge, OVN-managed)         │  │
  │  │  bridge)    │  │                                            │  │
  │  └──────┬──────┘  └──────────────────┬─────────────────────────┘  │
  │         │                            │                            │
  │     enp7s0 (NIC 2)              enp8s0 (NIC 3)                   │
  └─────────┴────────────────────────────┴────────────────────────────┘
            │                            │
            └─────── br-lab (host) ──────┘
```

Both NICs connect to the same `br-lab` host bridge, so VLAN 100 traffic from
a VM on `br-secondary` (via bridge CNI trunk) can reach a VM on `ovs-br1`
(via CUDN localnet) — the physical underlay carries tagged frames between
both bridges.

> **Prerequisite:** The host `br-lab` bridge has `vlan_filtering 1` enabled.
> By default the vnet ports only carry VLAN 1. You must add the lab VLANs to
> all `br-lab` member ports for cross-node VLAN traffic to work:
>
> ```bash
> for dev in $(bridge link show master br-lab | awk '{print $2}' | cut -d@ -f1); do
>   sudo bridge vlan add vid 100 dev $dev
>   sudo bridge vlan add vid 200 dev $dev
>   sudo bridge vlan add vid 300-399 dev $dev
> done
> sudo bridge vlan add vid 100 dev br-lab self
> sudo bridge vlan add vid 200 dev br-lab self
> sudo bridge vlan add vid 300-399 dev br-lab self
> ```

> **NIC naming:** Fedora containerdisk images use predictable interface names.
> The masquerade (pod network) NIC appears as `enp1s0`; the first secondary
> NIC (bridge/multus) appears as `enp2s0`. Cloud-init `runcmd` commands must
> use these names, not `eth1`.

### 5f. Exercises (by Persona)

**Exercise 1 — Normal VM: bridge vs localnet.** Deploy two VMs on VLAN 100 —
one via `vlan100-bridge` (bridge CNI), one via `phys-vlan100` (CUDN localnet).
Compare: which supports NetworkPolicy? Which can talk to the host?

**Exercise 2 — Network Appliance: full trunk.** Deploy `fw-dmz` with the
`trunk-bridge` NAD. Create VLAN sub-interfaces inside the VM. Verify that the
VM can see *any* VLAN (there is no per-port filtering).

**Exercise 2b — Filtered trunk: inter-VLAN routing through a firewall.**

Deploy three VMs to demonstrate `vlanTrunk` filtering and inter-VLAN routing:

```
  vm-vlan100              fw-filtered                vm-vlan200
  10.0.100.10/24          enp2s0.100: 10.0.100.1/24  10.0.200.10/24
  gw: 10.0.100.1          enp2s0.200: 10.0.200.1/24  gw: 10.0.200.1
       │                  ip_forward=1                     │
       │   VLAN 100       ┌────────────┐    VLAN 200       │
       └──────────────────┤ br-secondary├──────────────────┘
         vlan100-bridge   │ vlanTrunk: │    vlan200-bridge
         (access NAD)     │ 100, 200   │    (access NAD)
                          └────────────┘
                       trunk-100-200-bridge
                        (filtered trunk NAD)
```

1. Apply the NADs (`vlan100-bridge`, `vlan200-bridge`, `trunk-100-200-bridge`)
2. Create `fw-filtered` (uses `trunk-100-200-bridge`), `vm-vlan100` (uses
   `vlan100-bridge`), and `vm-vlan200` (uses `vlan200-bridge`)
3. Wait for VMs to boot. The firewall cloud-init enables IP forwarding and
   creates VLAN sub-interfaces automatically.
4. From `vm-vlan100`, ping through the firewall:

```bash
virtctl console vm-vlan100
# ping the firewall gateway
ping -c 3 10.0.100.1
# ping vm-vlan200 (routed through fw-filtered)
ping -c 3 10.0.200.10
```

5. On `fw-filtered`, observe the 802.1Q-tagged traffic:

```bash
virtctl console fw-filtered
tcpdump -i enp2s0 -e -n icmp
```

6. Verify VLAN filtering — create a sub-interface for VLAN 500 (not in the
   allow-list) and confirm that traffic is dropped:

```bash
# Still on fw-filtered
ip link add link enp2s0 name enp2s0.500 type vlan id 500
ip addr add 10.5.0.1/24 dev enp2s0.500
ip link set enp2s0.500 up
# No peer exists, but the bridge will also drop the frames
ping -c 2 10.5.0.99   # no response — VLAN 500 is filtered
```

**Exercise 3 — Network Appliance: localnet multi-NIC.** Deploy
`fw-dmz-localnet` with `phys-vlan100` and `phys-vlan200`. Verify the VM gets
two separate untagged NICs. Compare operational model with Exercise 2.

**Exercise 4 — VPC Tenant: primary UDN.** Create a namespace with the
`k8s.ovn.org/primary-user-defined-network` label. Deploy a VM. Confirm
`virtctl ssh` does not work. Verify persistent IPs across live migration.

**Exercise 5 — Cross-bridge connectivity.** Verify that `fw-dmz` on
`br-secondary` (VLAN 100 trunk) can reach `app-vm` on `ovs-br1` (VLAN 100
CUDN localnet) through the shared `br-lab` underlay.

**Exercise 6 — Day-2 VLAN.** Add VLAN 300. Compare the steps for each
approach:

| Approach | Steps | VM restart? |
|---|---|---|
| Linux-bridge trunk | No change needed — all VLANs pass. Inside VM: `ip link add ... type vlan id 300` | No |
| CUDN Localnet | Create new CUDN. Update VM spec to attach it. | Yes |

---

## Decision Framework

### Scenario Decision Matrix

#### Normal VM

| Requirement | Best choice | Why |
|---|---|---|
| Simple L2 on a VLAN, no policy | **Linux-bridge NAD** (`"vlan": N`) | Simplest: NNCP + NAD + VM |
| L2 on a VLAN + NetworkPolicy | **CUDN Localnet** (access mode) | OVN enforces policy |
| No physical underlay | **UDN Layer2** (secondary) | No NIC config needed |
| Live migration with persistent IP | **UDN Layer2** (primary, `Persistent`) | IPs preserved |
| Maximum performance | **SR-IOV** | Hardware passthrough (no live migration) |

#### VPC-like Tenant Isolation

| Requirement | Best choice | Why |
|---|---|---|
| Tenant-per-namespace isolation | **CUDN Layer2** (primary, `Persistent`) | Replaces default pod network |
| Multi-namespace shared network | **CUDN Layer2** (primary) + `namespaceSelector` | Single network spans tenant namespaces |
| Per-VLAN physical access + policy | **CUDN Localnet** (secondary) per VLAN | `namespaceSelector` controls access |

#### Network Appliance with Trunk

| Requirement | Best choice | Why |
|---|---|---|
| 802.1Q trunk (all VLANs) | **Linux-bridge trunk NAD** (`"vlan": 0`) | Only remaining trunk on OCP 4.17+ |
| Trunk + per-VM VLAN filtering | **SR-IOV** with VF trunk config | Hardware VLAN filtering |
| Multi-NIC, per-VLAN isolation | **CUDN Localnet** (one per VLAN) | OVN-managed, true isolation |

### The Punchline (OCP 4.17+)

> **What kind of VM is this?**
>
> - **Normal VM** → Start with **CUDN Localnet** (OVN-managed, NetworkPolicy).
>   Fall back to **linux-bridge NAD** if you don't need policy.
> - **VPC Tenant VM** → **Primary UDN Layer2** for overlay isolation. Add
>   **CUDN Localnet** for physical network access per VLAN.
> - **Network Appliance** → **Linux-bridge trunk NAD** (`"vlan": 0`). The
>   appliance is the firewall — it doesn't need OVN policy.
> - **All three at scale** → **Two-bridge hybrid model.** Appliances on
>   `br-secondary` (NIC 2), tenants on `ovs-br1` (NIC 3). Both bridges
>   connect to the same upstream, so cross-VLAN traffic flows through the
>   firewall.

### What Was Removed and Why

The `ovs-cni` plugin binary was removed in OCP 4.17. OVN-Kubernetes now manages
all OVS bridges exclusively — a standalone CNI plugin that directly manipulates
OVS ports conflicts with OVN's control plane. The two replacements are:

| Old (OVS CNI) | Replacement |
|---|---|
| `"type": "ovs"` with `"trunk": [...]` | **Linux-bridge trunk** (`"vlan": 0`) — no per-VM filtering |
| `"type": "ovs"` with `"trunk": [{"id": N}]` (filtered) | **Linux-bridge filtered trunk** (`"vlanTrunk": [{"id": N}]`) — software VLAN allow-list |
| `"type": "ovs"` with `"vlan": N` | **CUDN Localnet** with `vlan.mode: Access` |
| Per-port VLAN allow-lists (hardware) | **SR-IOV** with VF VLAN filtering |

---

## Learnings / Lab Errata

### OVS CNI (`"type": "ovs"`) Is Not Available in OCP 4.17+

The `ovs-cni` plugin binary is **no longer shipped** in OpenShift 4.17+. Any
`NetworkAttachmentDefinition` with `"type": "ovs"` will fail:

```
failed to find plugin "ovs" in path [/var/lib/cni/bin]
```

OVN-Kubernetes manages all OVS bridges via the OVN southbound database. A
standalone OVS CNI plugin that directly manipulates OVS ports conflicts with
OVN's control plane — OVN may remove or reconfigure ports it doesn't recognise.

### Localnet Topology Requires ClusterUserDefinedNetwork (CUDN), Not UDN

The namespace-scoped `UserDefinedNetwork` resource only supports `Layer2` and
`Layer3`. **Localnet is only available on `ClusterUserDefinedNetwork`:**

```bash
$ oc explain userdefinednetwork.spec.topology
ENUM: Layer2, Layer3

$ oc explain clusteruserdefinednetwork.spec.network.topology
ENUM: Layer2, Layer3, Localnet
```

Localnet connects OVN logical switches to physical OVS bridges via
`bridge-mappings`. These mappings are configured per node and must be
consistent cluster-wide — a namespace-scoped resource cannot guarantee this.

### CUDN Localnet VLAN is Access-Mode Only

`vlan: {mode: Access, access: {id: N}}` — no 802.1Q trunk passthrough. For
trunk delivery, use a linux-bridge NAD.

### OVS Bridge Is Still Required for Localnet

Even though the `ovs-cni` plugin is gone, OVS bridges are still needed. The
localnet topology requires an OVS bridge with an OVN bridge-mapping. The
difference is that **OVN manages all ports on this bridge** — you do not
create ports manually with `ovs-vsctl add-port`.

### Two-NIC Topology: Linux-Bridge on NIC 2, OVS/Localnet on NIC 3

```
  Host                                    OCP Node
  ┌──────────────┐                        ┌────────────────────────────────────┐
  │  br-lab      │◄── NIC2 (enp7s0) ────►│  br-secondary (linux-bridge)      │
  │  (VLAN-aware │                        │  └─ bridge CNI NADs               │
  │   host       │                        │     (trunk, vlan100, macvlan...)   │
  │   bridge)    │                        │                                    │
  │              │◄── NIC3 (enp8s0) ────►│  ovs-br1 (OVS bridge)             │
  │              │                        │  └─ CUDN Localnet                  │
  │              │                        │     (phys-vlan100, phys-vlan200)   │
  └──────────────┘                        └────────────────────────────────────┘
```

---

## Appendix: YAML Reference

All resource definitions collected for copy-paste.

### NNCPs

```yaml
# br-secondary (linux-bridge on NIC 2)
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
            - name: enp7s0
---
# ovs-br1 (OVS bridge on NIC 3 with OVN bridge-mapping)
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ovs-br1
spec:
  desiredState:
    interfaces:
      - name: ovs-br1
        type: ovs-bridge
        state: up
        bridge:
          port:
            - name: enp8s0
    ovn:
      bridge-mappings:
        - localnet: physnet1
          bridge: ovs-br1
          state: present
```

### NADs

```yaml
# Access-mode VLAN 100 on linux-bridge
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
---
# Access-mode VLAN 200 on linux-bridge
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vlan200-bridge
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "vlan200-bridge",
      "type": "bridge",
      "bridge": "br-secondary",
      "vlan": 200,
      "ipam": {}
    }
---
# Full trunk on linux-bridge (all VLANs, 802.1Q tagged)
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
---
# Filtered trunk on linux-bridge (VLANs 100, 200, 300-399 only)
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: trunk-100-200-bridge
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "filtered-trunk",
      "type": "bridge",
      "bridge": "br-secondary",
      "vlanTrunk": [
        {"id": 100},
        {"id": 200},
        {"minID": 300, "maxID": 399}
      ],
      "ipam": {}
    }
---
# macvlan
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
      "master": "br-secondary",
      "mode": "bridge",
      "ipam": { "type": "whereabouts", "range": "10.0.100.0/24" }
    }
---
# ipvlan
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
      "master": "br-secondary",
      "mode": "l2",
      "ipam": { "type": "whereabouts", "range": "10.0.100.0/24" }
    }
```

### CUDNs (Localnet)

```yaml
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: phys-vlan100
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
      subnets:
        - "10.0.100.0/24"
      physicalNetworkName: physnet1
      vlan:
        mode: Access
        access:
          id: 100
---
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: phys-vlan200
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
      subnets:
        - "10.0.200.0/24"
      physicalNetworkName: physnet1
      vlan:
        mode: Access
        access:
          id: 200
```

### UDNs

```yaml
# Layer2 primary (VPC tenant)
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-blue
  labels:
    k8s.ovn.org/primary-user-defined-network: ""
---
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
      - "10.100.0.0/16"
---
# Layer3 primary (routed VPC tenant)
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

### KubeVirt VMs

```yaml
# Normal VM — linux-bridge VLAN access
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: app-vm
  namespace: tenant-a
spec:
  runStrategy: Always
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
            networkName: vlan100-bridge
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
---
# Network Appliance — linux-bridge trunk
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fw-dmz
  namespace: firewall-vms
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: trunk
              bridge: {}
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
        resources:
          requests:
            memory: 2Gi
      networks:
        - name: default
          pod: {}
        - name: trunk
          multus:
            networkName: trunk-bridge
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              user: fedora
              password: fedora
              ssh_pwauth: true
              chpasswd:
                expire: false
---
# Network Appliance — CUDN Localnet multi-NIC
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fw-dmz-localnet
  namespace: firewall-vms
spec:
  runStrategy: Always
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
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
        resources:
          requests:
            memory: 2Gi
      networks:
        - name: default
          pod: {}
        - name: vlan100
          multus:
            networkName: phys-vlan100
        - name: vlan200
          multus:
            networkName: phys-vlan200
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              user: fedora
              password: fedora
              ssh_pwauth: true
              chpasswd:
                expire: false
---
# Filtered trunk firewall — inter-VLAN routing (Exercise 2b)
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fw-filtered
  namespace: default
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: trunk
              bridge: {}
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
        resources:
          requests:
            memory: 2Gi
      networks:
        - name: default
          pod: {}
        - name: trunk
          multus:
            networkName: trunk-100-200-bridge
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              user: fedora
              password: fedora
              ssh_pwauth: true
              chpasswd:
                expire: false
              runcmd:
                - sysctl -w net.ipv4.ip_forward=1
                - ip link add link enp2s0 name enp2s0.100 type vlan id 100
                - ip addr add 10.0.100.1/24 dev enp2s0.100
                - ip link set enp2s0.100 up
                - ip link add link enp2s0 name enp2s0.200 type vlan id 200
                - ip addr add 10.0.200.1/24 dev enp2s0.200
                - ip link set enp2s0.200 up
---
# Normal VM on VLAN 100 (Exercise 2b)
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-vlan100
  namespace: default
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: vlan100
              bridge: {}
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
        resources:
          requests:
            memory: 1Gi
      networks:
        - name: default
          pod: {}
        - name: vlan100
          multus:
            networkName: vlan100-bridge
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              user: fedora
              password: fedora
              ssh_pwauth: true
              chpasswd:
                expire: false
              runcmd:
                - ip addr add 10.0.100.10/24 dev enp2s0
                - ip link set enp2s0 up
                - ip route add 10.0.200.0/24 via 10.0.100.1
---
# Normal VM on VLAN 200 (Exercise 2b)
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-vlan200
  namespace: default
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: vlan200
              bridge: {}
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
        resources:
          requests:
            memory: 1Gi
      networks:
        - name: default
          pod: {}
        - name: vlan200
          multus:
            networkName: vlan200-bridge
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              user: fedora
              password: fedora
              ssh_pwauth: true
              chpasswd:
                expire: false
              runcmd:
                - ip addr add 10.0.200.10/24 dev enp2s0
                - ip link set enp2s0 up
                - ip route add 10.0.100.0/24 via 10.0.200.1
---
# VPC Tenant VM — primary UDN
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vpc-vm
  namespace: tenant-blue
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              bridge: {}
        resources:
          requests:
            memory: 1Gi
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
                - name: cloudinit
        - cloudInitNoCloud:
            userData: |
              #cloud-config
              user: fedora
              password: fedora
              ssh_pwauth: true
              chpasswd:
                expire: false
```
