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
#Your Firewall is $( firewall-cmd --state )"
#This is a list of your Firewall Commands $( firewall-cmd --list-all )"
#Lets make sure we can reach the internet and allow masquerading
firewall-cmd --add-masquerade --permanent
#Lets make sure the DHCP port:67 allows traffic and DNS port:53
#Port 67 TCP set up:
firewall-cmd --zone=public --add-port=67/tcp --permanent
#Port 67 UDP set up:
firewall-cmd --zone=public --add-port=67/udp --permanent
#echo "Port 68 TCP set up:"
firewall-cmd --zone=public --add-port=68/tcp --permanent
#echo "Port 68 UDP set up:"
firewall-cmd --zone=public --add-port=68/udp --permanent
#Port 53 TCP set up:
firewall-cmd --zone=public --add-port=53/tcp --permanent
#Port 53 UDP set up:
firewall-cmd --zone=public --add-port=53/udp --permanent
firewall-cmd --permanent --zone=public --add-icmp-block-inversion
firewall-cmd --reload
#Lets make sure the Firewall has made all those changes:
#firewall-cmd --list-all
systemctl restart firewalld

check_connected=$( nmcli | grep "ens" )
echo $check_connected

DHCP_IP=$( hostname -I )
echo $DHCP_IP

#Update mirrorlist and where gets CentOS
sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*

#Update packages
echo "....updating packages...bare with..."
yum update -y
echo "upgrading packages..."
yum upgrade -y

#Install DHCP
echo "Installing DHCP packages...another wait...almost there...."
yum install dhcp-client dhcp-libs dhcp-relay dhcp-server -y

#Lets make sure the DHCP listens on the network
DHCP_CONFIG=/etc/sysconfig/dhcpd
grep -q '^DHCPDARGS=' $DHCP_CONFIG && \
sed -i 's/^DHCPDARGS=.*/DHCPDARGS=ens33/' $DHCP_CONFIG || \
echo 'DHCPDARGS=ens33' >> $DHCP_CONFIG
#cat /etc/sysconfig/dhcpd

#echo "Lets set up a config file"
DHCP_PATH=/etc/dhcp/dhcpd.conf
chmod a+rwx /etc/dhcp/dhcpd.conf
bash -c "cat > $DHCP_PATH" << EOL
subnet 10.0.0.0 netmask 255.255.255.0 {
        range 10.0.0.10 10.0.0.100;
        option routers 10.0.0.1;
        option subnet-mask 255.255.255.0;
        option domain-name-servers 8.8.8.8, 8.8.4.4;
        option domain-name "lmw.local";
}
EOL

#DHCP configuration has been created at $DHCP_PATH

#Now we have done all those changes lets restart the server
systemctl restart dhcpd

#Lets ensure that all worked correctly
#systemctl status dhcpd

#Check everything configured correctly
chkconfig dhcpd on

