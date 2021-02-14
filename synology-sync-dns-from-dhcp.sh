#!/bin/ash

ScriptPath=$0
ScriptDir=$(dirname $ScriptPath)

# -----------------------------------------------------------------------------

Log(){
    d=$(date +%F_%T)
    echo "$d - $*"
}

Fail(){
  Log "Error:" "$@"
  exit 1
}

# -----------------------------------------------------------------------------

LogDir=$ScriptDir/logs
BackupDir=$ScriptDir/dns-backups
TempDir=$ScriptDir/temp

if ! mkdir -p ${LogDir}; then
  # The next line will probably fail as it tries to log stuff with no log directory but oh well
  Fail "Cannot create log directory." 
fi

if ! mkdir -p ${BackupDir}; then
  Fail "Cannot create backup directory."
fi

if ! mkdir -p ${TempDir}; then
  Fail "Cannot create temp directory."
fi

# -----------------------------------------------------------------------------
# Args

Poll=
Help=
Verbose=

for Arg in "$@"; do
  if [ "$Arg" = "--poll" ] || [ "$Arg" = "-p" ]; then
    Poll=poll
  elif [ "$Arg" = "--help" ] || [ "$Arg" = "-h" ] || [ "$Arg" = "-?" ]; then
    Help=help
  elif [ "$Arg" = "--verbose" ] || [ "$Arg" = "-v" ]; then
    Verbose=verbose
  else
    printf "Unknown argument [$Arg]. Try --help.\n"
    exit 1
  fi
done

# TODO: Actually write help


# -----------------------------------------------------------------------------
# Settings

GetSetting(){
  # $1 is both script global variable name and the parameter name in settings file
  SettingsFile=$ScriptDir/settings
  if [ -r $SettingsFile ]; then
    # TODO Peter: I would like to know why "$(cat etc.)" doesn't work, why I have to assign it into an (ignored) variable
    if _=$(cat $SettingsFile | grep $1=); then
      _Value=$(cat $SettingsFile | grep $1= | head -1 | cut -f2 -d"=")
      eval "$1=$_Value"
    else
      Fail "Error: Settings file [$SettingsFile] contained no setting [$1]."
    fi
  else
    Fail "Error: No settings file [$SettingsFile]."
  fi
}

GetSetting YourNetworkName
GetSetting ForwardMasterFile
GetSetting ReverseMasterFile


# -----------------------------------------------------------------------------

Update()(
  # That ( makes this a "subshell" function)

  DhcpLogFile=/etc/dhcpd/dhcpd-leases.log
  ZoneRootDir=/var/packages/DNSServer/target
  ZonePath=$ZoneRootDir/named/etc/zone/master
  DHCPAssigned=/etc/dhcpd/dhcpd.conf

  Log "Updating DNS to reflect current DHCP state..."

  NetworkInterfaces=",`ip -o link show | awk -F': ' '{printf $2","}'`"

  Log "Network interfaces:"
  Log $NetworkInterfaces
)

# -----------------------------------------------------------------------------
# Actually do stuff!

if [ "$Poll" ]; then
  # Loop forever Update()ing whenever it seems necessary
  while true; do    
    ChangeTime=`stat $DhcpLogFile | grep Modify`
    if [[ "$ChangeTime" != "$LastChangeTime" ]]; then
      date
      echo "DHCP state changed at [" + $ChangeTime + "]. Updating DNS."
      Update
      LastChangeTime=$ChangeTime
    fi
    sleep 5
  done
else
  # Just Update() once
  Update
fi

exit 0

# -----------------------------------------------------------------------------
# Bits to ripple up into the end of Update





# An address may not have been assigned yet so verify
# the leases log file exists before assigning.
DHCPLeases=/etc/dhcpd/dhcpd-leases.log
[ -f $DHCPLeases ] && DHCPAssigned="$DHCPAssigned $DHCPLeases"

DHCPStatic=/etc/dhcpd/dhcpd-static-static.conf
# this file may not exist if you haven't configured anything in the dhcp static reservations list (mac addr -> ip addr)
[ -f $DHCPStatic ] && DHCPAssigned="$DHCPAssigned $DHCPStatic"

