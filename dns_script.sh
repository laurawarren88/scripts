#!/bin/bash

#dns setup

# Grab the IP address for ens33 interface
DNS_IP=$(hostname -I | awk '{print $1}')
echo "DNS IP: $DNS_IP"

# Define network script paths
NETWORK_SCRIPT="/etc/sysconfig/network-scripts/ifcfg-ens33"
SYSCONFIG="/etc/sysconfig/network"
HOSTS_FILE="/etc/hosts"

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

#Creating three files to set up your DNS
touch /etc/named.conf /var/named/fwd.lmw.local /var/named/rev.lmw.local
chmod a+rwx /etc/named.conf
chmod a+rwx /var/named/fwd.lmw.local
chmod a+rwx /var/named/rev.lmw.local
#All done with full permissions

#Now lets edit the first file: /etc/named.conf and input the zones
# Define the named.conf file path
NAMED_CONF="/etc/named.conf"

# Modify the "listen-on port 53" line
sed -i '/listen-on port 53 {/!b;n;c\listen-on port 53 { 127.0.0.1; 10.0.0.3; };' $NAMED_CONF
sed -i 's|listen-on port 53 { 127.0.0.1; };|listen-on port 53 { 127.0.0.1; 10.0.0.3; };|' $NAMED_CONF

# Modify the "listen-on-v6 port 53" line
sed -i '/listen-on-v6   { none; };/!b;n;c\listen-on-v6  { none; };' $NAMED_CONF
sed -i 's|listen-on-v6.*|listen-on-v6 { none; };|' $NAMED_CONF

# Modify the "allow-query" line
sed -i '/allow-query {/!b;n;c\allow-query { localhost; 10.0.0.0/24; any; };' $NAMED_CONF
sed -i 's|allow-query { localhost; };|allow-query { localhost; 10.0.0.0/24; any; };|' $NAMED_CONF

# Add the "forwarders" section before the closing '};' of the options block
if ! grep -q "forwarders {" $NAMED_CONF; then
    sudo sed -i '/options {/,/};/ s|};| forwarders {\n          8.8.8.8;\n              8.8.4.4;\n      };\n    forward only;\n};|' $NAMED_CONF
fi

if ! grep -q 'zone "lmw.local" IN {' $NAMED_CONF; then
bash -c "cat <<EOL >> $NAMED_CONF

zone \"lmw.local\" IN {
        type master;
        file \"/var/named/fwd.lmw.local\";
        allow-update { none; };
};

zone \"0.0.10.in-addr.arpa\" IN {
        type master;
        file \"/var/named/rev.lmw.local\";
        allow-update { none; };
};
EOL"
fi

# Define the file paths
FWD_ZONE_FILE="/var/named/fwd.lmw.local"
REV_ZONE_FILE="/var/named/rev.lmw.local"

bash -c "echo '\$TTL 86400' > $FWD_ZONE_FILE"
bash -c "echo '@       IN      SOA     dns.lmw.local. hostmaster.lmw.local. (' >> $FWD_ZONE_FILE"
bash -c "echo '                        2024083012 ;Serial' >> $FWD_ZONE_FILE"
bash -c "echo '                        3600 ;Refresh' >> $FWD_ZONE_FILE"
bash -c "echo '                        1800 ;Retry' >> $FWD_ZONE_FILE"
bash -c "echo '                        1209600 ;Expire' >> $FWD_ZONE_FILE"
bash -c "echo '                        86400 ;Minimum TTL' >> $FWD_ZONE_FILE"
bash -c "echo '                )' >> $FWD_ZONE_FILE"
bash -c "echo '' >> $FWD_ZONE_FILE"
bash -c "echo '@       IN      NS      dns.lmw.local.' >> $FWD_ZONE_FILE"
bash -c "echo '@       IN      A       10.0.0.3' >> $FWD_ZONE_FILE"
bash -c "echo '' >> $FWD_ZONE_FILE"
bash -c "echo 'lmw.local.      IN      A       10.0.0.3' >> $FWD_ZONE_FILE"
bash -c "echo 'www             IN      CNAME   lmw.local.' >> $FWD_ZONE_FILE"
bash -c "echo 'gateway         IN      A       10.0.0.1' >> $FWD_ZONE_FILE"
bash -c "echo 'dhcp            IN      A       10.0.0.2' >> $FWD_ZONE_FILE"
bash -c "echo 'dns             IN      A       10.0.0.3' >> $FWD_ZONE_FILE"

bash -c "echo '\$TTL 86400' > $REV_ZONE_FILE"
bash -c "echo '@       IN      SOA     dns.lmw.local. hostmaster.lmw.local. (' >> $REV_ZONE_FILE"
bash -c "echo '                        2024083012 ;Serial' >> $REV_ZONE_FILE"
bash -c "echo '                        3600 ;Refresh' >> $REV_ZONE_FILE"
bash -c "echo '                        1800 ;Retry' >> $REV_ZONE_FILE"
bash -c "echo '                        1209600 ;Expire' >> $REV_ZONE_FILE"
bash -c "echo '                        86400 ;Minimum TTL' >> $REV_ZONE_FILE"
bash -c "echo '                )' >> $REV_ZONE_FILE"
bash -c "echo '' >> $REV_ZONE_FILE"
bash -c "echo '@       IN      NS      dns.lmw.local.' >> $REV_ZONE_FILE"
bash -c "echo '' >> $REV_ZONE_FILE"
bash -c "echo '1       IN      PTR     gateway.lmw.local.   ;10.0.0.1' >> $REV_ZONE_FILE"
bash -c "echo '2       IN      PTR     dhcp.lmw.local.      ;10.0.0.2' >> $REV_ZONE_FILE"
bash -c "echo '3       IN      PTR     lmw.local.        ;10.0.0.3' >> $REV_ZONE_FILE"
#Both $FWD_ZONE_FILE and $REV_ZONE_FILE have been overwritten with the new zone information.

#Check that the files have compiled correctly and work
named-checkzone lmw.local /var/named/fwd.lmw.local
named-checkzone lmw.local /var/named/rev.lmw.local

#Now we can restart the BIND packages 
systemctl restart named
systemctl enable named

#Lets check it works
ping -c 2 8.8.8.8
ping -c 2 google.co.uk

