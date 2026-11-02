#!/usr/bin/env lua
-- /usr/bin/lora_mqtt_bridge.lua
-- Home Assistant MQTT Auto-Discovery & Bidirectional Downlink Bridge
-- Compatible with Dragino LPS8 (SX1302) & LG01/LG02 (SX1276)
--
-- Features:
--   1. Auto-publishes Home Assistant MQTT Discovery for all registered nodes.
--   2. Groups entities under a single unified Device Card with Area/Group in HA.
--   3. Publishes live telemetry to `lora/<NODE_ID>/state`.
--   4. Subscribes to `lora/+/set` for bidirectional downlinks from Home Assistant.
--   5. Performs Listen-Before-Send (LBT) and dispatches LoRa downlinks to port 5556.

local sqlite3 = require "lsqlite3"
local nixio   = require "nixio"
local jsonc   = require "luci.jsonc"

local CONFIG_PATH   = "/etc/lora/config.json"
local DB_NODES_PATH = "/etc/lora/nodes.db"
local PACKETS_JSON  = "/tmp/lora_packets.json"
local PORT_DOWN     = 5556

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

local function build_auth_flags()
    local flags = ""
    if MQTT_USER ~= "" then
        flags = flags .. " -u " .. nixio.shellquote(MQTT_USER)
    end
    if MQTT_PASS ~= "" then
        flags = flags .. " -P " .. nixio.shellquote(MQTT_PASS)
    end
    return flags
end

local AUTH_FLAGS = build_auth_flags()

local function mqtt_publish(topic, payload, retain)
    if not MQTT_ENABLED then return end
    local cmd = string.format(
        "mosquitto_pub -h %s -p %d %s %s -t %s -m %s 2>/dev/null",
        nixio.shellquote(MQTT_HOST),
        MQTT_PORT,
        AUTH_FLAGS,
        retain and "-r" or "",
        nixio.shellquote(topic),
        nixio.shellquote(payload)
    )
    os.execute(cmd)
end

-- Publish Home Assistant MQTT Discovery Configs for a Node
local function publish_ha_discovery(node)
    if not MQTT_ENABLED then return end
    local node_id = node.node_id
    local name = node.name or ("Node " .. node_id)
    local cls = node.node_class or "A"
    local area = node.group_name or "Default"

    local device_obj = {
        identifiers = { "lora_" .. node_id },
        name = name,
        model = "LoRa Device (Class " .. cls .. ")",
        manufacturer = "Custom Dragino Gateway",
        suggested_area = area,
        sw_version = "v1.1.0"
    }

    -- 1. Temperature Sensor (if model is sensor or default)
    local temp_config = {
        name = name .. " Temperature",
        unique_id = "lora_" .. node_id .. "_temperature",
        state_topic = TOPIC_ROOT .. "/" .. node_id .. "/state",
        value_template = "{{ value_json.temperature | default(none) }}",
        unit_of_measurement = "°C",
        device_class = "temperature",
        state_class = "measurement",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/temp/config", HA_PREFIX, node_id), jsonc.stringify(temp_config), true)

    -- 2. Battery Voltage Sensor
    local batt_config = {
        name = name .. " Battery",
        unique_id = "lora_" .. node_id .. "_battery",
        state_topic = TOPIC_ROOT .. "/" .. node_id .. "/state",
        value_template = "{{ value_json.battery | default(none) }}",
        unit_of_measurement = "V",
        device_class = "voltage",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/batt/config", HA_PREFIX, node_id), jsonc.stringify(batt_config), true)

    -- 3. RSSI Signal Sensor (Diagnostic)
    local rssi_config = {
        name = name .. " RSSI",
        unique_id = "lora_" .. node_id .. "_rssi",
        state_topic = TOPIC_ROOT .. "/" .. node_id .. "/state",
        value_template = "{{ value_json.rssi | default(none) }}",
        unit_of_measurement = "dBm",
        device_class = "signal_strength",
        entity_category = "diagnostic",
        device = device_obj
    }
    mqtt_publish(string.format("%s/sensor/lora_%s/rssi/config", HA_PREFIX, node_id), jsonc.stringify(rssi_config), true)

    -- 4. Actuator / Switch Entity (for Class C actuators or relays)
    if cls == "C" or (node.model and node.model:find("valve") or node.model:find("relay") or node.model:find("actuator")) then
        local switch_config = {
            name = name .. " Actuator",
            unique_id = "lora_" .. node_id .. "_switch",
            state_topic = TOPIC_ROOT .. "/" .. node_id .. "/state",
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
end

-- Auto-Publish Discovery for all registered nodes in SQLite
local function sync_all_discovery()
    local db = sqlite3.open(DB_NODES_PATH)
    if not db then return end
    for row in db:nrows("SELECT * FROM node_settings WHERE ha_enabled = 1;") do
        publish_ha_discovery(row)
    end
    db:close()
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
-- Main MQTT Subscriber & Discovery Loop
-- ==============================================================================
print(string.format("[MQTT] Starting Home Assistant MQTT Bridge (Broker: %s:%d)...", MQTT_HOST, MQTT_PORT))

-- 1. Initial sync of Home Assistant Discovery Configs
sync_all_discovery()

-- 2. Spawn mosquitto_sub listening for Home Assistant commands (lora/+/set)
local sub_cmd = string.format(
    "mosquitto_sub -h %s -p %d %s -t '%s/+/set' -v 2>/dev/null",
    nixio.shellquote(MQTT_HOST),
    MQTT_PORT,
    AUTH_FLAGS,
    TOPIC_ROOT
)

local sub_pipe = io.popen(sub_cmd)
if not sub_pipe then
    io.stderr:write("[MQTT] Failed to spawn mosquitto_sub listener!\n")
    os.exit(1)
end

for line in sub_pipe:lines() do
    -- Format: lora/AA0C/set ON
    local topic, payload = line:match("^(%S+)%s+(.*)$")
    if topic and payload then
        local node_id = topic:match(TOPIC_ROOT .. "/([^/]+)/set")
        if node_id then
            node_id = node_id:upper()
            payload = payload:gsub("^%s+", ""):gsub("%s+$", "")
            print(string.format("[MQTT-RECV] Downlink Command from Home Assistant for [%s]: %s", node_id, payload))
            dispatch_lora_downlink(node_id, payload)
        end
    end
end

sub_pipe:close()
