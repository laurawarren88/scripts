#!/bin/bash
#dns setup
check_connected=$( nmcli | grep "ens" )
echo $check_connected

DHCP_IP=$( hostname -I )
echo $DHCP_IP

echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" | tee /etc/resolv.conf

#Add information to network scripts - Boot Protocol, IP Address and Gateway
NETWORK_SCRIPT="/etc/sysconfig/network-scripts/ifcfg-ens33"

#Adding IP address
IPADDR=10.0.0.3 >> $NETWORK_SCRIPT
grep -q '^IPADDR=' $NETWORK_SCRIPT && \
sed -i 's/^IPADDR=.*/IPADDR=10.0.0.3/' $NETWORK_SCRIPT ||
echo 'IPADDR=10.0.0.3' >> $NETWORK_SCRIPT

#Adding Gateway address
GATEWAY=10.0.0.1 >> $NETWORK_SCRIPT
grep -q '^GATEWAY=' $NETWORK_SCRIPT && \
sed -i 's/^GATEWAY=.*/GATEWAY=10.0.0.1/' $NETWORK_SCRIPT || \
echo 'GATEWAY=10.0.0.1' >> $NETWORK_SCRIPT

#Change the BOOTPROTO to static
sed -i 's/BOOTPROTO=dhcp/BOOTPROTO=static/' $NETWORK_SCRIPT

#Adding DNS address
DNS=10.0.0.3 >> $NETWORK_SCRIPT
grep -q '^DNS=' $NETWORK_SCRIPT && \
sed -i 's/^DNS=.*/DNS=10.0.0.3/' $NETWORK_SCRIPT || \
echo 'DNS=10.0.0.3' >> $NETWORK_SCRIPT

#Adding a domain
DOMAIN="lmw.local" >> $NETWORK_SCRIPT
grep -q '^DOMAIN=' $NETWORK_SCRIPT && \
sed -i 's/^DOMAIN=.*/DOMAIN=lmw.local/' $NETWORK_SCRIPT || \
echo 'DOMAIN=lmw.local' >> $NETWORK_SCRIPT

#Let's set up our system Configuration
SYSCONFIG="/etc/sysconfig/network"

#Adding Neworking
NETWORKING="yes" >> $SYSCONFIG
grep -q '^NETWORKING=' $SYSCONFIG && \
sed -i 's/^NETWORKING=.*/NETWORKING=yes/' $SYSCONFIG ||
echo 'NETWORKING=yes' >> $SYSCONFIG

#Removing Neworking IPV6
NETWORKING_IPV6="no" >> $SYSCONFIG
grep -q '^NETWORKING_IPV6=' $SYSCONFIG && \
sed -i 's/^NETWORKING_IPV6=.*/NETWORKING_IPV6=no/' $SYSCONFIG ||
echo 'NETWORKING_IPV6=no' >> $SYSCONFIG

#Setting Hostname
HOSTNAME="lmw.local" >> $SYSCONFIG
grep -q '^HOSTNAME=' $SYSCONFIG && \
sed -i 's/^HOSTNAME=.*/HOSTNAME=lmw.local/' $SYSCONFIG ||
echo 'HOSTNAME=lmw.local' >> $SYSCONFIG

#Adding the gateway
GATEWAY=10.0.0.1 >> $SYSCONFIG
grep -q '^GATEWAY=' $SYSCONFIG && \
sed -i 's/^GATEWAY=.*/GATEWAY=10.0.0.1/' $SYSCONFIG ||
echo 'GATEWAY=10.0.0.1' >> $SYSCONFIG

#Let's set up our host
# Define the /etc/hosts file path
HOSTS_FILE="/etc/hosts"

# Add the line "10.0.0.3 lmw.local" if it doesn't already exist, accounting for tabs and spaces
if ! grep -qP "^\s*10\.0\.0\.3\s+lmw\.local\s*$" $HOSTS_FILE; then
    echo "Adding '10.0.0.3 lmw.local' to $HOSTS_FILE"
    bash -c "echo -e '10.0.0.3\tlmw.local' >> $HOSTS_FILE"
fi

# Modify the line with 127.0.0.1
if grep -qP "^\s*127\.0\.0\.1\s+localhost" $HOSTS_FILE; then
    echo "Modifying 127.0.0.1 line in $HOSTS_FILE"
    sed -i 's/^\s*127\.0\.0\.1\s+.*/127.0.0.1 lmw.local localhost/' $HOSTS_FILE
fi

#Hosts file update complete.

#Ensure hostname is set
hostnamectl set-hostname lmw.local
systemctl restart systemd-hostnamed
DNS_HOSTNAME=$( hostname -f)
echo $DNS_HOSTNAME

ip route add default via 10.0.0.1 dev ens33

#Now all the files have been configured, lets sort out the firewall
firewall-cmd --zone=public --add-port=53/tcp --permanent
firewall-cmd --zone=public --add-port=53/udp --permanent
firewall-cmd --permanent --zone=public --add-icmp-block-inversion
systemctl restart firewalld

#Update mirrorlist and where gets CentOS
sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*

#updating packages
yum update -y
#upgrading packages
yum upgrade -y
#Install other necessary DHCP packages
yum makecache
Install BIND
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
ping -c 3 8.8.8.8
ping -c 2 10.0.0.1
ping -c 2 10.0.0.2
ping -c 2 google.co.uk

