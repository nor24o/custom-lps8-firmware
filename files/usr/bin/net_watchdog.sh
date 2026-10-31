#!/bin/sh
GATEWAY=$(ip route | grep default | awk '{print $3}')

if [ -z "$GATEWAY" ]; then
    logger -t Watchdog "No default gateway found. Restarting network."
    /etc/init.d/network restart
    exit 1
fi

ping -c 3 -W 2 $GATEWAY > /dev/null

if [ $? -ne 0 ]; then
    logger -t Watchdog "Local network ping to $GATEWAY failed. Restarting interface."
    ifup lan
else
    exit 0
fi
