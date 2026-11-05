#!/usr/bin/env lua
-- /usr/bin/lora_mqtt_bridge.lua
-- Home Assistant MQTT Auto-Discovery & Bidirectional Downlink Bridge
-- Compatible with Dragino LPS8 (SX1302) & LG01/LG02 (SX1276)
--
-- Features:
--   1. Gateway Self-Discovery: Exposes Dragino Gateway as a primary Device in Home Assistant
--      (Concentrator Temp, RX Uplinks, TX Downlinks, CRC Errors, Active Nodes, Radio State, Uptime, Restart Button).
--   2. Gateway Topology: Links all discovered LoRa end devices to the Gateway via `via_device`.
--   3. Auto-publishes Home Assistant MQTT Discovery for all registered nodes.
--   4. Groups entities under a single unified Device Card with Area/Group in HA.
--   5. Periodically publishes gateway telemetry to `lora/gateway/state`.
--   6. Subscribes to `lora/+/set` for bidirectional downlinks from Home Assistant.
--   7. Subscribes to `lora/gateway/restart` to trigger concentrator restart from HA.
--   8. Performs Listen-Before-Send (LBT) and dispatches LoRa downlinks to port 5556.

local sqlite3 = require "lsqlite3"
local nixio   = require "nixio"
local jsonc   = require "luci.jsonc"

local CONFIG_PATH   = "/etc/lora/config.json"
local DB_NODES_PATH = "/etc/lora/nodes.db"
local PACKETS_JSON  = "/tmp/lora_packets.json"
local PORT_DOWN     = 5556
local STATUS_PORT   = 5557