DHCPeth0=/etc/dhcpd/dhcpd-eth0-static.conf
#Reportedly, this is the name of the leases file under DSM 6.0.  If it exists, we scan it.
[ -f $DHCPeth0 ] && DHCPAssigned="$DHCPAssigned $DHCPeth0"

DHCPLeaseFile=/etc/dhcpd/dhcpd.conf.leases
[ -f $DHCPLeaseFile ] && DHCPAssigned="$DHCPAssigned $DHCPLeaseFile"

##########################################################################
# Verify files exist and appropriate rights are granted
# Fail if environment is not set up correctly.
#TODO

##########################################################################
# Back up the forward and reverse master files
# Two options: a) One backup which is overwritten each time 
# or b) file is backed up once each day... but only the first use and
# retained for one year.
#

tmpPrefix=$BackupDir/DNS_Backup_$(date +%m%d)
Log "Backing up DNS files to $tmpPrefix.*"
[ -f $tmpPrefix.$ForwardMasterFile ] && Log "INFO: Forward master already backed up for today." || cp -a $ZonePath/$ForwardMasterFile $tmpPrefix.$ForwardMasterFile
[ -f $tmpPrefix.$ReverseMasterFile ] && Log "INFO: Reverse master already backed up for today." || cp -a $ZonePath/$ReverseMasterFile $tmpPrefix.$ReverseMasterFile

# Declare reusable functions.  Logic is pretty much the same for forward and reverse files.
printPartialDNSFile () {
   # Pass in the DNS file to process (forward or reverse master)
   # Print everything except for PTR and A records.
   # The only exception are "ns.domain" records.  We keep those.
   #Assumptions:
   # PTR and A records should be removed unless they contain "ns.<YourNetworkName>."
   awk '
      {
		if ($5 != ";dynamic") {
			PrintThis=1;
		} else{
			PrintThis=0;
		}
      }
      (PrintThis == 1) {print $0 }
   ' $1
}

printDhcpAsRecords () {
	# Pass in "A" for A records and "PTR" for PTR records.
	# Process the DHCP static and dynamic records
	# Logic is the same for PTR and A records.  Just a different print output.
	# Sorts and remove duplicates. Filters records you don't want.
    awk -v YourNetworkName=$YourNetworkName -v RecordType=$1  -v StaticRecords=$2 -v adapters=$NetworkInterfaces '
        BEGIN {
           # Set awks field separator
           FS="[\t =,]";
        }
        {IP=""} # clear out variables
        # Leases start with numbers. Do not use if column 4 is an interface
        $1 ~ /^[0-9]/ {  if(NF>4 || index(adapters, "," $4 "," ) == 0) { IP=$3; NAME=$4; RENEW=86400 } } 
        # Static assignments start with dhcp-host
        $1 == "dhcp-host" {IP=$4; NAME=$3; RENEW=$5}
        # If we have an IP and a NAME (and if name is not a placeholder)
        (IP != "" && NAME!="*" && NAME!="") {
           split(IP,arr,".");
           ReverseIP = arr[4] "." arr[3] "." arr[2] "." arr[1];
           if(RecordType == "PTR" && index(StaticRecords, ReverseIP ".in-addr.arpa.," ) > 0) {IP="";}
           if(RecordType == "A" && index(StaticRecords, NAME "." YourNetworkName ".," ) > 0) {IP="";}
           # Remove invalid characters according to rfc952
           gsub(/([^a-zA-Z0-9-]*|^[-]*|[-]*$)/,"",NAME)
           # Print the last number in the IP address so we can sort the addresses
           # Add a tab character so that "cut" sees two fields... it will print the second
           # field and remove the first which is the last number in the IP address.
           if(IP != "" && NAME!="*" && NAME!="") {
               if (RecordType == "PTR") {print 1000 + arr[4] "\t" ReverseIP ".in-addr.arpa.\t" RENEW "\tPTR\t" NAME "." YourNetworkName ".\t;dynamic"}
               if (RecordType == "A") print 2000 + arr[4] "\t" NAME "." YourNetworkName ".\t" RENEW "\tA\t" IP "\t;dynamic"
           }
        }
    ' $DHCPAssigned| sort | cut -f 2- | uniq	
	
	
}

