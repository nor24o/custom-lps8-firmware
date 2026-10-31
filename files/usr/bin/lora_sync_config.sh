#!/bin/sh
# /usr/bin/lora_sync_config.sh
# Synchronizes UCI /etc/config/lora to /etc/lora/config.json

SERVER=$(uci -q get lora.general.server_address || echo "192.168.1.8")
PORT_UP=$(uci -q get lora.general.serv_port_up || echo "5555")
PORT_DOWN=$(uci -q get lora.general.serv_port_down || echo "5556")
STATUS_PORT=$(uci -q get lora.general.status_port || echo "5557")
HB_INT=$(uci -q get lora.general.stat_interval || echo "10")
SPI_PATH=$(uci -q get lora.general.spi_path || echo "/dev/spidev1.0")
RESET_GPIO=$(uci -q get lora.general.reset_gpio || echo "23")
PA_GPIO=$(uci -q get lora.general.pa_gpio || echo "dragino2:red:wan")
TXPOW=$(uci -q get lora.general.tx_power || echo "14")
SYNCWORD=$(uci -q get lora.general.syncword || echo "0x12")

if [ -f /etc/lora/config.json ]; then
    lua -e '
        local jsonc = require "luci.jsonc"
        local f = io.open("/etc/lora/config.json", "r")
        if f then
            local str = f:read("*a")
            f:close()
            local cfg = jsonc.parse(str) or {}
            cfg["target_ip"] = "'"$SERVER"'"
            cfg["port_up"] = tonumber("'"$PORT_UP"'") or 5555
            cfg["port_down"] = tonumber("'"$PORT_DOWN"'") or 5556
            cfg["status_port"] = tonumber("'"$STATUS_PORT"'") or 5557
            cfg["heartbeat_interval_s"] = tonumber("'"$HB_INT"'") or 10
            cfg["spi_path"] = "'"$SPI_PATH"'"
            cfg["reset_gpio"] = "'"$RESET_GPIO"'"
            cfg["pa_gpio"] = "'"$PA_GPIO"'"
            cfg["tx_default_power"] = tonumber("'"$TXPOW"'") or 14
            cfg["sync_word"] = ("'"$SYNCWORD"'" == "0x34" or "'"$SYNCWORD"'" == "public") and "public" or "private"

            local out = io.open("/etc/lora/config.json", "w")
            if out then
                out:write(jsonc.stringify(cfg, true))
                out:close()
            end
        end
    '
fi

if [ -x /etc/init.d/lora_gateway ]; then
    /etc/init.d/lora_gateway restart
fi
