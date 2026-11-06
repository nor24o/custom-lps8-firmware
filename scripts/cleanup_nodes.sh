#!/usr/bin/env bash
set -e
GATEWAY_IP="192.168.1.17"
PASS="root"

echo "=== Cleaning up dummy seed nodes on Dragino LPS8 ==="
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@${GATEWAY_IP} "sqlite3 /etc/lora/nodes.db \"UPDATE node_settings SET ha_enabled = 0, is_configured = 0, group_name = 'Unassigned' WHERE node_id IN ('AA0B', 'AA0C'); SELECT node_id, is_configured, group_name, ha_enabled FROM node_settings;\""