incrementSerial () {
# serial number must be incremented in SOA record when DNS changes are made so that slaves will recognize a change
  ser=$(sed -e '1,/.*SOA/d' $1 | sed -e '2,$d' -e 's/;.*//' )  #isolate DNS serial from first line following SOA
  comments=$(sed -e '1,/.*SOA/d' $1 | sed -e '2,$d' | sed -n '/;/p' |sed -e 's/.*;//' )  #preserve any comments, if any exist
  bumpedserial=$(( $ser +1 ))

  sed -n '1,/.*SOA/p' $1
  echo -e "\t$bumpedserial ;$comments"
  sed -e '1,/.*SOA/d' $1 | sed -n '2,$p'


}
##########################################################################
# FORWARD MASTER FILE FIRST - (Logic is the same for both)
# Print everything except for PTR and A records.
# The only exception are "ns.domain" records.  We keep those.
#Assumptions:
# PTR and A records should be removed unless they contain "ns.<YourNetworkName>."
Log "Regenerating forward master file $ForwardMasterFile"
PARTIAL="$(printPartialDNSFile $ZonePath/$ForwardMasterFile)"
Log "forward master file static DNS addresses:"
echo "$PARTIAL"
echo
STATIC=$(echo "$PARTIAL"|awk '{if(NF>3 && NF<6) print $1}'| tr '\n' ',')
echo "$PARTIAL"  > $BackupDir/$ForwardMasterFile.new
Log "adding these DHCP leases to DNS forward master file:"
printDhcpAsRecords "A" $STATIC
echo
printDhcpAsRecords "A" $STATIC >> $BackupDir/$ForwardMasterFile.new

incrementSerial $BackupDir/$ForwardMasterFile.new > $BackupDir/$ForwardMasterFile.bumped

##########################################################################
# REVERSE MASTER FILE - (Logic is the same for both)
# Print everything except for PTR and A records.
# The only exception are "ns.domain" records.  We keep those.
#Assumptions:
# PTR and A records should be removed unless they contain "ns.<YourNetworkName>."
Log "Regenerating reverse master file $ReverseMasterFile"
PARTIAL="$(printPartialDNSFile $ZonePath/$ReverseMasterFile)"
STATIC=$(echo "$PARTIAL"|awk '{if(NF>3 && NF<6) print $1}'| tr '\n' ',')
Log "Reverse master file static DNS addresses:"
echo "$PARTIAL"
echo
echo "$PARTIAL" > $BackupDir/$ReverseMasterFile.new
Log "adding these DHCP leases to DNS reverse master file: "
printDhcpAsRecords "PTR" $STATIC
echo
printDhcpAsRecords "PTR" $STATIC >> $BackupDir/$ReverseMasterFile.new
incrementSerial $BackupDir/$ReverseMasterFile.new > $BackupDir/$ReverseMasterFile.bumped


##########################################################################
# Ensure the owner/group and modes are set at default
# then overwrite the original files
Log "Overwriting with updated files: $ForwardMasterFile $ReverseMasterFile"
if ! chown nobody:nobody $BackupDir/$ForwardMasterFile.bumped $BackupDir/$ReverseMasterFile.bumped ; then
  Log "Error:  Cannot change file ownership"
  Log ""
  Log "Try running this script as root for correct permissions"
  exit 4
fi
chmod 644 $BackupDir/$ForwardMasterFile.bumped $BackupDir/$ReverseMasterFile.bumped
#cp -a $BackupDir/$ForwardMasterFile.new $ZonePath/$ForwardMasterFile 
#cp -a $BackupDir/$ReverseMasterFile.new $ZonePath/$ReverseMasterFile 

mv -f $BackupDir/$ForwardMasterFile.bumped $ZonePath/$ForwardMasterFile
mv -f $BackupDir/$ReverseMasterFile.bumped $ZonePath/$ReverseMasterFile

# -----------------------------------------------------------------------------
# Reload the server config after modifications
$ZoneRootDir/script/reload.sh

Log "$0 complete."
exit 0



