#!/bin/sh
# /usr/bin/lora_sync_config.sh
# Synchronizes UCI /etc/config/lora to /etc/lora/config.json & /etc/lora/gateway.json

GWID=$(uci -q get lora.general.gateway_id || echo "a84041ffff16c21c")
SERVER=$(uci -q get lora.general.server_address || echo "eu1.cloud.thethings.network")
PORT_UP=$(uci -q get lora.general.serv_port_up || echo "1700")
PORT_DOWN=$(uci -q get lora.general.serv_port_down || echo "1700")
REGION=$(uci -q get lora.general.region || echo "EU868")
TXPOW=$(uci -q get lora.general.tx_power || echo "26")
SYNCWORD=$(uci -q get lora.general.syncword || echo "0x34")
INTERFACE=$(uci -q get lora.general.interface || echo "spi")
RESET_GPIO=$(uci -q get lora.general.reset_gpio || echo "23")

logger -t lora "Syncing UCI configuration to /etc/lora/ JSON configurations..."

# Update SX1302 /etc/lora/config.json
if [ -f /etc/lora/config.json ]; then
    lua -e '
        local jsonc = require "luci.jsonc"
        local f = io.open("/etc/lora/config.json", "r")
        if f then
            local str = f:read("*a")
            f:close()
            local cfg = jsonc.parse(str) or {}
            cfg["target_ip"] = "'"$SERVER"'"
            cfg["port_up"] = tonumber("'"$PORT_UP"'") or 1700
            cfg["port_down"] = tonumber("'"$PORT_DOWN"'") or 1700
            cfg["reset_gpio"] = "'"$RESET_GPIO"'"
            cfg["sync_word"] = ("'"$SYNCWORD"'" == "0x34") and "public" or "private"
            
            local out = io.open("/etc/lora/config.json", "w")
            if out then
                out:write(jsonc.stringify(cfg, true))
                out:close()
            end
        end
    '
fi

# Update LG01/LG02 /etc/lora/gateway.json
if [ -f /etc/lora/gateway.json ]; then
    lua -e '
        local jsonc = require "luci.jsonc"
        local f = io.open("/etc/lora/gateway.json", "r")
        if f then
            local str = f:read("*a")
            f:close()
            local cfg = jsonc.parse(str) or {}
            cfg["GWID"] = "'"$GWID"'"
            cfg["server_address"] = "'"$SERVER"'"
            cfg["upp"] = "'"$PORT_UP"'"
            cfg["dpp"] = "'"$PORT_DOWN"'"
            cfg["TXPOWER"] = "'"$TXPOW"'"
            cfg["RXSYNC"] = ("'"$SYNCWORD"'" == "0x34") and "52" or "18"
            
            local out = io.open("/etc/lora/gateway.json", "w")
            if out then
                out:write(jsonc.stringify(cfg, true))
                out:close()
            end
        end
    '
fi

# Restart daemon
if [ -x /etc/init.d/lora_gateway ]; then
    /etc/init.d/lora_gateway restart
fi
