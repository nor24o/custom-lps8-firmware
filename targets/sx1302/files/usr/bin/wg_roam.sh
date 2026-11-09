#!/bin/sh
# Keeps the tunnel to the Bobcat up wherever this gateway is: while there is no
# recent handshake it alternates between the Bobcat's home-network address and
# its internet address. Both are set on the WireGuard VPN page.
IF=wg0
PEER=$(uci -q get network.bobcat.public_key)
LAN=$(uci -q get network.bobcat.lan_endpoint)
WAN=$(uci -q get network.bobcat.wan_endpoint)
now=$(date +%s)
last=$(wg show $IF latest-handshakes 2>/dev/null | awk '{print $2}')
[ -n "$last" ] && [ "$last" -gt 0 ] && [ $((now - last)) -lt 180 ] && exit 0
cur=$(wg show $IF endpoints 2>/dev/null | awk '{print $2}')
if [ "$cur" = "$LAN" ] && [ -n "$WAN" ]; then next=$WAN; else next=${LAN:-$WAN}; fi
[ -n "$next" ] && wg set $IF peer "$PEER" endpoint "$next"
