#!/bin/bash

Name=synology-sync-dns-from-dhcp
ScriptDir="/var/services/homes/admin/$Name"
StartDir="/usr/local/etc/rc.d/"

mkdir -p -v $ScriptDir

Install(){
    cp -p -v ./$1 $2
    local File=$2/$1
    chmod -v u=rw$3,go=r$3 $File
    chown -v root:root $File
}

Install $Name.sh $ScriptDir x
Install control.sh $ScriptDir x
Install settings $ScriptDir
Install $Name.control.sh $StartDir x

