# Filtered Trunk: Inter-VLAN Routing Through a Firewall

## Topology

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

Three VMs share the same `br-secondary` linux-bridge but with different VLAN
policies. The firewall gets a **filtered trunk** (only VLANs 100 and 200),
creates sub-interfaces, and routes between the two client VMs which each sit
on a single access VLAN.

---

## Prerequisites

### Node network: linux-bridge on a bond (NNCP)

The bridge CNI NADs reference `br-secondary`, a VLAN-filtering linux-bridge
on each node. In a production environment with two physical NICs
available for secondary traffic, create it on top of a bond for redundancy.

This NNCP bonds `enp7s0` and `enp8s0` in active-backup mode, then creates
`br-secondary` with VLAN filtering on top:

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: br-secondary
spec:
  desiredState:
    interfaces:
      - name: bond-secondary
        type: bond
        state: up
        link-aggregation:
          mode: active-backup
          port:
            - enp7s0
            - enp8s0
      - name: br-secondary
        type: linux-bridge
        state: up
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: bond-secondary
              vlan:
                mode: trunk
                trunk-tags:
                  - id-range:
                      min: 1
                      max: 4094
```


### Fedora NIC naming

Fedora containerdisk images use predictable names: the masquerade (pod
network) NIC is `enp1s0`, the first secondary (multus) NIC is `enp2s0`.

---

## 1. Create NADs

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
---
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
        {"id": 200}
      ],
      "ipam": {}
    }
```

```bash
oc apply -f - <<'EOF'
# paste the three NADs above
EOF
```

`vlanTrunk` is the key field — the guest receives 802.1Q-tagged frames but
**only** for the listed VLANs. Any other VLAN is silently dropped by the
bridge. Ranges are also supported: `{"minID": 300, "maxID": 399}`.

---

## 2. Create VMs

### fw-filtered (firewall / router)

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

### vm-vlan100 (client on VLAN 100)

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

### vm-vlan200 (client on VLAN 200)

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

```bash
oc apply -f - <<'EOF'
# paste all three VM definitions above
EOF
```

Wait ~90 seconds for the VMs to boot and cloud-init to complete:

```bash
oc get vmi -n default -w
```

---

## 3. Verify firewall configuration

```bash
sshpass -p fedora virtctl ssh --username=fedora \
  -t "-o StrictHostKeyChecking=no" \
  -t "-o UserKnownHostsFile=/dev/null" \
  -t "-o PreferredAuthentications=password" \
  vmi/fw-filtered -n default \
  -c "cat /proc/sys/net/ipv4/ip_forward; ip addr show enp2s0.100; ip addr show enp2s0.200"
```

Expected: `ip_forward = 1`, `enp2s0.100` has `10.0.100.1/24`, `enp2s0.200`
has `10.0.200.1/24`.

---

## 4. Test inter-VLAN routing

From `vm-vlan100`, ping through the firewall to `vm-vlan200`:

```bash
sshpass -p fedora virtctl ssh --username=fedora \
  -t "-o StrictHostKeyChecking=no" \
  -t "-o UserKnownHostsFile=/dev/null" \
  -t "-o PreferredAuthentications=password" \
  vmi/vm-vlan100 -n default \
  -c "ping -c 3 10.0.100.1; ping -c 3 10.0.200.10"
```

Expected: both pings succeed. The second ping has **TTL=63** (decremented by
the firewall), confirming the packet was routed, not switched.

Reverse direction from `vm-vlan200`:

```bash
sshpass -p fedora virtctl ssh --username=fedora \
  -t "-o StrictHostKeyChecking=no" \
  -t "-o UserKnownHostsFile=/dev/null" \
  -t "-o PreferredAuthentications=password" \
  vmi/vm-vlan200 -n default \
  -c "ping -c 3 10.0.200.1; ping -c 3 10.0.100.10"
```

---

## 5. Observe tagged traffic on the firewall

```bash
sshpass -p fedora virtctl ssh --username=fedora \
  -t "-o StrictHostKeyChecking=no" \
  -t "-o UserKnownHostsFile=/dev/null" \
  -t "-o PreferredAuthentications=password" \
  vmi/fw-filtered -n default \
  -c "sudo tcpdump -i enp2s0 -e -n icmp -c 10"
```

You will see 802.1Q VLAN tags (100 and 200) on the ICMP packets.

---

## 6. Verify VLAN filtering

Create a VLAN 500 sub-interface on the firewall (500 is **not** in the
`vlanTrunk` allow-list) and confirm traffic is dropped:

```bash
sshpass -p fedora virtctl ssh --username=fedora \
  -t "-o StrictHostKeyChecking=no" \
  -t "-o UserKnownHostsFile=/dev/null" \
  -t "-o PreferredAuthentications=password" \
  vmi/fw-filtered -n default \
  -c "sudo ip link add link enp2s0 name enp2s0.500 type vlan id 500; \
      sudo ip addr add 10.5.0.1/24 dev enp2s0.500; \
      sudo ip link set enp2s0.500 up; \
      ping -c 2 -W 2 10.5.0.99; \
      ip neigh show dev enp2s0.500"
```

Expected: 100% packet loss, ARP stays `INCOMPLETE`. The bridge silently drops
VLAN 500 frames because the `vlanTrunk` allow-list only permits 100 and 200.

---

## 7. CUDN Localnet VMs — trombone routing

This extension adds two VMs using **CUDN Localnet** (OVN-Kubernetes) on the
same VLANs. Traffic between them routes through the **same firewall**, but
the path trombones through two different bridge stacks:

