#!/bin/sh

while true; do    
   ChangeTime=`stat /etc/dhcpd/dhcpd-leases.log | grep Modify`
   if [[ "$ChangeTime" != "$LastChangeTime" ]]; then
     date
     echo "DHCP state changed at " + $ChangeTime + ". Updating DNS."
     /var/services/homes/admin/diskstation_dns_modify.sh
     LastChangeTime=$ChangeTime
   fi
   sleep 5
done


