#!/bin/bash
#Setting up the DHCP for the network

echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" | tee /etc/resolv.conf

#Add information to network scripts - Boot Protocol, IP Address and Gateway
NETWORK_SCRIPT="/etc/sysconfig/network-scripts/ifcfg-ens33"

# Remove UUID
sed -i '/^UUID=/d' $NETWORK_SCRIPT

#Adding IP address
IPADDR=10.0.0.2 >> $NETWORK_SCRIPT
grep -q '^IPADDR=' $NETWORK_SCRIPT && \
sed -i 's/^IPADDR=.*/IPADDR=10.0.0.2/' $NETWORK_SCRIPT ||
echo 'IPADDR=10.0.0.2' >> $NETWORK_SCRIPT

#Adding Gateway address
GATEWAY=10.0.0.1 >> $NETWORK_SCRIPT
grep -q '^GATEWAY=' $NETWORK_SCRIPT && \
sed -i 's/^GATEWAY=.*/GATEWAY=10.0.0.1/' $NETWORK_SCRIPT || \
echo 'GATEWAY=10.0.0.1' >> $NETWORK_SCRIPT

#echo "Adding DNS1 address"
DNS1=8.8.8.8 >> $NETWORK_SCRIPT
grep -q '^DNS1=' $NETWORK_SCRIPT && \
sed -i 's/^DNS1=.*/DNS1=8.8.8.8/' $NETWORK_SCRIPT || \
echo 'DNS1=8.8.8.8' >> $NETWORK_SCRIPT

#echo "Adding DNS2 address"
DNS2=8.8.4.4 >> $NETWORK_SCRIPT
grep -q '^DNS2=' $NETWORK_SCRIPT && \
sed -i 's/^DNS2=.*/DNS2=8.8.4.4/' $NETWORK_SCRIPT || \
echo 'DNS2=8.8.4.4' >> $NETWORK_SCRIPT

#Change the BOOTPROTO to stati
sed -i 's/BOOTPROTO=dhcp/BOOTPROTO=static/' $NETWORK_SCRIPT

sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

ip route add 172.16.6.0/24 via 10.0.0.1 dev ens33
ip route add default via 10.0.0.1 dev ens33

# Disable SELinux
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/sysconfig/selinux
setenforce 0

#Next, setup the firewall
echo "Now let's setup the Firewall"
systemctl start firewalld
#Lets make sure we can reach the internet and allow masquerading
firewall-cmd --add-masquerade --permanent
#Lets make sure the DHCP port:67 allows traffic and DNS port:53
firewall-cmd --zone=public --add-port=67/tcp --permanent
firewall-cmd --zone=public --add-port=67/udp --permanent
firewall-cmd --zone=public --add-port=68/tcp --permanent
firewall-cmd --zone=public --add-port=68/udp --permanent
firewall-cmd --zone=public --add-port=53/tcp --permanent
firewall-cmd --zone=public --add-port=53/udp --permanent
firewall-cmd --permanent --zone=public --add-icmp-block-inversion
firewall-cmd --reload
systemctl restart firewalld

check_connected=$( nmcli | grep "ens" )
echo $check_connected

DHCP_IP=$( hostname -I )
echo $DHCP_IP

#Update mirrorlist and where gets CentOS
sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*

#Update packages
yum update -y
yum upgrade -y

#Install DHCP
yum install dhcp-client dhcp-libs dhcp-relay dhcp-server -y
yum install bind bind-utils -y

#Lets make sure the DHCP listens on the network
DHCP_CONFIG=/etc/sysconfig/dhcpd
grep -q '^DHCPDARGS=' $DHCP_CONFIG && \
sed -i 's/^DHCPDARGS=.*/DHCPDARGS=ens33/' $DHCP_CONFIG || \
echo 'DHCPDARGS=ens33' >> $DHCP_CONFIG

# Generate rndc key and set ownership and permissions
#echo "Generating rndc key..."
rndc-confgen -a -b 512
chmod 740 /etc/rndc.key
echo "Extracting the key"
#cat /etc/rndc.key
# Extract the secret key from the rndc.key file
RNDC_SECRET=$(grep -Eo 'secret ".*";' /etc/rndc.key | awk '{print $2}' | tr -d '";')
#echo "Extracted RNDC secret key: $RNDC_SECRET"


# Validate if the RNDC secret is properly extracted
if [ -z "$RNDC_SECRET" ]; then
    echo "Error: Failed to extract the RNDC secret key!"
    exit 1
fi

# Ensure BIND is running
systemctl restart named

# Modifying named.conf to include controls and zone definitions
NAMED_CONF="/etc/named.conf"
if ! grep -q "key \"rndc-key\"" $NAMED_CONF; then
#   echo "Adding RNDC key to named.conf..."
    cat <<EOL >> $NAMED_CONF
controls {
    inet 127.0.0.1 allow { localhost; } keys { "rndc-key"; };
};

key "rndc-key" {
    algorithm hmac-md5;
    secret $RNDC_SECRET;
};
EOL
 # Debug: Show confirmation of changes to named.conf
    echo "named.conf modified:"
    tail -n 20 $NAMED_CONF
#else
#   echo "named.conf already contains controls section."
fi

# Modify dhcpd.conf to include the secret key for DDNS
DHCPD_CONF="/etc/dhcp/dhcpd.conf"

if ! grep -q "key \"rndc-key\"" $DHCPD_CONF; then
#    echo "Adding RNDC key to dhcpd.conf..."
    cat <<EOL >> $DHCPD_CONF
ddns-update-style interim;
ignore client-updates;

key rndc-key {
    algorithm hmac-md5;
    secret $RNDC_SECRET;
};

zone lmw.local. {
    primary 10.0.0.3;  # IP of your DNS server
    key rndc-key;
}

zone 0.0.10.in-addr.arpa. {
    primary 10.0.0.3;
    key rndc-key;
}

subnet 10.0.0.0 netmask 255.255.255.0 {
    range 10.0.0.10 10.0.0.100;
    option domain-name-servers 10.0.0.3;
    option domain-name "lmw.local";
    option routers 10.0.0.1;
    option broadcast-address 10.0.0.255;
    default-lease-time 600;
    max-lease-time 7200;
}
EOL
# Debug: Show confirmation of changes to dhcpd.conf
#    echo "dhcpd.conf modified:"
#   tail -n 20 $DHCPD_CONF
else
    echo "dhcpd.conf already contains key configuration."
fi

# Restart the DHCP service to apply changes
systemctl restart dhcpd

#DHCP setup complete
echo "DHCP complete"

