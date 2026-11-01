#!/bin/sh
# /usr/bin/net_watchdog.sh
# Checks network connectivity and ensures lora_keepalive.sh is active

# 1. Ensure LoRa keepalive supervisor is running
if ! pgrep -f lora_keepalive.sh >/dev/null 2>&1; then
    if [ -x /usr/bin/lora_keepalive.sh ]; then
        logger -t Watchdog "Starting lora_keepalive.sh supervisor"
        /usr/bin/lora_keepalive.sh >/dev/null 2>&1 &
    fi
fi

# 2. Check upstream target or default gateway connectivity
TARGET_IP=$(grep -o '"target_ip"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/lora/config.json 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/')
GATEWAY=$(ip route 2>/dev/null | grep default | awk '{print $3}' | head -n 1)

if [ -z "$GATEWAY" ] && [ -z "$TARGET_IP" ]; then
    logger -t Watchdog "No default route found. Renewing LAN interface."
    ifup lan 2>/dev/null || /etc/init.d/network restart 2>/dev/null
    exit 1
fi

CHECK_HOST="${GATEWAY:-$TARGET_IP}"
if [ -n "$CHECK_HOST" ]; then
    if ! ping -c 2 -W 2 "$CHECK_HOST" >/dev/null 2>&1; then
        logger -t Watchdog "Ping to $CHECK_HOST failed. Reconnecting LAN interface."
        ifup lan 2>/dev/null
    fi
fi
exit 0
