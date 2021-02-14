#!/bin/sh

# control start
# control stop
# control status

ScriptDir=$(dirname $0)
Name=synology-sync-dns-from-dhcp

LOG_CONTEXT="-" #override to add extra stuff to log messages
date_echo(){
    datestamp=$(date +%F_%T)
    echo "${datestamp} ${LOG_CONTEXT} $*"
}

if $(ps x > /dev/null 2>&1 ); then
  #apparently DSM 6.0 needs the x option for ps.  DSM 5.x does not have this option, but the default ps is good enough without options.
  PS="ps x"
else
  PS="ps"
fi

if [ "$1" = "start" ]; then
#nohup ./poll-dhcp-changes.sh >> /var/services/homes/admin/logs/dhcp-dns.log 2>&1 &
#nohup does not work on synology.
  IsRunning=`$PS | grep $Name | grep -v grep |wc -l`
  if [ $IsRunning -gt 0 ]; then
    date_echo "$Name is already running."
  else
    date_echo "starting $Name"
    #LogDir=$ScriptDir/logs
    #mkdir -p $LogDir
    #$ScriptDir/$Name.sh >> $LogDir/dhcp-dns.log 2>&1 &
    $ScriptDir/$Name.sh &
  fi

elif [ "$1" = "stop" ]; then
  ProcessId=`$PS | grep $Name | grep -v grep | head -1 |awk -F' ' '{print $1}'`
  #if for some reason there are more than 1 $Name processes running, just kill the first one found.
  if [ $ProcessId -gt 1 ]; then
    date_echo "Killing Process#$ProcessId"
    kill $ProcessId
  fi

elif [ "$1" = "status" ]; then
  IsRunning=`$PS | grep $Name | grep -v grep | wc -l`
  if [ $IsRunning -gt 0 ]; then
    date_echo "$Name is running:"
    $PS | grep $Name | grep -v grep
  else
    date_echo "$Name is stopped."
  fi
fi
