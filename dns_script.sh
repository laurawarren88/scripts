#!/bin/bash

#dns setup

# Grab the IP address for ens33 interface
DNS_IP=$(hostname -I | awk '{print $1}')
echo "DNS IP: $DNS_IP"

# Define network script paths
NETWORK_SCRIPT="/etc/sysconfig/network-scripts/ifcfg-ens33"
SYSCONFIG="/etc/sysconfig/network"
HOSTS_FILE="/etc/hosts"

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
update_network_config "IPADDR" "10.0.0.3" $NETWORK_SCRIPT
update_network_config "GATEWAY" "10.0.0.1" $NETWORK_SCRIPT
update_network_config "DNS" "10.0.0.3" $NETWORK_SCRIPT
update_network_config "DOMAIN" "lmw.local" $NETWORK_SCRIPT

#Change the BOOTPROTO to static
sed -i 's/BOOTPROTO=dhcp/BOOTPROTO=static/' $NETWORK_SCRIPT

# Configure /etc/sysconfig/network
update_network_config "NETWORKING" "yes" $SYSCONFIG
update_network_config "NETWORKING_IPV6" "no" $SYSCONFIG
update_network_config "HOSTNAME" "lmw.local" $SYSCONFIG
update_network_config "GATEWAY" "10.0.0.1" $SYSCONFIG

# Update /etc/hosts with static IP and hostname
if ! grep -q "10.0.0.3 lmw.local" $HOSTS_FILE; then
    echo "10.0.0.3 lmw.local" >> $HOSTS_FILE
fi

# Ensure 127.0.0.1 entry is correct
sed -i 's/127\.0\.0\.1.*/127.0.0.1 lmw.local localhost/' $HOSTS_FILE

# Set hostname and restart hostnamed service
hostnamectl set-hostname lmw.local
systemctl restart systemd-hostnamed

# Set up basic nameservers
echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" | tee /etc/resolv.conf

#Set default route
ip route add default via 10.0.0.1 dev ens33

#Firewall configuration for DNS (port 53)
firewall-cmd --zone=public --add-port=53/tcp --permanent
firewall-cmd --zone=public --add-port=53/udp --permanent
firewall-cmd --permanent --zone=public --add-icmp-block-inversion
firewall-cmd --reload

sleep 10

#Update mirrorlist and where gets CentOS
sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*

sleep 10

# Update and install packages
yum update -y 
yum makecache
yum install bind bind-utils -y

#Now we can restart the BIND packages 
systemctl restart named
systemctl enable named

# Generate rndc key
echo "Generating rndc key..."
rndc-confgen -a -b 512
chown named:named /etc/rndc.key
chmod 600 /etc/rndc.key

# Ensure BIND is running
systemctl restart named

NAMED_CONF="/etc/named.conf"
echo "Modifying named.conf..."

# Add controls section for rndc if not already present
if ! grep -q 'controls {' $NAMED_CONF; then
    cat <<EOL >> $NAMED_CONF
controls {
    inet 127.0.0.1 allow { localhost; } keys { "rndc-key"; };
};

key "rndc-key" {
    algorithm hmac-md5;
    secret "$(grep secret /etc/rndc.key | awk '{print $2}' | tr -d '\";')";
};
EOL
fi

# Add forward and reverse zone configuration if not present
if ! grep -q 'zone "lmw.local" IN {' $NAMED_CONF; then
    cat <<EOL >> $NAMED_CONF

zone "lmw.local" IN {
    type master;
    file "/var/named/fwd.lmw.local";
    allow-update { key "rndc-key"; };
};

zone "0.0.10.in-addr.arpa" IN {
    type master;
    file "/var/named/rev.lmw.local";
    allow-update { key "rndc-key"; };
};
EOL
fi

# Set proper permissions for zone files
chown named:named $FWD_ZONE_FILE $REV_ZONE_FILE
chmod 644 $FWD_ZONE_FILE $REV_ZONE_FILE

echo "Checking zone file syntax..."
named-checkzone lmw.local $FWD_ZONE_FILE
named-checkzone 0.0.10.in-addr.arpa $REV_ZONE_FILE

# Reload BIND and check status
echo "Reloading BIND and checking status..."
systemctl restart named
rndc reload
rndc status

echo "BIND setup completed."

# Path to rndc key
RNDC_KEY="/etc/rndc.key"

# Extract the secret for nsupdate
RNDC_SECRET=$(grep secret $RNDC_KEY | awk '{print $2}' | tr -d '";')

# Create a temp file for nsupdate commands
NSUPDATE_FILE="/tmp/nsupdate.txt"

# Function to perform DNS updates using nsupdate
nsupdate_add_record() {
    local record_name=$1
    local record_type=$2
    local record_value=$3

# Set proper permissions for zone files
chown named:named $FWD_ZONE_FILE $REV_ZONE_FILE
chmod 644 $FWD_ZONE_FILE $REV_ZONE_FILE

echo "Checking zone file syntax..."
named-checkzone lmw.local $FWD_ZONE_FILE
named-checkzone 0.0.10.in-addr.arpa $REV_ZONE_FILE

# Reload BIND and check status
echo "Reloading BIND and checking status..."
systemctl restart named
rndc reload
rndc status

echo "BIND setup completed."

# Path to rndc key
RNDC_KEY="/etc/rndc.key"

# Extract the secret for nsupdate
RNDC_SECRET=$(grep secret $RNDC_KEY | awk '{print $2}' | tr -d '";')

# Create a temp file for nsupdate commands
NSUPDATE_FILE="/tmp/nsupdate.txt"

# Function to perform DNS updates using nsupdate
nsupdate_add_record() {
    local record_name=$1
    local record_type=$2
    local record_value=$3

    echo "server 127.0.0.1" > $NSUPDATE_FILE
    echo "key rndc-key $RNDC_SECRET" >> $NSUPDATE_FILE
    echo "zone lmw.local" >> $NSUPDATE_FILE
    echo "update add $record_name 86400 $record_type $record_value" >> $NSUPDATE_FILE
    echo "send" >> $NSUPDATE_FILE

    # Run nsupdate
    nsupdate -v $NSUPDATE_FILE
}

# Function to remove DNS record using nsupdate
nsupdate_delete_record() {
    local record_name=$1
    local record_type=$2

    echo "server 127.0.0.1" > $NSUPDATE_FILE
    echo "key rndc-key $RNDC_SECRET" >> $NSUPDATE_FILE
    echo "zone lmw.local" >> $NSUPDATE_FILE
    echo "update delete $record_name $record_type" >> $NSUPDATE_FILE
    echo "send" >> $NSUPDATE_FILE

    # Run nsupdate
    nsupdate -v $NSUPDATE_FILE
}

# Add example A records dynamically using nsupdate
echo "Adding A records via nsupdate..."
nsupdate_add_record "newhost.lmw.local." "A" "10.0.0.4"
nsupdate_add_record "anotherhost.lmw.local." "A" "10.0.0.5"

# Optionally, delete a record
# echo "Deleting A record for newhost.lmw.local..."
# nsupdate_delete_record "newhost.lmw.local." "A"

# Clean up temporary file
rm -f $NSUPDATE_FILE

# Reload BIND after nsupdate changes
rndc reload

#Now we can restart the BIND packages 
systemctl restart named
systemctl enable named

#Lets check it works
ping -c 2 8.8.8.8
ping -c 2 google.com
