#!/usr/bin/env bash
set -e

GATEWAY_IP="192.168.1.17"
PASS="root"
TARGET_DIR="targets/sx1302/files"

echo "=== Deploying NetID-Purged Firmware Components to Dragino LPS8 (${GATEWAY_IP}) ==="

export SSHPASS="$PASS"
SSH_CMD="sshpass -e ssh -o StrictHostKeyChecking=no root@${GATEWAY_IP}"
SCP_CMD="sshpass -e scp -o StrictHostKeyChecking=no"

echo "1. Uploading /etc/lora/decoders.json..."
$SCP_CMD ${TARGET_DIR}/etc/lora/decoders.json root@${GATEWAY_IP}:/etc/lora/decoders.json

echo "2. Uploading LuCI Controller & Views..."
$SCP_CMD ${TARGET_DIR}/usr/lib/lua/luci/controller/lora.lua root@${GATEWAY_IP}:/usr/lib/lua/luci/controller/lora.lua
$SCP_CMD ${TARGET_DIR}/usr/lib/lua/luci/view/lora/decoder.htm root@${GATEWAY_IP}:/usr/lib/lua/luci/view/lora/decoder.htm
$SCP_CMD ${TARGET_DIR}/usr/lib/lua/luci/view/lora/status.htm root@${GATEWAY_IP}:/usr/lib/lua/luci/view/lora/status.htm
$SCP_CMD ${TARGET_DIR}/usr/lib/lua/luci/view/lora/nodes.htm root@${GATEWAY_IP}:/usr/lib/lua/luci/view/lora/nodes.htm

echo "3. Uploading lora_decoder.js..."
$SCP_CMD ${TARGET_DIR}/www/luci-static/resources/lora_decoder.js root@${GATEWAY_IP}:/www/luci-static/resources/lora_decoder.js

echo "4. Uploading backend engines (linking engine & mqtt bridge)..."
$SCP_CMD ${TARGET_DIR}/usr/bin/lora_linking_engine.lua root@${GATEWAY_IP}:/usr/bin/lora_linking_engine.lua
$SCP_CMD ${TARGET_DIR}/usr/bin/lora_mqtt_bridge.lua root@${GATEWAY_IP}:/usr/bin/lora_mqtt_bridge.lua

echo "5. Restarting services and clearing LuCI cache on gateway..."
$SSH_CMD << 'EOF'
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache*
/etc/init.d/uhttpd restart
killall -9 lora_linking_engine.lua lora_mqtt_bridge.lua 2>/dev/null || true
echo "Cleared cache & restarted uhttpd."
EOF

echo "6. Testing live Lua on the gateway..."
$SSH_CMD << 'EOF'
lua -e '
local f = io.open("/etc/lora/decoders.json", "r")
local c = f:read("*a")
f:close()
local jsonc = require "luci.jsonc"
local d = jsonc.parse(c)
print("Decoders JSON loaded on gateway! Schemes count: " .. #d.schemes)
for idx, s in ipairs(d.schemes) do
    print(string.format("  [%d] %s (%s)", idx, s.name, s.type))
end
'
EOF

echo "=== Deployment & Verification Complete! ==="
