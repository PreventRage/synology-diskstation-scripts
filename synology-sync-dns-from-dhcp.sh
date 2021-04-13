#!/bin/ash

ScriptPath=$0
ScriptDir=$(dirname $ScriptPath)

# -----------------------------------------------------------------------------

LogEmptyLine=

Log(){
  if [ "$1" = "" ]; then
    if [ "$LogEmptyLine" ]; then
      echo
      LogEmptyLine=
    fi
  else
    echo $1
    LogEmptyLine=1
  fi
}

LogT(){
    d=$(date "+%F %T")
    Log "$* ($d)"
}

Fail(){
  LogT "Error:" "$@"
  exit 1
}

LogFile(){
  x=${!1}
  if [ "$x" ]; then
    # $1 was indeed the name of a variable
    Label="$1"
    Path=$x
    if [ ! -f "$Path" ]; then
      Log "Error: $Label [$Path] does not exist"
      return 1
    fi
  else
    # $1 is presumably the actual path to the file
    Path=$1
    if [ ! -f "$Path" ]; then
      Log "Error: [$Path] does not exist"
      return 1
    fi
    Label=$(basename "$Path")
  fi

  Log
  Log "BEGIN $Label"
  Log "[$Path]"
  Log "--------------------------------------------------------------------------------"
  cat "$Path"
  Log "--------------------------------------------------------------------------------"
  Log "END $Label"
  Log 
}

