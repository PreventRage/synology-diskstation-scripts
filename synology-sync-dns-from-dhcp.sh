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

EchoOver(){
  if [ "$1" ]; then
    c=$((${#1}+1))
      # expression containing an arithmetic expression
      # ${#varname} is length of value of varname
    echo "$1 ${2:$c}"
  else
    echo "$2"
  fi
}

EchoBegin(){
  EchoOver "$1" ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
}

EchoEnd(){
  EchoOver "$1" "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"
}

# -----------------------------------------------------------------------------

LogDir=$ScriptDir/logs
BackupDir=$ScriptDir/backup
TempDir=$ScriptDir/temp

if ! mkdir -p ${LogDir}; then
  # The next line will probably fail as it tries to log stuff with no log directory but oh well
  Fail "Cannot create log directory [$LogDir]" 
fi

if ! mkdir -p ${BackupDir}; then
  Fail "Cannot create backup directory [$BackupDir]"
fi

if ! mkdir -p ${TempDir}; then
  Fail "Cannot create temp directory. [$TempDir]"
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




# -----------------------------------------------------------------------------

Update()(
  # That "("" makes this a "subshell" function which can have its own inner functions


  Log "Updating DNS to reflect current DHCP state"

  # -----------------------------------------------------------------------------

  GetSetting(){
    # $1 is both script global variable name and the parameter name in settings file
    SettingsFile=$ScriptDir/settings
    if [ -r $SettingsFile ]; then
      # TODO Peter: I would like to know why "$(cat etc.)" doesn't work, why I have to assign it into an (ignored) variable
      if _Dummy=$(cat $SettingsFile | grep $1=); then
        _Value=$(cat $SettingsFile | grep $1= | head -1 | cut -f2 -d"=")
        eval "$1=$_Value"
      else
        Fail "Error: Settings file [$SettingsFile] contained no setting [$1]"
      fi
    else
      Fail "Error: No settings file [$SettingsFile]"
    fi
  }

  GetSetting YourNetworkName
  GetSetting ForwardMasterFile
  GetSetting ReverseMasterFile

  # -----------------------------------------------------------------------------

  ZoneRootDir=/var/packages/DNSServer/target
  ZonePath=$ZoneRootDir/named/etc/zone/master

  NetworkInterfaces=",`ip -o link show | awk -F': ' '{printf $2","}'`"
  Log "Network interfaces: $NetworkInterfaces"

  # ---------------------------------------------------------------------------
  DhcpFiles=/etc/dhcpd/dhcpd.conf

  f=/etc/dhcpd/dhcpd-leases.log
  [ -f $f ] && DhcpFiles="$DhcpFiles $f"

  f=/etc/dhcpd/dhcpd-static-static.conf
  # this file may not exist if you haven't configured anything in the dhcp static reservations list (mac addr -> ip addr)
  [ -f $f ] && DhcpFiles="$DhcpFiles $f"

  f=/etc/dhcpd/dhcpd-eth0-static.conf
  #Reportedly, this is the name of the leases file under DSM 6.0.  If it exists, we scan it.
  [ -f $f ] && DhcpFiles="$DhcpFiles $f"

  f=/etc/dhcpd/dhcpd.conf.leases
  [ -f $f ] && DhcpFiles="$DhcpFiles $f"

  Log "DHCP Files: $DhcpFiles"

  # ---------------------------------------------------------------------------
  # TODO: Verify files exist and appropriate rights are granted

  # ---------------------------------------------------------------------------
  # Back up the forward and reverse master files
  
  x=$BackupDir/dns-backup-$(date +%m%d)
  # By naming these per day with no year they neatly overwrite each other after a year.

  y=$x.$ForwardMasterFile
  if [ -f $y ]; then
    Log "Forward master already backed up for today [$y]"
  else
    Log "Backing up forward master [$y]"
    cp -a $ZonePath/$ForwardMasterFile $y
  fi

  y=$x.$ReverseMasterFile
  if [ -f $y ]; then
    Log "Reverse master already backed up for today [$y]"
  else
    Log "Backing up reverse master [$y]"
    cp -a $ZonePath/$ReverseMasterFile $y
  fi

  # ---------------------------------------------------------------------------

  DnsZoneFileContentsWithoutDynamicHosts () {
    # Pass in the contents of a DNS Zone File (forward or reverse master)
    # Filters out any line/record that ends with ;dynamic (those that came from DHCP)
    # to create the start point of an update.
    echo "$1" |
    awk '
      {
        if ($5 != ";dynamic") {
          PrintThis=1;
        } else {
          PrintThis=0;
        }
      }
      (PrintThis == 1) {print $0 }
    '
  }

  # ---------------------------------------------------------------------------

  DhcpAsDnsHostRecords () {
    # Pass in $1 "A" for A records and "PTR" for PTR records.
    # Process the DHCP static and dynamic records
    # Pass in $2 a comma-delimited list of records to ignore (presumably because they're already in the DNS zone file)
    # Logic is the same for PTR and A records. Just a different print output.
    # Sorts and remove duplicates. Filters records you don't want.
    awk -v YourNetworkName=$YourNetworkName -v RecordType=$1  -v IgnoreHosts=$2 -v NetworkInterfaces=$NetworkInterfaces '
      BEGIN {
        # Set awks field separator
        FS="[\t =,]";
      }

      {
        IpAddress=""
        Name=""
        Ttl=""
      }

      # Leases start with numbers. Do not use if column 4 is an interface
      $1 ~ /^[0-9]/ {
        if (NF > 4 || index(NetworkInterfaces, "," $4 "," ) == 0) {
          IpAddress=$3
          Name=$4
          Ttl=86400
        }
      }

      # Static assignments start with dhcp-host
      $1 == "dhcp-host" {
        IpAddress=$4
        Name=$3
        Ttl=$5
      }

      {
        if (IpAddress == "" || Name == "" || Name == "*") { next } # not a host

        split(IpAddress, IpA, ".")
        IpAddressReversed = IpA[4] "." IpA[3] "." IpA[2] "." IpA[1]

        # Ignore some hosts
        if (RecordType == "A") {
          if (index(IgnoreHosts, Name "." YourNetworkName ".," ) > 0) { next }
        }
        else if (RecordType == "PTR") {
          if (index(IgnoreHosts, IpAddressReversed ".in-addr.arpa.," ) > 0) { next }
        }

        # Remove invalid characters according to rfc952
        gsub(/([^a-zA-Z0-9-]*|^[-]*|[-]*$)/, "", Name)
        if (Name == "") { next }

        # We sort by IpAddress and then remove it using cut

        Key=((((((((IpA[0] * 256) + IpA[1]) * 256) + IpA[2]) * 256) + IpA[3]) * 256) + IpA[4])
        if (RecordType == "A") {
          print Key "\t" Name "." YourNetworkName ".\t" Ttl "\tA\t" IpAddress "\t;dynamic"
        }
        else if (RecordType == "PTR") {
          print Key "\t" IpAddressReversed ".in-addr.arpa.\t" Ttl "\tPTR\t" Name "." YourNetworkName ".\t;dynamic"
        }
      }
    ' $DhcpFiles | sort | cut -f 2- | uniq	
  }

  # ---------------------------------------------------------------------------

  HostNamesFromDnsZoneFileContent () {
    echo "$1" |
    awk '
      BEGIN {
        # Set awks field separator
        FS="\t"
      }
      {
        # Theres some non-host-record lines at the start of a zone file but conveniently
        # they all have 0 or 1 tab character in them and thus 1 or 2 "fields" according
        # to awk.
        # Then a more subtle filter. We also omit any host-records that have 3 fields
        # (which will be host name, record type, address) because they dont have a TTL
        # field. Which avoids the namespace records (there seem usually to be two,
        # one of type NS and one of type A/host).
        # We also filter out any record with more then 5 fields presuming that the 6th
        # field would be a ;dynamic comment.
        if (NF>3 && NF<6 && ($3 == "A" || $4 == "A")) print $1
      }
    ' |
    tr '\n' ','
  }


  # ---------------------------------------------------------------------------

  incrementSerial () {
    # serial number must be incremented in SOA record when DNS changes are made so that slaves will recognize a change
    ser=$(sed -e '1,/.*SOA/d' $1 | sed -e '2,$d' -e 's/;.*//' )  #isolate DNS serial from first line following SOA
    comments=$(sed -e '1,/.*SOA/d' $1 | sed -e '2,$d' | sed -n '/;/p' |sed -e 's/.*;//' )  #preserve any comments, if any exist
    bumpedserial=$(( $ser +1 ))

    sed -n '1,/.*SOA/p' $1
    echo -e "\t$bumpedserial ;$comments"
    sed -e '1,/.*SOA/d' $1 | sed -n '2,$p'
  }

  
  # ---------------------------------------------------------------------------
  # FORWARD MASTER FILE FIRST - (Logic is the same for both)
  # Print everything except for PTR and A records.
  # The only exception are "ns.domain" records.  We keep those.
  #Assumptions:
  # PTR and A records should be removed unless they contain "ns.<YourNetworkName>."
  Log "Updating forward master [$ForwardMasterFile]"
  ExistingDnsZoneFile=$ZonePath/$ForwardMasterFile

  ExistingDnsZoneFileContent=$(cat $ExistingDnsZoneFile)
  if [ "$Verbose" ]; then
    EchoBegin "ExistingDnsZoneFileContent"
    echo "$ExistingDnsZoneFileContent"
    EchoEnd "ExistingDnsZoneFileContent"
  fi

  FilteredDnsZoneFileContent=$(DnsZoneFileContentsWithoutDynamicHosts "$ExistingDnsZoneFileContent")
  if [ "$Verbose" ]; then
    EchoBegin "FilteredDnsZoneFileContent"
    echo "$FilteredDnsZoneFileContent"
    EchoEnd "FilteredDnsZoneFileContent"
  fi

  KeptHostNames=$(HostNamesFromDnsZoneFileContent "$FilteredDnsZoneFileContent")
  if [ "$Verbose" ]; then
    EchoBegin "KeptHostNames"
    echo $KeptHostNames
    EchoEnd "KeptHostNames"
  fi

  DhcpAsDnsHostRecords "A" $KeptHostNames

  #echo "$FilteredDnsContents" > $BackupDir/$ForwardMasterFile.new
  #Log "adding these DHCP leases to DNS forward master file:"
  #DhcpAsDnsHostRecords "A" $STATIC

  #STATIC=$(echo "$PARTIAL"|awk '{if(NF>3 && NF<6) print $1}'| tr '\n' ',')
  #echo "$PARTIAL"  > $BackupDir/$ForwardMasterFile.new
  #Log "adding these DHCP leases to DNS forward master file:"
  #DhcpAsDnsHostRecords "A" $STATIC
  #echo
  #DhcpAsDnsHostRecords "A" $STATIC >> $BackupDir/$ForwardMasterFile.new

  #incrementSerial $BackupDir/$ForwardMasterFile.new > $BackupDir/$ForwardMasterFile.bumped
)

# -----------------------------------------------------------------------------
# Actually do stuff!

if [ "$Poll" ]; then
  # Loop forever Update()ing whenever it seems necessary
  Log "Polling for DHCP state changes..."
  DhcpLogFile=/etc/dhcpd/dhcpd-leases.log
  while true; do    
    ChangeTime=`stat $DhcpLogFile | grep Modify`
    if [[ "$ChangeTime" != "$LastChangeTime" ]]; then
      Log "DHCP state changed"
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











##########################################################################
# REVERSE MASTER FILE - (Logic is the same for both)
# Print everything except for PTR and A records.
# The only exception are "ns.domain" records.  We keep those.
#Assumptions:
# PTR and A records should be removed unless they contain "ns.<YourNetworkName>."
Log "Regenerating reverse master file $ReverseMasterFile"
PARTIAL="$(DnsZoneFileContentsWithoutDynamicHosts $ZonePath/$ReverseMasterFile)"
STATIC=$(echo "$PARTIAL"|awk '{if(NF>3 && NF<6) print $1}'| tr '\n' ',')
Log "Reverse master file static DNS addresses:"
echo "$PARTIAL"
echo
echo "$PARTIAL" > $BackupDir/$ReverseMasterFile.new
Log "adding these DHCP leases to DNS reverse master file: "
DhcpAsDnsHostRecords "PTR" $STATIC
echo
DhcpAsDnsHostRecords "PTR" $STATIC >> $BackupDir/$ReverseMasterFile.new
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