local function read_config()
    local f = io.open(CONFIG_PATH, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    return jsonc.parse(content) or {}
end

local g_cfg = read_config()
local mqtt_cfg = g_cfg.mqtt or {}

local MQTT_ENABLED = (mqtt_cfg.enabled ~= false)
local MQTT_HOST    = mqtt_cfg.server or "127.0.0.1"
local MQTT_PORT    = tonumber(mqtt_cfg.port) or 1883
local MQTT_USER    = mqtt_cfg.user or ""
local MQTT_PASS    = mqtt_cfg.password or ""
local HA_PREFIX    = mqtt_cfg.discovery_prefix or "homeassistant"
local TOPIC_ROOT   = mqtt_cfg.state_prefix or "lora"

local function shellquote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function build_auth_flags()
    local flags = ""
    if MQTT_USER ~= "" then
        flags = flags .. " -u " .. shellquote(MQTT_USER)
    end
    if MQTT_PASS ~= "" then
        flags = flags .. " -P " .. shellquote(MQTT_PASS)
    end
    return flags
end

local AUTH_FLAGS = build_auth_flags()

local function mqtt_publish(topic, payload, retain)
    if not MQTT_ENABLED then return end
    local cmd = string.format(
        "mosquitto_pub -h %s -p %d %s %s -t %s -m %s 2>/dev/null",
        shellquote(MQTT_HOST),
        MQTT_PORT,
        AUTH_FLAGS,
        retain and "-r" or "",
        shellquote(topic),
        shellquote(payload)
    )
    os.execute(cmd)
end

-- Query live concentrator telemetry from TCP status port 5557 (pure Lua non-blocking socket)
local function query_gateway_status()
    local s = nixio.socket("inet", "stream")
    if not s then return nil end
    s:setopt("socket", "rcvtimeo", 2)
    s:setopt("socket", "sndtimeo", 2)
    local ok = s:connect("127.0.0.1", STATUS_PORT)
    if not ok then
        s:close()
        return nil
    end
    local chunks = {}
    while true do
        local chunk = s:recv(1024)
        if not chunk or #chunk == 0 then break end
        table.insert(chunks, chunk)
    end
    s:close()
    local raw = table.concat(chunks)
    return raw and jsonc.parse(raw)
end

-- Query system network IP (for configuration_url link in Home Assistant)
local function get_gateway_ip()
    local ubus_ok, ubus = pcall(require, "ubus")
    if ubus_ok and ubus then
        local conn = ubus.connect()
        if conn then
            local status = conn:call("network.interface.lan", "status", {})
            if status and status["ipv4-address"] and status["ipv4-address"][1] then
                return status["ipv4-address"][1].address
            end
        end
    end
    local p = io.popen("ip -4 addr show eth0 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2")
    if p then
        local ip = p:read("*l")
        p:close()
        if ip and ip ~= "" then return ip end
    end
    return "127.0.0.1"
end

-- Retrieve hardware details for Gateway Device Discovery
local function get_gateway_info()
    local stat = query_gateway_status() or {}
    local eui = stat.eui
    if not eui or eui == "" then
        local f = io.open("/sys/class/net/eth0/address", "r")
        if f then
            local mac = f:read("*l") or ""
            f:close()
            eui = mac:gsub(":", "")
        end
    end
    eui = (eui and eui ~= "") and eui:lower() or "dragino01"

    local ip = get_gateway_ip()
    local model = "Dragino LPS8 (SX1302)"
    if nixio.fs.access("/usr/bin/raw_lora_app") then
        model = "Dragino LPS8 (SX1302 8-CH)"
    elseif nixio.fs.access("/usr/bin/lg02_pkt_fwd") or nixio.fs.access("/usr/bin/sx1276_app") then
        model = "Dragino LG01/LG02 (SX1276)"
    end

    return {
        eui = eui,
        ip = ip,
        model = model,
        stat = stat
    }
end

local g_gw_info = get_gateway_info()

-- Count registered & categorized nodes in SQLite
local function count_active_nodes()
    local count = 0
    local db = sqlite3.open(DB_NODES_PATH)
    if db then
        db:busy_timeout(5000)
        local stmt = db:prepare("SELECT count(*) FROM node_settings WHERE is_configured = 1 AND group_name != 'Unassigned' AND group_name != 'Uncategorized';")
        if stmt then
            if stmt:step() == sqlite3.ROW then
                count = stmt:get_value(0) or 0
            end
            stmt:finalize()
        end
        db:close()
    end
    return count
end

-- ==============================================================================
-- Home Assistant MQTT Discovery: Gateway Self-Discovery
-- ==============================================================================
local function publish_gateway_discovery()
    if not MQTT_ENABLED then return end
    local gw = g_gw_info
    local gw_id = gw.eui
    local gw_device_id = "dragino_gateway_" .. gw_id

    local gw_device = {
        identifiers = { gw_device_id },
        name = "Dragino LoRa Gateway",
        model = gw.model,
        manufacturer = "Dragino",
        sw_version = "v1.1.0",
        configuration_url = "http://" .. gw.ip .. "/"
    }

    local state_topic = TOPIC_ROOT .. "/gateway/state"

    -- 1. Concentrator Chip Temperature Sensor
    local temp_config = {
        name = "LoRa Concentrator Temperature",
        unique_id = "dragino_gw_" .. gw_id .. "_temp",
        state_topic = state_topic,
        value_template = "{{ value_json.temp_c | default(none) }}",
        unit_of_measurement = "°C",
        device_class = "temperature",
        state_class = "measurement",
        device = gw_device
    }
    mqtt_publish(string.format("%s/sensor/dragino_gw_%s/temp/config", HA_PREFIX, gw_id), jsonc.stringify(temp_config), true)

    -- 2. Uplink Packets Received (Counter)
    local rx_config = {
        name = "LoRa Uplinks Received",
        unique_id = "dragino_gw_" .. gw_id .. "_rx",
        state_topic = state_topic,
        value_template = "{{ value_json.rx | default(0) }}",
        state_class = "total_increasing",
        entity_category = "diagnostic",
        icon = "mdi:radio-tower",
        device = gw_device
    }
    mqtt_publish(string.format("%s/sensor/dragino_gw_%s/rx/config", HA_PREFIX, gw_id), jsonc.stringify(rx_config), true)

    -- 3. Downlink Packets Transmitted (Counter)
    local tx_config = {
        name = "LoRa Downlinks Sent",
        unique_id = "dragino_gw_" .. gw_id .. "_tx",
        state_topic = state_topic,
        value_template = "{{ value_json.tx | default(0) }}",
        state_class = "total_increasing",
        entity_category = "diagnostic",
        icon = "mdi:transmit-tower",
        device = gw_device
    }
    mqtt_publish(string.format("%s/sensor/dragino_gw_%s/tx/config", HA_PREFIX, gw_id), jsonc.stringify(tx_config), true)

    -- 4. CRC Errors (Counter)
    local crc_config = {
        name = "LoRa CRC Errors",
        unique_id = "dragino_gw_" .. gw_id .. "_crc_err",
        state_topic = state_topic,
        value_template = "{{ value_json.crc_err | default(0) }}",
        state_class = "total_increasing",
        entity_category = "diagnostic",
        icon = "mdi:alert-circle-outline",
        device = gw_device
    }
    mqtt_publish(string.format("%s/sensor/dragino_gw_%s/crc_err/config", HA_PREFIX, gw_id), jsonc.stringify(crc_config), true)

    -- 5. Active Registered Nodes Count
    local nodes_config = {
        name = "Active LoRa Nodes",
        unique_id = "dragino_gw_" .. gw_id .. "_active_nodes",
        state_topic = state_topic,
        value_template = "{{ value_json.active_nodes | default(0) }}",
        icon = "mdi:devices",
        device = gw_device
    }
    mqtt_publish(string.format("%s/sensor/dragino_gw_%s/active_nodes/config", HA_PREFIX, gw_id), jsonc.stringify(nodes_config), true)

    -- 6. Radio State (LISTENING, TX_FREE)
    local state_config = {
        name = "Radio State",
        unique_id = "dragino_gw_" .. gw_id .. "_radio_state",
        state_topic = state_topic,
        value_template = "{{ value_json.rx_status | default('LISTENING') }}",
        entity_category = "diagnostic",
        icon = "mdi:signal-distance-variant",
        device = gw_device
    }
    mqtt_publish(string.format("%s/sensor/dragino_gw_%s/radio_state/config", HA_PREFIX, gw_id), jsonc.stringify(state_config), true)

    -- 7. Gateway System Uptime
    local uptime_config = {
        name = "Gateway Uptime",
        unique_id = "dragino_gw_" .. gw_id .. "_uptime",
        state_topic = state_topic,
        value_template = "{{ (value_json.uptime_s | default(0) / 3600) | round(1) }}",
        unit_of_measurement = "h",
        entity_category = "diagnostic",
        icon = "mdi:clock-outline",
        device = gw_device
    }
    mqtt_publish(string.format("%s/sensor/dragino_gw_%s/uptime/config", HA_PREFIX, gw_id), jsonc.stringify(uptime_config), true)

    -- 8. Radio Connectivity (Binary Sensor)
    local conn_config = {
        name = "Radio Online",
        unique_id = "dragino_gw_" .. gw_id .. "_online",
        state_topic = state_topic,
        value_template = "{{ 'ON' if (value_json.rx_status | default('LISTENING')) == 'LISTENING' else 'OFF' }}",
        device_class = "connectivity",
        entity_category = "diagnostic",
        device = gw_device
    }
    mqtt_publish(string.format("%s/binary_sensor/dragino_gw_%s/online/config", HA_PREFIX, gw_id), jsonc.stringify(conn_config), true)

    -- 9. Restart LoRa Concentrator (Button)
    local restart_config = {
        name = "Restart LoRa Concentrator",
        unique_id = "dragino_gw_" .. gw_id .. "_restart",
        command_topic = TOPIC_ROOT .. "/gateway/restart",
        payload_press = "PRESS",
        device_class = "restart",
        entity_category = "config",
        device = gw_device
    }
    mqtt_publish(string.format("%s/button/dragino_gw_%s/restart/config", HA_PREFIX, gw_id), jsonc.stringify(restart_config), true)
end

-- ==============================================================================
-- Home Assistant MQTT Discovery: Child LoRa Nodes
-- ==============================================================================
-- ==============================================================================
-- Home Assistant MQTT Discovery: Child LoRa Nodes
-- ==============================================================================
local function publish_ha_discovery(node)
    if not MQTT_ENABLED then return end
    local gw = g_gw_info
    local gw_device_id = "dragino_gateway_" .. gw.eui

    local node_id = node.node_id
    local clean_name = node.name
    if not clean_name or clean_name:find("^New Node") or clean_name:find("^Node ") or clean_name == "" then
        clean_name = "LoRa Node " .. node_id
    end

    local cls = (node.node_class or "A"):upper()
    local area = (node.group_name and node.group_name ~= "Unassigned" and node.group_name ~= "Uncategorized" and node.group_name ~= "Default") and node.group_name or nil
    local state_topic = TOPIC_ROOT .. "/" .. node_id .. "/state"

    local device_obj = {
        identifiers = { "lora_" .. node_id },
        name = clean_name,
        model = (node.model and node.model ~= "" and node.model ~= "generic") and node.model or ("LoRa Device (Class " .. cls .. ")"),
        manufacturer = "Custom Dragino Gateway",
        suggested_area = area,
        sw_version = "v1.2.0",
        via_device = gw_device_id
    }

    -- 1. Temperature Sensor
    local temp_config = {
        name = "Temperature",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_temperature",
        state_topic = state_topic,
        value_template = "{{ value_json.temperature | default(none) }}",
        unit_of_measurement = "°C",
        device_class = "temperature",
        state_class = "measurement",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/temp/config", HA_PREFIX, node_id), jsonc.stringify(temp_config), true)

    -- 2. Battery Voltage (V)
    local batt_config = {
        name = "Battery Voltage",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_battery",
        state_topic = state_topic,
        value_template = "{{ value_json.battery | default(none) }}",
        unit_of_measurement = "V",
        device_class = "voltage",
        state_class = "measurement",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/batt/config", HA_PREFIX, node_id), jsonc.stringify(batt_config), true)

    -- 3. Battery Voltage (mV)
    local batt_mv_config = {
        name = "Battery (mV)",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_battery_mv",
        state_topic = state_topic,
        value_template = "{{ value_json.battery_mv | default(none) }}",
        unit_of_measurement = "mV",
        device_class = "voltage",
        entity_category = "diagnostic",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/batt_mv/config", HA_PREFIX, node_id), jsonc.stringify(batt_mv_config), true)

    -- 4. RSSI Signal Sensor (Diagnostic)
    local rssi_config = {
        name = "Signal RSSI",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_rssi",
        state_topic = state_topic,
        value_template = "{{ value_json.rssi | default(none) }}",
        unit_of_measurement = "dBm",
        device_class = "signal_strength",
        entity_category = "diagnostic",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/rssi/config", HA_PREFIX, node_id), jsonc.stringify(rssi_config), true)

    -- 5. Signal SNR (Diagnostic)
    local snr_config = {
        name = "Signal SNR",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_snr",
        state_topic = state_topic,
        value_template = "{{ value_json.snr | default(none) }}",
        unit_of_measurement = "dB",
        entity_category = "diagnostic",
        icon = "mdi:signal-distance-variant",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/snr/config", HA_PREFIX, node_id), jsonc.stringify(snr_config), true)

    -- 6. RF Frequency (Diagnostic)
    local freq_config = {
        name = "Frequency",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_freq",
        state_topic = state_topic,
        value_template = "{{ value_json.freq | default(none) }}",
        unit_of_measurement = "MHz",
        entity_category = "diagnostic",
        icon = "mdi:radio-tower",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/freq/config", HA_PREFIX, node_id), jsonc.stringify(freq_config), true)

    -- 7. Data Rate / Spreading Factor (Diagnostic)
    local datr_config = {
        name = "Data Rate",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_datr",
        state_topic = state_topic,
        value_template = "{{ value_json.datr | default(none) }}",
        entity_category = "diagnostic",
        icon = "mdi:antenna",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/datr/config", HA_PREFIX, node_id), jsonc.stringify(datr_config), true)

    -- 8. Packet Sequence Counter (Diagnostic)
    local seq_config = {
        name = "Packet Sequence",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_seq",
        state_topic = state_topic,
        value_template = "{{ value_json.seq | default(value_json.fcnt) | default(none) }}",
        state_class = "total_increasing",
        entity_category = "diagnostic",
        icon = "mdi:counter",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/seq/config", HA_PREFIX, node_id), jsonc.stringify(seq_config), true)

    -- 9. Network Identifier (Diagnostic)
    local netid_config = {
        name = "Network ID",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_net_id",
        state_topic = state_topic,
        value_template = "{{ value_json.net_id | default(none) }}",
        entity_category = "diagnostic",
        icon = "mdi:identifier",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/net_id/config", HA_PREFIX, node_id), jsonc.stringify(netid_config), true)

    -- 10. Sender Hardware ID (Diagnostic)
    local sender_config = {
        name = "Sender ID",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_sender_id",
        state_topic = state_topic,
        value_template = "{{ value_json.sender_id | default(none) }}",
        entity_category = "diagnostic",
        icon = "mdi:chip",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/sender_id/config", HA_PREFIX, node_id), jsonc.stringify(sender_config), true)

    -- 11. Target Gateway ID (Diagnostic)
    local target_config = {
        name = "Target Gateway",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_target_id",
        state_topic = state_topic,
        value_template = "{{ value_json.target_id | default(none) }}",
        entity_category = "diagnostic",
        icon = "mdi:router-wireless",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/target_id/config", HA_PREFIX, node_id), jsonc.stringify(target_config), true)

    -- 12. Channel 1 Raw Sensor Value
    local ch1_config = {
        name = "Channel 1 Raw",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_ch1_val",
        state_topic = state_topic,
        value_template = "{{ value_json.ch1_val | default(none) }}",
        entity_category = "diagnostic",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/ch1_val/config", HA_PREFIX, node_id), jsonc.stringify(ch1_config), true)

    -- 13. Humidity Sensor
    local hum_config = {
        name = "Humidity",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_humidity",
        state_topic = state_topic,
        value_template = "{{ value_json.humidity | default(none) }}",
        unit_of_measurement = "%",
        device_class = "humidity",
        state_class = "measurement",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/humidity/config", HA_PREFIX, node_id), jsonc.stringify(hum_config), true)

    -- 14. Atmospheric Pressure Sensor
    local press_config = {
        name = "Pressure",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_pressure",
        state_topic = state_topic,
        value_template = "{{ value_json.pressure | default(none) }}",
        unit_of_measurement = "hPa",
        device_class = "pressure",
        state_class = "measurement",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/pressure/config", HA_PREFIX, node_id), jsonc.stringify(press_config), true)

    -- 15. Last Seen Timestamp (Diagnostic)
    local seen_config = {
        name = "Last Seen",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_last_seen",
        state_topic = state_topic,
        value_template = "{{ value_json.last_seen | default(none) }}",
        device_class = "timestamp",
        entity_category = "diagnostic",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/last_seen/config", HA_PREFIX, node_id), jsonc.stringify(seen_config), true)

    -- 16. Raw Payload HEX (Diagnostic)
    local hex_config = {
        name = "Raw Hex",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_raw_hex",
        state_topic = state_topic,
        value_template = "{{ value_json.hex | default(none) }}",
        entity_category = "diagnostic",
        icon = "mdi:code-json",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/raw_hex/config", HA_PREFIX, node_id), jsonc.stringify(hex_config), true)

    -- 17. Actuator / Switch Entity (for Class C actuators or relays)
    if cls == "C" or (node.model and (node.model:find("valve") or node.model:find("relay") or node.model:find("actuator"))) then
        local switch_config = {
            name = "Actuator",
            has_entity_name = true,
            unique_id = "lora_" .. node_id .. "_switch",
            state_topic = state_topic,
            command_topic = TOPIC_ROOT .. "/" .. node_id .. "/set",
            value_template = "{{ value_json.state | default('OFF') }}",
            payload_on = "ON",
            payload_off = "OFF",
            state_on = "ON",
            state_off = "OFF",
            device = device_obj
        }
        mqtt_publish(string.format("%s/switch/lora_%s/switch/config", HA_PREFIX, node_id), jsonc.stringify(switch_config), true)
    end

    -- 18. Digital Channel 1 State (Binary Sensor)
    local ch1_state_config = {
        name = "Channel 1 State",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_ch1_state",
        state_topic = state_topic,
        value_template = "{{ value_json.ch1_state | default(none) }}",
        payload_on = "ON",
        payload_off = "OFF",
        device = device_obj
    }
    mqtt_publish(string.format("%s/binary_sensor/lora_%s/ch1_state/config", HA_PREFIX, node_id), jsonc.stringify(ch1_state_config), true)

    -- 19. Device Type Descriptor Byte (Diagnostic)
    local devtype_config = {
        name = "Device Type",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_device_type",
        state_topic = state_topic,
        value_template = "{{ value_json.device_type | default(none) }}",
        entity_category = "diagnostic",
        icon = "mdi:shape",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/device_type/config", HA_PREFIX, node_id), jsonc.stringify(devtype_config), true)

    -- 20. Device Capability (Diagnostic)
    local cap_config = {
        name = "Capability",
        has_entity_name = true,
        unique_id = "lora_" .. node_id .. "_capability",
        state_topic = state_topic,
        value_template = "{{ value_json.capability | default(none) }}",
        entity_category = "diagnostic",
        icon = "mdi:tag-outline",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/capability/config", HA_PREFIX, node_id), jsonc.stringify(cap_config), true)
end

-- ==============================================================================
-- Purge / Unpublish Node from Home Assistant (Delete from HA registry)
-- ==============================================================================
local function unpublish_ha_discovery(node_id)
    if not MQTT_ENABLED then return end
    local entity_keys = {
        { comp = "sensor",        key = "temp" },
        { comp = "sensor",        key = "batt" },
        { comp = "sensor",        key = "batt_mv" },
        { comp = "sensor",        key = "rssi" },
        { comp = "sensor",        key = "snr" },
        { comp = "sensor",        key = "freq" },
        { comp = "sensor",        key = "datr" },
        { comp = "sensor",        key = "seq" },
        { comp = "sensor",        key = "net_id" },
        { comp = "sensor",        key = "sender_id" },
        { comp = "sensor",        key = "target_id" },
        { comp = "sensor",        key = "ch1_val" },
        { comp = "sensor",        key = "humidity" },
        { comp = "sensor",        key = "pressure" },
        { comp = "sensor",        key = "last_seen" },
        { comp = "sensor",        key = "raw_hex" },
        { comp = "switch",        key = "switch" },
        { comp = "binary_sensor", key = "ch1_state" },
        { comp = "sensor",        key = "device_type" },
        { comp = "sensor",        key = "capability" },
    }
    for _, item in ipairs(entity_keys) do
        local topic = string.format("%s/%s/lora_%s/%s/config", HA_PREFIX, item.comp, node_id, item.key)
        mqtt_publish(topic, "", true)
    end
end

-- ==============================================================================
-- Synchronize Home Assistant Discovery
-- Only publishes adopted & categorized nodes; purges uncategorized/unassigned nodes
-- ==============================================================================
local function sync_all_discovery()
    publish_gateway_discovery()
    local db = sqlite3.open(DB_NODES_PATH)
    if not db then return end
    db:busy_timeout(5000)
    db:exec("PRAGMA journal_mode = MEMORY;")

    -- 1. Read Adopted, Configured & Categorized Nodes
    local active_nodes = {}
    for row in db:nrows([[
        SELECT * FROM node_settings 
        WHERE ha_enabled = 1 
          AND is_configured = 1 
          AND group_name IS NOT NULL 
          AND group_name != '' 
          AND group_name != 'Unassigned' 
          AND group_name != 'Uncategorized';
    ]]) do
        table.insert(active_nodes, row)
    end

    -- 2. Read Inactive, Unconfigured, or Uncategorized Nodes to Purge from Home Assistant
    local inactive_ids = {}
    for row in db:nrows([[
        SELECT node_id FROM node_settings 
        WHERE ha_enabled = 0 
           OR is_configured = 0 
           OR group_name IS NULL 
           OR group_name = '' 
           OR group_name = 'Unassigned' 
           OR group_name = 'Uncategorized';
    ]]) do
        table.insert(inactive_ids, row.node_id)
    end

    db:close()

    -- 3. Perform network MQTT publications with database closed (zero lock contention)
    for _, row in ipairs(active_nodes) do
        publish_ha_discovery(row)
    end
    for _, nid in ipairs(inactive_ids) do
        unpublish_ha_discovery(nid)
    end
end

-- Publish Gateway Live Telemetry to `lora/gateway/state`
local function publish_gateway_telemetry()
    if not MQTT_ENABLED then return end
    local stat = query_gateway_status() or {}
    local active_count = count_active_nodes()

    local payload_tbl = {
        temp_c       = stat.temp_c or 30.0,
        rx           = stat.rx or 0,
        tx           = stat.tx or 0,
        crc_err      = stat.crc_err or 0,
        rx_status    = stat.rx_status or "LISTENING",
        tx_status    = stat.tx_status or "TX_FREE",
        uptime_s     = stat.uptime_s or 0,
        active_nodes = active_count
    }

    local topic = TOPIC_ROOT .. "/gateway/state"
    mqtt_publish(topic, jsonc.stringify(payload_tbl), true)
end

-- Measure Channel RSSI (Listen-Before-Send)
local function lbt_check_clear(thresh_dbm)
    thresh_dbm = thresh_dbm or -85
    local current_rssi = -110.0
    local f = io.open(PACKETS_JSON, "r")
    if f then
        local content = f:read("*a")
        f:close()
        local list = content and jsonc.parse(content)
        if list and #list > 0 and list[1].rssic then
            current_rssi = tonumber(list[1].rssic) or -110.0
        end
    end
    return (current_rssi < thresh_dbm), current_rssi
end

-- Send LoRa Downlink to Concentrator UDP Socket
local function dispatch_lora_downlink(node_id, cmd_payload)
    local db = sqlite3.open(DB_NODES_PATH)
    local tx_power = 14
    local node_class = "C"

    if db then
        local stmt = db:prepare("SELECT node_class, default_tx_power FROM node_settings WHERE node_id = ?;")
        if stmt then
            stmt:bind_values(node_id)
            if stmt:step() == sqlite3.ROW then
                node_class = stmt:get_value(0) or "C"
                tx_power = stmt:get_value(1) or 14
            end
            stmt:finalize()
        end
        db:close()
    end

    -- Translate simple Home Assistant ON/OFF to binary hex
    local raw_payload = cmd_payload
    if cmd_payload == "ON" or cmd_payload == "1" then
        raw_payload = "0101"
    elseif cmd_payload == "OFF" or cmd_payload == "0" then
        raw_payload = "0100"
    end

    local is_hex = (raw_payload:match("^%x+$") and #raw_payload % 2 == 0)
    local raw_bin = is_hex and (raw_payload:gsub('..', function(cc) return string.char(tonumber(cc, 16)) end)) or raw_payload
    local b64 = nixio.bin.b64encode(raw_bin)

    -- Listen-Before-Send
    local is_clear, rssi = lbt_check_clear(-85)
    if not is_clear then
        nixio.nanosleep(0, 40000000) -- backoff 40ms
    end

    local pkt = {
        imme = (node_class == "C"),
        freq = 868.1,
        rfch = 0,
        powe = tx_power,
        modu = "LORA",
        datr = "SF7BW125",
        codr = "4/5",
        ipol = false,
        size = #raw_payload,
        data = b64
    }

    local sock = nixio.socket("inet", "dgram")
    if sock then
        sock:sendto(jsonc.stringify(pkt), "127.0.0.1", PORT_DOWN)
        sock:close()
    end

    -- Publish state update back to Home Assistant immediately
    local state_val = (cmd_payload == "ON" or cmd_payload == "1" or raw_payload == "0101") and "ON" or "OFF"
    local state_json = jsonc.stringify({ state = state_val, last_cmd = raw_payload })
    mqtt_publish(TOPIC_ROOT .. "/" .. node_id .. "/state", state_json, true)
end

-- ==============================================================================
-- Main MQTT Supervisor & Background Ticker Loop
-- ==============================================================================
print(string.format("[MQTT] Starting Home Assistant Gateway & LoRa Bridge (Broker: %s:%d)...", MQTT_HOST, MQTT_PORT))

-- 1. Initial sync of Home Assistant Discovery Configs (Gateway + Nodes)
sync_all_discovery()
publish_gateway_telemetry()

-- 2. Fork dedicated background worker for periodic Gateway Telemetry & Node discovery refresh
local ticker_pid = nixio.fork()
if ticker_pid == 0 then
    -- Ticker child process
    local last_active_nodes = count_active_nodes()
    local tick_count = 0
    while true do
        publish_gateway_telemetry()
        tick_count = tick_count + 1

        -- Every 30s (3 ticks) or when node count changes, sync discovery
        local current_nodes = count_active_nodes()
        if (current_nodes ~= last_active_nodes) or (tick_count % 3 == 0) then
            last_active_nodes = current_nodes
            sync_all_discovery()
        end

        nixio.nanosleep(10, 0)
        -- Terminate if parent died
        if nixio.getppid() == 1 then
            os.exit(0)
        end
    end
    os.exit(0)
end

-- 3. Main process: mosquitto_sub listener loop for HA Commands & Gateway Restarts
local sub_cmd = string.format(
    "mosquitto_sub -h %s -p %d %s -t '%s/+/set' -t '%s/gateway/restart' -v 2>/dev/null",
    shellquote(MQTT_HOST),
    MQTT_PORT,
    AUTH_FLAGS,
    TOPIC_ROOT,
    TOPIC_ROOT
)

while true do
    local sub_pipe = io.popen(sub_cmd)
    if sub_pipe then
        for line in sub_pipe:lines() do
            local topic, payload = line:match("^(%S+)%s*(.*)$")
            if topic then
                payload = (payload or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if topic == TOPIC_ROOT .. "/gateway/restart" then
                    print("[MQTT-RECV] Concentrator Restart command from Home Assistant!")
                    os.execute("killall raw_lora_app sx1276_app lg02_pkt_fwd 2>/dev/null")
                else
                    local node_id = topic:match(TOPIC_ROOT .. "/([^/]+)/set")
                    if node_id then
                        node_id = node_id:upper()
                        print(string.format("[MQTT-RECV] Downlink Command from Home Assistant for [%s]: %s", node_id, payload))
                        dispatch_lora_downlink(node_id, payload)
                    end
                end
            end
        end
        sub_pipe:close()
    end

    -- If mosquitto_sub dropped or broker restarted, wait 5s and reconnect
    print("[MQTT] mosquitto_sub disconnected. Reconnecting in 5 seconds...")
    nixio.nanosleep(5, 0)
end
