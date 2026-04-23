# VM Networking on OpenShift — A Consultant's Lab

Hands-on lab and decision guide for Red Hat / partner consultants advising
on OpenShift Virtualization networking. Covers Linux networking primitives
(bridge, macvlan, ipvlan, OVS, OVN), then maps them to OCP 4.17+ attachment
mechanisms (linux-bridge NAD, CUDN Localnet, UDN, SR-IOV) through a
**three-persona framework**: Normal VM, VPC-like Tenant, and Network Appliance.

## Lab curriculum

| Resource | Description |
|----------|-------------|
| **[cheatsheet.md](cheatsheet.md)** | Standalone 2-page printable constraint/decision reference. Pull out during customer engagements. Covers the master capability table, scenario decision matrix, 13 critical constraints with documentation links, and the hybrid two-bridge architecture. |
| **[slides.html](slides.html)** | Reveal.js visual explainer deck (open in any browser, navigate with arrow keys). 8 sections covering Linux primitives through the OCP decision framework. |
| **[consolidated-plan.md](consolidated-plan.md)** | Full lab manual with copy-paste commands for hands-on exercises. |

### Lab structure

| Phase | Topic | Environment |
|-------|-------|-------------|
| 1 | Linux networking primitives (veth, bridge, macvlan, ipvlan) | Fedora VM + namespaces |
| 2 | Open vSwitch (OVS) fundamentals and flow tables | Fedora VM + namespaces |
| 3 | OVS vs Bridge side-by-side comparison | Fedora VM + namespaces |
| 4 | OVN logical networking | Fedora VM |
| 5 | OpenShift 4.21 — attachments, constraints, personas | OCP cluster |
| — | Decision Framework + YAML Appendix | — |

All Phase 1–4 exercises use network namespaces on a single Fedora VM —
no nested VMs required. Phase 5 uses an OpenShift cluster with KubeVirt.

## Companion scripts

These scripts configure the host-level networking used by the lab and by
the companion [sushy-lab](https://github.com/ngner/sushy-lab) VM
infrastructure.

| File | Purpose |
|------|---------|
| `host-bridge-setup.sh` | Create a primary linux bridge (`br0`) from a physical NIC with MTU 9000 and STP disabled |
| `host-vlan-bridge-config.sh` | Create VLAN-specific bridges (`br-123`, `br-100`, `br-150`) and register them as libvirt networks |
| `host-network-config` | Combined nmcli recipe: bridge + VLAN bridges + virsh network registration |
| `routednet.xml` | Libvirt routed network definition with DHCP reservations for lab cluster nodes |
| `dnsmasq/00-use-dnsmasq.conf` | Enable the dnsmasq plugin in NetworkManager |
| `dnsmasq/01-DNS-dnsmasq-routednet.conf` | Dnsmasq local zone and upstream config for the lab domain |
| `dnsmasq/virsh-routednet-dnsmasq.hosts` | Static DNS host entries for lab cluster API/console endpoints |

## Quick start

```bash
# 1. Create the primary bridge
#    Edit NET_DEV in the script to match your physical NIC
./host-bridge-setup.sh

# 2. Add VLAN bridges (optional, for VLAN trunk exercises)
./host-vlan-bridge-config.sh

# 3. Define the routed libvirt network
#    Edit IPs and domain in routednet.xml to match your environment
sudo virsh net-define routednet.xml
sudo virsh net-start routednet
sudo virsh net-autostart routednet

# 4. Configure dnsmasq (optional, for lab DNS resolution)
sudo cp dnsmasq/00-use-dnsmasq.conf /etc/NetworkManager/conf.d/
sudo cp dnsmasq/01-DNS-dnsmasq-routednet.conf /etc/NetworkManager/dnsmasq.d/
sudo cp dnsmasq/virsh-routednet-dnsmasq.hosts /etc/virsh-routednet-dnsmasq.hosts
sudo systemctl reload NetworkManager
```

## Adapting to your environment

The default IP scheme uses `192.168.192.0/24` for the routed network. Edit
`routednet.xml` and `dnsmasq/virsh-routednet-dnsmasq.hosts` to match your
lab subnet. Replace `lab.example.com` with your own domain throughout.

## Related repositories

- [sushy-lab](https://github.com/ngner/sushy-lab) -- Sushy Redfish
  emulator and libvirt VM lifecycle scripts that run on top of this
  networking.
- [federated-fleet-forge](https://github.com/federated-fleet-forge) --
  ACM/ZTP GitOps reference that deploys OpenShift to those VMs.

## License

Apache-2.0. See [LICENSE](LICENSE).