LogFileIfVerbose(){
  if [ "$Verbose" ]; then
    LogFile "$@"
  fi
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

Update()(
  # That "("" makes this a "subshell" function which can have its own inner functions


  LogT "Updating DNS to reflect current DHCP state"

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
    LogT "Backing up forward master [$y]"
    cp -a $ZonePath/$ForwardMasterFile $y
  fi

  y=$x.$ReverseMasterFile
  if [ -f $y ]; then
    Log "Reverse master already backed up for today [$y]"
  else
    LogT "Backing up reverse master [$y]"
    cp -a $ZonePath/$ReverseMasterFile $y
  fi

  # ---------------------------------------------------------------------------

  DnsRecordsFromZoneFile () {
    # Pass in $1 = path to a DNS Zone File (forward or reverse master)
    # Filters out any line/record that ends with ;dynamic (those that came from DHCP)
    # to create the start point of an update.
    awk '
      BEGIN {
        #FS="\t" # I think Synology DNS files use Tabs as separators exclusively
      }
      {
        if (substr($0, 1, 1) == "$") next

        if ($5 != ";dynamic") {
          PrintThis=1;
        } else {
          PrintThis=0;
        }
      }
      (PrintThis == 1) {print $0 }
    ' "$1"
  }
  # ---------------------------------------------------------------------------

  DnsZoneFileWithoutDynamicHosts () {
    # See https://en.wikipedia.org/wiki/Zone_file
    # Pass in $1 = path to a DNS Zone File (forward or reverse master)
    # Filters out any line/record that ends with ;dynamic (those that came from DHCP)
    # to create the start point of an update.
    awk -D '
      function Log(msg) {
        printf("%s:%d: %s\n", FILENAME, FNR, msg) > "/dev/stdout"
      }

      function Error(msg) {
        printf("%s:%d: Error: %s\n", FILENAME, FNR, msg) > "/dev/stderr"
        _Error_Exit = 1
        exit 1
      }

      function Assert(condition, msg)
      {
        if (!condition) {
          Error("Assertion Failed: " msg)
        }
      }

      function InitRecord(r,
        lines) {
        delete r # empties the array
        lines[1] = "" # now lines is an array
        Assert()
        delete lines # now lines is an _empty_ array
        Log("Before assign")
        r["Lines"] = lines
        Log("After assign")
        r["State"] = 1 # Initialized
      }

      function IsRecordInitialized(r) {
        return r["State"] == 1
      }

      function IsRecordInProgress(r) {
        return r["State"] == 2
      }
      
      function IsRecordComplete(r) {
        return r["State"] == 3
      }

      function AddLineToRecord(r, line,
        lines) {
        lines = r["Lines"]
#        count = length(lines)
        lines[count + 1] = line
        r["State"] = 3
        Assert(IsRecordComplete(r))
      }

      function ProcessRecord(r,
        lines, line) {
        lines = r["Lines"]
        for (line in lines) {
          print line
        }
      }

# {
#     if (p1++ > 3)
#         return

#     a[p1] = p1

#     some_func(p1)

#     printf("At level %d, index %d %s found in a\n",
#          p1, (p1 - 1), (p1 - 1) in a ? "is" : "is not")
#     printf("At level %d, index %d %s found in a\n",
#          p1, p1, p1 in a ? "is" : "is not")
#     print ""
# }
      BEGIN {
        #FS="\t" # Set field separator
        InitRecord(Record)
        Assert(IsRecordInitialized(Record))
        InMultiLineParentheses = 0
      }

      {
        AddLineToRecord(Record, $0)
        if (IsRecordComplete(Record)) {
          ProcessRecord(Record)
          InitRecord(Record)
        }
        next

        Line=$0
        Comment=""

        if (match(Line, /^(.*);(.*)$/, Matches)) {
          Line=Matches[1]
          Comment=Matches[2]
        } 


        if (InMultiLineParentheses) {
          print "[Continued]" $0
          if ($0 ~ /\)$/) { # line ends with )
            InMultiLineParentheses=0
          }
          next
        }
        if ($1 ~ /^\$/) {
          print "[Directive]" $0
          next
        }
        if (!InMultiLineParentheses) {
          if ($0 ~ /^.*\($/) { # line ends with (
            InMultiLineParentheses=1
            print "ML!>" $0
            next
          }
        }
        print "[" $1 "][" $2 "][" $3 "][" $4 "][" $5 "][" $6 "]"
        next
        if ($5 != ";dynamic") {
          PrintThis=1;
        } else {
          PrintThis=0;
        }
      }

      END {
        if (_Error_Exit) {
          exit 1
        }
        if (IsRecordIncomplete(Record)) {
        }
      }

      (PrintThis == 1) {print $0 }
    ' "$1"
  }

  # ---------------------------------------------------------------------------

  HostNamesFromDnsZoneFile () {
  # Pass in $1 = path to a DNS Zone File (forward or reverse master)
  # Reduces to a list of host names.
    awk '
      BEGIN {
        FS="\t" # Set awks field separator
        InMultiLineParentheses=0
      }

      {
        if ($0 ~ /^.*\($/) {
          print $0
        }
        next

        # Theres some non-host-record lines at the start of a zone file but conveniently
                # they all have 1 or 2 "fields" according
        # to awk.
        # Then a more subtle filter. We also omit any host-records that have 3 fields
        # (which will be host name, record type, address) because they dont have a TTL
        # field. Which avoids the namespace records (there seem usually to be two,
        # one of type NS and one of type A/host).
        # We also filter out any record with more then 5 fields presuming that the 6th
        # field would be a ;dynamic comment.
        if (NF>3 && NF<6 && ($3 == "A" || $4 == "A")) print $1
      }
    ' "$1"
  }

  # ---------------------------------------------------------------------------

  DnsHostRecordsFromDhcp () {
    # $1 is "A" for A records and "PTR" for PTR records.
    # [Optional] $2 is a file (path) containing a sorted list of host names (forward or reverse) that we'll skip (not emit) because you've got them handled some other way.
    # Process the DHCP static and dynamic records.
    # Sorts and remove duplicates. Filters out records you don't want.

    awk -v YourNetworkName=$YourNetworkName -v RecordType=$1 -v NetworkInterfaces=$NetworkInterfaces '
      BEGIN {
        # Set field separator
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
    ' $DhcpFiles |
    if [ -f "$2" ]; then
      grep -f "$2" -F -v # only keep lines that don't match any lines in the file $2
    else
      cat
    fi |
    sort |
    cut -f 2- |
    uniq
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
  # Assumptions:
  # PTR and A records should be removed unless they contain "ns.<YourNetworkName>."
  LogT "Updating forward master [$ForwardMasterFile]"
  ExistingDnsZoneFile=$ZonePath/$ForwardMasterFile
  LogFileIfVerbose "ExistingDnsZoneFile"

  FilteredDnsZoneFile=$TempDir/$ForwardMasterFile-filtered
  DnsZoneFileWithoutDynamicHosts "$ExistingDnsZoneFile" > "$FilteredDnsZoneFile"
  # echo "$FilteredDnsContents" > $BackupDir/$ForwardMasterFile.new
  LogFileIfVerbose "FilteredDnsZoneFile"

  KeptHostsFile=$TempDir/$ForwardMasterFile-kept-hosts
  HostNamesFromDnsZoneFile "$FilteredDnsZoneFile" | sort | uniq > "$KeptHostsFile"
  LogFileIfVerbose "KeptHostsFile"

  DnsHostRecordsFromDhcp "A" "$KeptHostsFile"

  #echo "$FilteredDnsContents" > $BackupDir/$ForwardMasterFile.new
  #LogT "adding these DHCP leases to DNS forward master file:"

  #STATIC=$(echo "$PARTIAL"|awk '{if(NF>3 && NF<6) print $1}'| tr '\n' ',')
  #echo "$PARTIAL"  > $BackupDir/$ForwardMasterFile.new
  #LogT "adding these DHCP leases to DNS forward master file:"
  #DnsHostRecordsFromDhcp "A" $STATIC
  #echo
  #DnsHostRecordsFromDhcp "A" $STATIC >> $BackupDir/$ForwardMasterFile.new

  #incrementSerial $BackupDir/$ForwardMasterFile.new > $BackupDir/$ForwardMasterFile.bumped




)

# -----------------------------------------------------------------------------
# Actually do stuff!

if [ "$Poll" ]; then
  # Loop forever Update()ing whenever it seems necessary
  LogT "Polling for DHCP state changes..."
  DhcpLogFile=/etc/dhcpd/dhcpd-leases.log
  while true; do    
    ChangeTime=`stat $DhcpLogFile | grep Modify`
    if [[ "$ChangeTime" != "$LastChangeTime" ]]; then
      LogT "DHCP state changed"
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
LogT "Regenerating reverse master file $ReverseMasterFile"
PARTIAL="$(DnsZoneFileContentsWithoutDynamicHosts $ZonePath/$ReverseMasterFile)"
STATIC=$(echo "$PARTIAL"|awk '{if(NF>3 && NF<6) print $1}'| tr '\n' ',')
LogT "Reverse master file static DNS addresses:"
echo "$PARTIAL"
echo
echo "$PARTIAL" > $BackupDir/$ReverseMasterFile.new
LogT "adding these DHCP leases to DNS reverse master file: "
DnsHostRecordsFromDhcp "PTR" $STATIC
echo
DnsHostRecordsFromDhcp "PTR" $STATIC >> $BackupDir/$ReverseMasterFile.new
incrementSerial $BackupDir/$ReverseMasterFile.new > $BackupDir/$ReverseMasterFile.bumped


##########################################################################
# Ensure the owner/group and modes are set at default
# then overwrite the original files
LogT "Overwriting with updated files: $ForwardMasterFile $ReverseMasterFile"
if ! chown nobody:nobody $BackupDir/$ForwardMasterFile.bumped $BackupDir/$ReverseMasterFile.bumped ; then
  LogT "Error:  Cannot change file ownership"
  LogT ""
  LogT "Try running this script as root for correct permissions"
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

LogT "$0 complete."
exit 0



