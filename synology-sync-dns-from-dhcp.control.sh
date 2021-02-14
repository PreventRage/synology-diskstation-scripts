#!/bin/sh
#
# This script should be installed on a synology diskstation in the following
# folder for automatic startup:
#
# /usr/local/etc/rc.d/
#
# All it does is reach into the "install directory" and run control.sh
Name=synology-sync-dns-from-dhcp
/var/services/homes/admin/$Name/control.sh "$@"
