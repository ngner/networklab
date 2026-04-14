

## see sushy-hacks/host-bridge-setup.sh
# that sets up the bridge .

####  VLAN specific bridges 

for vlan in 123 100 150
do
  nmcli con add ifname br-${vlan} type bridge con-name br-${vlan}
  nmcli con modify br-${vlan} ipv4.method disabled ipv6.method ignore
  nmcli con up br-${vlan}
  nmcli con add type vlan con-name br0.${vlan} ifname br0.${vlan} dev br0 id ${vlan}
  nmcli con modify br0.${vlan} master br-${vlan} slave-type bridge
  nmcli con up br0.${vlan}
done



for BRIDGE in br0 br-123 br-100 br-150
do
  echo working on adding virsh net for $BRIDGE
  mkdir -p ~/virsh-configs/networks/
  cat << EOF > ~/virsh-configs/networks/${BRIDGE}.xml
<network>
  <name>$BRIDGE</name>
  <forward mode="bridge" />
  <bridge name="$BRIDGE" />
</network>
EOF
  sudo virsh net-define ~/virsh-configs/networks/${BRIDGE}.xml
  sudo virsh net-start ${BRIDGE}
  sudo virsh net-autostart ${BRIDGE}
done




