#!/bin/ksh
Offset=`ntpq  -p |grep  -e '*'|awk  '{print $9}'`
Offset=${Offset%.*}
Script_Path=/unixadmin/controlfile
if [ "$Offset" -lt "-60000" ] || [ "$Offset" -gt 60000 ] || [ -z  "$Offset" ]
then
        if [ ! -f $Script_Path/ntp_offset_critical ]
        then
        /opt/OV/bin/opcmsg a=Offset o=Offset severity=Critical msg_text="`hostname` sunucusunda NTP Offset Problem !!! " node=`hostname`
        touch  $Script_Path/ntp_offset_critical
        fi
else
        if [ -f $Script_Path/ntp_offset_critical ]
        then
        /opt/OV/bin/opcmsg a=Offset o=Offset severity=Normal msg_text="`hostname` sunucusunda NTP Offset Fixed. !!! " node=`hostname`
        rm  -rf  $Script_Path/ntp_offset_critical
        fi
fi
