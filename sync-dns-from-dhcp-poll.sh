#!/bin/sh

Script=$(dirname $0)/diskstation_dns_modify.sh
DhcpLog=/etc/dhcpd/dhcpd-leases.log

while true; do    
   ChangeTime=`stat $DhcpLog | grep Modify`
   if [[ "$ChangeTime" != "$LastChangeTime" ]]; then
     date
     echo "DHCP state changed at [" + $ChangeTime + "]. Updating DNS."
     $Script
     LastChangeTime=$ChangeTime
   fi
   sleep 5
done


