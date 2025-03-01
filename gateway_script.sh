#!/bin/bash
#gateway setup

IFCFG_ENS33="/etc/sysconfig/network-scripts/ifcfg-ens33"
IFCFG_ENS35="/etc/sysconfig/network-scripts/ifcfg-ens35"

# Create and populate /etc/sysconfig/network-scripts/ifcfg-ens35
bash -c "cat > $IFCFG_ENS35 <<EOL
TYPE=Ethernet
PROXY_METHOD=none
BROWSER_ONLY=no
BOOTPROTO=static
DEFROUTE=yes
IPV4_FAILURE_FATAL=no
IPV6INIT=yes
IPV6_AUTOCONF=yes
IPV6_DEFROUTE=yes
IPV6_FAILURE_FATAL=no
IPV6_ADDR_GEN_MODE=eui64
NAME=ens35
DEVICE=ens35
ONBOOT=yes
IPADDR=10.0.0.1
DNS=10.0.0.3
EOL"

systemctl restart NetworkManager

# Dynamically get the IPs for ens33 and ens35
IP_ENS33=$(nmcli -g IP4.ADDRESS dev show ens33 | cut -d'/' -f1)

# Retrieve the IP address of ens35
IP_ENS35=$(ip -4 addr show ens35 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# Detect the gateway IP for ens33
GATEWAY_IP=$(ip route | grep default | grep ens33 | awk '{print $3}')

# Fallback if the gateway IP is not detected
if [ -z "$GATEWAY_IP" ]; then
  GATEWAY_IP="172.16.6.179"  # Default or fallback gateway IP
fi

# Check if IP_ENS35 has been set
if [ -z "$IP_ENS35" ]; then
    echo "Error: Unable to retrieve IP address for ens35."
    exit 1
fi

# Add DNS=10.0.0.3 to /etc/sysconfig/network-scripts/ifcfg-ens33
# Check if the line already exists
grep -q "^DNS=10.0.0.3" $IFCFG_ENS33 | tee -a $IFCFG_ENS33

# Disable SELinux
setenforce 0

# Set the interfaces
firewall-cmd --permanent --zone=public --change-interface=ens33
firewall-cmd --permanent --zone=public --change-interface=ens35

# Add source IPs
firewall-cmd --permanent --zone=public --add-source=10.0.0.3
firewall-cmd --permanent --zone=public --add-source=10.0.0.2

# Add services
firewall-cmd --permanent --zone=public --add-service=cockpit
firewall-cmd --permanent --zone=public --add-service=dhcpv6-client
firewall-cmd --permanent --zone=public --add-service=ssh

# Add port 3000/tcp
firewall-cmd --permanent --zone=public --add-port=3000/tcp

# Enable masquerading
firewall-cmd --permanent --zone=public --add-masquerade

# Add forward-ports
firewall-cmd --permanent --zone=public --add-forward-port=port=67:proto=tcp:toport=80:toaddr=10.0.0.2
firewall-cmd --permanent --zone=public --add-forward-port=port=53:proto=tcp:toport=80:toaddr=10.0.0.3
firewall-cmd --permanent --zone=public --add-icmp-block-inversion

# Reload firewall to apply changes
firewall-cmd --reload

# Add static route using detected gateway IP
ip route add $GATEWAY_IP/32 dev ens35
ip route add default via $GATEWAY_IP dev ens35 metric 101
# Ensure persistent routes
echo "GATEWAY=$GATEWAY_IP" >> /etc/sysconfig/network-scripts/ifcfg-ens35
echo "$GATEWAY_IP/32 dev ens35" >> /etc/sysconfig/network-scripts/route-ens35

#Restart the server
systemctl restart NetworkManager

# Check connected interfaces
check_connected=$(nmcli | grep "ens")
echo $check_connected

# Display the external network IP
external_network=$(hostname -I | awk '{print $1}')
echo "External IP: $external_network"

# Display the internal network IP
internal_network=$(ip -4 addr show ens35 | grep -oP "(?<=inet\s)\d+(\.\d+){3}")
echo "Internal IP: $internal_network"

#allow port forwarding
sysctl -w net.ipv4.ip_forward=1

# Check if net.ipv4.ip_forward=1 is already in /etc/sysctl.conf
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

#Gateway setup complete
echo "Gateway complete"

