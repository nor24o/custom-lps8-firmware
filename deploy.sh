#!/usr/bin/env bash
set -e

TARGET_IP="${1:-192.168.1.17}"
TARGET_USER="${2:-root}"
TARGET_PASS="${3:-root}"

echo "=================================================================="
echo " Deploying LoRa GUI, Pipeline, Decoder & HA to $TARGET_USER@$TARGET_IP"
echo "=================================================================="

# Check sshpass
if command -v sshpass >/dev/null 2>&1; then
    SSH_CMD="sshpass -p $TARGET_PASS ssh -o StrictHostKeyChecking=no"
    SCP_CMD="sshpass -p $TARGET_PASS scp -o StrictHostKeyChecking=no -r"
else
    SSH_CMD="ssh -o StrictHostKeyChecking=no"
    SCP_CMD="scp -o StrictHostKeyChecking=no -r"
fi

echo "[1/4] Uploading files/ overlay to gateway root..."
$SCP_CMD files/* "$TARGET_USER@$TARGET_IP:/"

echo "[2/4] Setting execution permissions..."
$SSH_CMD "$TARGET_USER@$TARGET_IP" "chmod +x /usr/bin/lora_* /etc/init.d/lora_gateway 2>/dev/null || true"

echo "[3/4] Purging LuCI web caches..."
$SSH_CMD "$TARGET_USER@$TARGET_IP" "rm -rf /tmp/luci-indexcache /tmp/luci-modulecache"

echo "[4/4] Restarting LoRa linking & HA bridge engine..."
$SSH_CMD "$TARGET_USER@$TARGET_IP" "/usr/bin/lora_keepalive.sh restart >/dev/null 2>&1 || true"

echo "=================================================================="
echo " Deployment successful! Open http://$TARGET_IP/cgi-bin/luci/admin/lora/decoder"
echo "=================================================================="
