export NET_DEV="enp8s0"
sudo nmcli con |grep -E "${NET_DEV}"
export NM_NAME="Wired connection 1"

export NAME_BRIDGE=br0



## https://blog.christophersmart.com/2020/07/27/how-to-create-linux-bridges-and-open-vswitch-bridges-with-networkmanager/

echo working on $NET_DEV
sudo nmcli con delete $NAME_BRIDGE
sudo nmcli con delet $NAME_BRIDGE-slave-"${NET_DEV}"


sudo nmcli con add type bridge ifname "$NAME_BRIDGE" con-name "$NAME_BRIDGE" 802-3-ethernet.mtu 9000 bridge.stp no
sudo nmcli con add type bridge-slave ifname "${NET_DEV}" master $NAME_BRIDGE con-name $NAME_BRIDGE-slave-"${NET_DEV}"


sudo ip link show dev $NAME_BRIDGE
sudo ip link show dev "${NET_DEV}"

## create a DHCP entry for the bridge mnac
# 42:60:f7:7c:af:12



#sudo nmcli con modify $NAME_BRIDGE ipv4.method disabled ipv6.method disabled
#commented to  Allow it to get DHCP for the bridge

ip -d link list
#check the max supported MTU


sudo nmcli con down "${NM_NAME}" ; sudo nmcli con up $NAME_BRIDGE

sudo nmcli con delete "${NM_NAME}"


# https://blog.christophersmart.com/2021/07/18/how-to-create-vlan-trunks-and-access-ports-for-vms-on-linux-bridges-using-networkmanager-and-have-them-talk/