```
  vm-localnet-100 (tenant-a)         fw-filtered (default)         vm-localnet-200 (tenant-b)
  CUDN phys-vlan100                  bridge CNI trunk              CUDN phys-vlan200
  10.0.100.0/24 (DHCP)               enp2s0.100 / enp2s0.200      10.0.200.0/24 (DHCP)
       │                                    │                            │
  OVN localnet                         bridge CNI                   OVN localnet
       │                                    │                            │
  ovs-br1 ──► enp8s0 ──► br-lab ◄── enp7s0 ◄── br-secondary       ovs-br1 ──► enp8s0
       (NIC 3)               (host)        (NIC 2)                      (NIC 3)
```

The packet crosses **four** bridge boundaries: OVS → host bridge → linux
bridge → firewall → linux bridge → host bridge → OVS.

### Prerequisites

These CUDNs and namespaces should already exist from the consolidated plan:

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
        values: [firewall-vms, tenant-a]
  network:
    topology: Localnet
    localnet:
      physicalNetworkName: physnet1
      role: Secondary
      subnets: ["10.0.100.0/24"]
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
        values: [firewall-vms, tenant-b]
  network:
    topology: Localnet
    localnet:
      physicalNetworkName: physnet1
      role: Secondary
      subnets: ["10.0.200.0/24"]
      vlan:
        mode: Access
        access:
          id: 200
```

### Create the localnet VMs

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-localnet-100
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
            - name: localnet100
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
        - name: localnet100
          multus:
            networkName: phys-vlan100
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
                - |
                  DHCP_IP=$(ip -4 addr show enp2s0 | grep 'inet ' | awk '{print $2}' | head -1)
                  GW=10.0.100.1
                  ip route add 10.0.200.0/24 via $GW dev enp2s0
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-localnet-200
  namespace: tenant-b
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: localnet200
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
        - name: localnet200
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
              runcmd:
                - |
                  DHCP_IP=$(ip -4 addr show enp2s0 | grep 'inet ' | awk '{print $2}' | head -1)
                  GW=10.0.200.1
                  ip route add 10.0.100.0/24 via $GW dev enp2s0
```

```bash
oc apply -f - <<'EOF'
# paste both VM definitions above
EOF
```

### Discover DHCP addresses

OVN IPAM assigns addresses from the CUDN subnet. Cloud-init static IPs will
**not** work for cross-bridge traffic because OVN port security drops ARPs for
IPs it did not assign. Use the DHCP-assigned addresses:

```bash
# Get the DHCP address for each localnet VM
sshpass -p fedora virtctl ssh --username=fedora \
  -t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null" \
  -t "-o PreferredAuthentications=password" \
  vmi/vm-localnet-100 -n tenant-a \
  -c "ip -4 addr show enp2s0 | grep 'inet '"

sshpass -p fedora virtctl ssh --username=fedora \
  -t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null" \
  -t "-o PreferredAuthentications=password" \
  vmi/vm-localnet-200 -n tenant-b \
  -c "ip -4 addr show enp2s0 | grep 'inet '"
```

### Test trombone routing

From `vm-localnet-100`, ping through the firewall to `vm-localnet-200`:

```bash
sshpass -p fedora virtctl ssh --username=fedora \
  -t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null" \
  -t "-o PreferredAuthentications=password" \
  vmi/vm-localnet-100 -n tenant-a \
  -c "ping -c 3 10.0.100.1; ping -c 3 <vm-localnet-200-dhcp-ip>"
```

Expected: both succeed. The second ping has **TTL=63** — routed through the
firewall's `enp2s0.100` → IP forwarding → `enp2s0.200` path.

### Cross-mechanism test

The localnet VMs can also reach the bridge-CNI VMs on the same VLAN because
both share the `br-lab` physical underlay:

```bash
# From vm-localnet-100 (OVN localnet, tenant-a) → vm-vlan100 (bridge CNI, default)
# Same VLAN 100 — direct L2, TTL=64
ping -c 2 10.0.100.10

# From vm-localnet-100 → vm-vlan200 (bridge CNI, different VLAN)
# Routed through fw-filtered — TTL=63
ping -c 2 10.0.200.10
```

### Key observations

| Source | Destination | Path | TTL |
|--------|------------|------|-----|
| localnet-100 → fw gateway | Direct L2, same VLAN | OVS → br-lab → br-secondary | 64 |
| localnet-100 → bridge-CNI vlan100 | Direct L2, same VLAN | OVS → br-lab → br-secondary | 64 |
| localnet-100 → bridge-CNI vlan200 | Routed through fw | OVS → br-lab → br-secondary → fw → br-secondary → br-lab → br-secondary | 63 |
| localnet-100 → localnet-200 | Routed through fw (trombone) | OVS → br-lab → br-secondary → fw → br-secondary → br-lab → OVS | 63 |

> **OVN port security constraint:** CUDN localnet with `subnets` uses OVN
> IPAM which assigns addresses via DHCP. OVN port security then filters ARP
> responses for IPs not in its binding table. You **must** use the
> DHCP-assigned address — manually configured static IPs on the localnet
> interface will not be reachable from outside the VM.

---

## Cleanup

```bash
oc delete vm fw-filtered vm-vlan100 vm-vlan200 -n default
oc delete vm vm-localnet-100 -n tenant-a
oc delete vm vm-localnet-200 -n tenant-b
oc delete net-attach-def trunk-100-200-bridge vlan100-bridge vlan200-bridge -n default
```
