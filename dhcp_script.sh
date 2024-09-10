 #!/bin/bash
#Setting up the DHCP for the network

#Adding google to the path in order to reach the internet
echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" | tee /etc/resolv.conf

echo "Allow port forwarding"
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf 2>/dev/null

check_connected=$( nmcli | grep "ens" )
echo $check_connected

DHCP_IP=$( hostname -I )
echo "Your hostname is:" $DHCP_IP

#Update mirrorlist and where gets CentOS
sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*

#Setting up all the variables
#Add information to network scripts - Boot Protocol, IP Address and Gateway
NETWORK_SCRIPT="/etc/sysconfig/network-scripts/ifcfg-ens33"
DHCP_CONFIG="/etc/sysconfig/dhcpd"

# Function to update network config
update_network_config() {
    local key=$1
    local value=$2
    local file=$3

    if grep -q "^$key=" $file; then
        sed -i "s/^$key=.*/$key=$value/" $file
    else
        echo "$key=$value" >> $file
    fi
}

# Set static IP, Gateway, DNS, and domain in network script
update_network_config "IPADDR" "10.0.0.2" $NETWORK_SCRIPT
update_network_config "GATEWAY" "10.0.0.1" $NETWORK_SCRIPT
update_network_config "DNS" "10.0.0.3" $NETWORK_SCRIPT
# Remove UUID
sed -i '/^UUID=/d' $NETWORK_SCRIPT
#Change the BOOTPROTO to static
sed -i 's/BOOTPROTO=dhcp/BOOTPROTO=static/' $NETWORK_SCRIPT

#Ensure the VM connects through the Gateway
ip route add 172.16.6.0/24 via 10.0.0.1 dev ens33
ip route add default via 10.0.0.1 dev ens33

# Disable SELinux
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/sysconfig/selinux
setenforce 0

#Next, setup the firewall
echo "Now let's setup the Firewall"
systemctl start firewalld
echo "Lets make sure we can reach the internet and allow masquerading"
firewall-cmd --add-masquerade --permanent
echo "Lets make sure the DHCP port:67, 68 & 53 allows traffic"
echo "Port 67 tcp:"
firewall-cmd --zone=public --add-port=67/tcp --permanent
echo “Port 67 udp:
firewall-cmd --zone=public --add-port=67/udp --permanent
echo "Port 68 tcp:"
firewall-cmd --zone=public --add-port=68/tcp --permanent
echo "Port 68 udp:"
firewall-cmd --zone=public --add-port=68/udp --permanent
echo "Port 53 tcp:"
firewall-cmd --zone=public --add-port=53/tcp --permanent
echo "Port 53 udp:"
firewall-cmd --zone=public --add-port=53/udp --permanent
echo "Allow traffic from other VMs on our network"
firewall-cmd --permanent --zone=public --add-icmp-block-inversion
echo "After all those changes lets reload the firewall"
firewall-cmd --reload
systemctl restart firewalld

#Install DHCP
echo "Installing necessary DHCP packages"
yum install dhcp-client dhcp-libs dhcp-relay dhcp-server -y
yum install bind bind-utils -y

#ISetting up other variables now have the packages installed
NAMED_CONF="/etc/named.conf"
DHCPD_CONF="/etc/dhcp/dhcpd.conf"

echo "Lets make sure the DHCP listens on the network"
update_network_config "DHCPDARGS" "ens33" $DHCP_CONFIG

# Generate rndc key and set ownership and permissions
echo "Generating rndc key..."
rndc-confgen -a -b 512
chmod 740 /etc/rndc.key
echo "Extracting the key"
cat /etc/rndc.key
# Extract the secret key from the rndc.key file
RNDC_SECRET=$(grep -Eo 'secret ".*";' /etc/rndc.key | awk '{print $2}' | tr -d '";')
echo "Extracted RNDC secret key: $RNDC_SECRET"

# Validate if the RNDC secret is properly extracted
if [ -z "$RNDC_SECRET" ]; then
    echo "Error: Failed to extract the RNDC secret key!"
    exit 1
fi

# Ensure BIND is running
systemctl restart named

# Modifying named.conf to include controls and zone definitions
if ! grep -q "key \"rndc-key\"" $NAMED_CONF; then
    echo "Adding RNDC key to named.conf..."
    cat <<EOL >> $NAMED_CONF
controls {
    inet 127.0.0.1 allow { localhost; } keys { "rndc-key"; };
};
key "rndc-key" {
    algorithm hmac-md5;
    secret $RNDC_SECRET;
};
EOL
fi

# Modify dhcpd.conf to include the secret key for DDNSif ! grep -q "key \"rndc-key\"" $DHCPD_CONF; then
if ! grep -q "key \"rndc-key\"" $DHCPD_CONF; then
echo "Adding RNDC key to dhcpd.conf..."
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
fi

# Restart the DHCP service to apply changes
systemctl restart dhcpd

#DHCP setup complete
echo "DHCP complete"
