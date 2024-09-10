#!/bin/bash
# DNS setup script

# Variables
NETWORK_SCRIPT="/etc/sysconfig/network-scripts/ifcfg-ens33"
SYSCONFIG="/etc/sysconfig/network"
HOSTS_FILE="/etc/hosts"
NAMED_CONF="/etc/named.conf"
FWD_ZONE_FILE="/var/named/fwd.lmw.local"
REV_ZONE_FILE="/var/named/rev.lmw.local"
DNS_IP="10.0.0.3"
GATEWAY_IP="10.0.0.1"
DOMAIN="lmw.local"
RNDC_KEY="/etc/rndc.key"
NSUPDATE_FILE="/tmp/nsupdate.txt"

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

# Configure network settings
update_network_config "IPADDR" "$DNS_IP" $NETWORK_SCRIPT
update_network_config "GATEWAY" "$GATEWAY_IP" $NETWORK_SCRIPT
update_network_config "DNS" "$DNS_IP" $NETWORK_SCRIPT
update_network_config "DOMAIN" "$DOMAIN" $NETWORK_SCRIPT
update_network_config "NETWORKING" "yes" $SYSCONFIG
update_network_config "HOSTNAME" "$DOMAIN" $SYSCONFIG
update_network_config "GATEWAY" "$GATEWAY_IP" $SYSCONFIG
update_network_config "NETWORKING_IPV6" "no" $SYSCONFIG

# Remove UUID and set BOOTPROTO to static
sed -i '/^UUID=/d' $NETWORK_SCRIPT
sed -i 's/BOOTPROTO=dhcp/BOOTPROTO=static/' $NETWORK_SCRIPT

# Update /etc/hosts
if ! grep -q "$DNS_IP $DOMAIN" $HOSTS_FILE; then
    echo "$DNS_IP $DOMAIN" >> $HOSTS_FILE
fi

#Ensure 127.0.0.1 entry is correct
sed -i 's/127\.0\.0\.1.*/127.0.0.1 lmw.local localhost/' $HOSTS_FILE

#Set hostname and restart hostnamed service
hostnamectl set-hostname $DOMAIN
systemctl restart systemd-hostnamed

# Set up basic nameservers
echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" | tee /etc/resolv.conf

# Set default route
ip route add default via $GATEWAY_IP dev ens33

#Next, setup the firewall
echo "Setting up the Firewall"
systemctl start firewalld
echo "Lets make sure we can reach the internet and allow masquerading"
firewall-cmd --add-masquerade --permanent
echo "Lets make sure the DNS uses port: 53"
echo "Port 53 tcp:"
firewall-cmd --zone=public --add-port=53/tcp --permanent
echo "Port 53 udp:"
firewall-cmd --zone=public --add-port=53/udp --permanent
echo "Allow traffic from other VMs on our network"
firewall-cmd --permanent --zone=public --add-icmp-block-inversion
echo "After all those changes lets reload the firewall"
firewall-cmd --reload


sleep 10

# Update CentOS mirrorlist to use vault
sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*

sleep 10

# Update and install packages
# yum update -y
# yum makecache
yum install bind bind-utils -y

# Generate rndc key
echo "Generating rndc key..."
rndc-confgen -a -b 512
chown named:named $RNDC_KEY
chmod 600 $RNDC_KEY

# Extract RNDC key secret
RNDC_SECRET=$(grep -Eo 'secret ".*";' $RNDC_KEY | awk '{print $2}' | tr -d '";')


echo "Modifying named.conf..."
if ! grep -q 'controls {' $NAMED_CONF; then
    cat <<EOL >> $NAMED_CONF
controls {
    inet 127.0.0.1 allow { localhost; } keys { "rndc-key"; };
};

key "rndc-key" {
    algorithm hmac-md5;
    secret "$RNDC_SECRET";
};

zone "$DOMAIN" IN {
    type master;
    file "$FWD_ZONE_FILE";
    allow-update { key "rndc-key"; };
};

zone "0.0.10.in-addr.arpa" IN {
    type master;
    file "$REV_ZONE_FILE";
    allow-update { key "rndc-key"; };
};
EOL
fi

#Create forward and reverse zone files
cat <<EOL > $FWD_ZONE_FILE
\$TTL 86400
@   IN  SOA     ns1.$DOMAIN. admin.$DOMAIN. (
        2024091001 ; Serial
        3600       ; Refresh
        1800       ; Retry
        1209600    ; Expire
        86400 )    ; Minimum TTL
;
@   IN  NS      ns1.$DOMAIN.
ns1 IN  A       $DNS_IP
EOL

cat <<EOL > $REV_ZONE_FILE
\$TTL 86400
@   IN  SOA     ns1.$DOMAIN. admin.$DOMAIN. (
        2024091001 ; Serial
        3600       ; Refresh
        1800       ; Retry
        1209600    ; Expire
        86400 )    ; Minimum TTL
;
@   IN  NS      ns1.$DOMAIN.
3   IN  PTR     ns1.$DOMAIN.
EOL

# Set proper permissions for zone files
chown named:named $FWD_ZONE_FILE $REV_ZONE_FILE
chmod 644 $FWD_ZONE_FILE $REV_ZONE_FILE

echo "Checking zone file syntax..."
named-checkzone $DOMAIN $FWD_ZONE_FILE
named-checkzone 0.0.10.in-addr.arpa $REV_ZONE_FILE

# Reload BIND and check status
echo "Reloading BIND and checking status..."
systemctl restart named
systemctl enable named

# Function to perform DNS updates using nsupdate
nsupdate_add_record() {
    local action=$1
    local record_name=$2
    local record_type=$3
    local record_value=$4

    echo "server 127.0.0.1" > $NSUPDATE_FILE
    echo "key rndc-key $RNDC_SECRET" >> $NSUPDATE_FILE
    echo "zone $DOMAIN" >> $NSUPDATE_FILE
    echo "update $action $record_name $record_type $record_value" >> $NSUPDATE_FILE
    echo "send" >> $NSUPDATE_FILE

    #Run nsupdate
    nsupdate -v $NSUPDATE_FILE
}

# Add example A records dynamically using nsupdate
echo "Adding A records via nsupdate..."
nsupdate_add_record "add" "newhost.$DOMAIN." "A" "10.0.0.4"
nsupdate_add_record "add" "anotherhost.$DOMAIN." "A" "10.0.0.5"

# Reload BIND after nsupdate changes
rndc reload

# Clean up temporary file
rm -f $NSUPDATE_FILE

#Lets check it works
ping -c 2 8.8.8.8
ping -c 2 google.com
