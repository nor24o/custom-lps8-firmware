#!/usr/bin/env bash
set -e
IP="192.168.1.15"
PASS="root"
TARGET_DIR="/home/hor/2026-gateway/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/targets/sx1276_lg01_lg02"

echo "=== Deploying to $IP ==="
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$TARGET_DIR/files/usr/bin/lg02_pkt_fwd" "root@$IP:/tmp/lg02_pkt_fwd"
sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "root@$IP" "mv -f /tmp/lg02_pkt_fwd /usr/bin/lg02_pkt_fwd && chmod +x /usr/bin/lg02_pkt_fwd"
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$TARGET_DIR/files/usr/lib/lua/luci/controller/lora.lua" "root@$IP:/usr/lib/lua/luci/controller/lora.lua"
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$TARGET_DIR/files/usr/lib/lua/luci/view/lora/config.htm" "root@$IP:/usr/lib/lua/luci/view/lora/config.htm"
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$TARGET_DIR/files/usr/lib/lua/luci/view/lora/status.htm" "root@$IP:/usr/lib/lua/luci/view/lora/status.htm"

echo "=== Restarting services on $IP ==="
sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "root@$IP" "
    rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache*
    killall -9 lg02_pkt_fwd 2>/dev/null || true
    killall -9 uhttpd 2>/dev/null || true
    /etc/init.d/uhttpd start
"

echo "=== Verifying lg02_pkt_fwd status ==="
sleep 6
python3 -c "
import requests, json
s = requests.Session()
s.post('http://$IP/cgi-bin/luci/', data={'luci_username': 'root', 'luci_password': 'root'})
r = s.get('http://$IP/cgi-bin/luci/admin/lora/api_status')
print('Status API Response:')
print(json.dumps(r.json(), indent=2))
"
