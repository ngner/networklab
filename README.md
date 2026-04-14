# Linux Networking & KubeVirt VLAN Trunk Lab

Hands-on lab for building knowledge of native Linux networking constructs
(linux bridge, macvlan, ipvlan, OVS, OVN) to consult on the best network
architecture for KubeVirt VMs -- specifically firewall VMs with VLAN trunks --
in OVN-Kubernetes environments.

## Lab curriculum

**[slides.html](slides.html)** -- visual explainer deck (open in any browser,
navigate with arrow keys). Covers concepts, topology diagrams, and the
consulting decision framework. Use for short talks or as the lecture
component before hands-on time.

**[consolidated-plan.md](consolidated-plan.md)** -- detailed lab manual with
copy-paste commands for hands-on exercises. Covers:

| Phase | Topic |
|-------|-------|
| 1 | Linux networking primitives (veth, bridge, macvlan, ipvlan) |
| 2 | Open vSwitch (OVS) fundamentals and flow tables |
| 3 | OVN logical networking |
| 4 | Kubernetes networking (Multus, bridge CNI, OVN-Kubernetes) |
| 5 | KubeVirt VM networking and VLAN trunk pass-through |

All Phase 1-3 exercises use network namespaces on a single Fedora VM --
no nested VMs required. Phase 4-5 use an OpenShift compact cluster.

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
