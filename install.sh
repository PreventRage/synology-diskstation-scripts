#!/bin/bash

ScriptDir=/var/services/homes/admin/synology-sync-dhcp-with-dns

mkdir -p -v $ScriptDir

InstallScript(){
    cp -p -v ./$1 $ScriptDir
    local File=$ScriptDir/$1
    chmod -v u=rwx,go=rx $File
    chown -v root:root $File
}

InstallFile(){
    cp -p -v ./$1 $ScriptDir
    local File=$ScriptDir/$1
    chmod -v u=rw,go=r $File
    chown -v root:root $File
}

InstallScript diskstation_dns_modify.sh
InstallScript poll-dhcp-changes.sh
InstallFile settings

