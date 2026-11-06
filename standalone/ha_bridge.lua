-- ==============================================================================
-- ha_bridge.lua — Home Assistant MQTT Discovery & Telemetry Bridge
-- ==============================================================================
-- Part of the Standalone LoRa Decoder & Home Assistant Pipeline
-- Handles:
--   1. Dynamic Home Assistant MQTT Auto-Discovery configuration
--   2. Real-time telemetry state publication (lora/<node_id>/state)
--   3. Orphan entity purge & unpublish management
-- ==============================================================================

local LoraDecoder = require "lora_decoder"
local json = LoraDecoder.json

local HABridge = {
    _VERSION = "2.1.0",
    DEFAULT_HA_PREFIX  = "homeassistant",
    DEFAULT_STATE_TOPIC = "lora"
}

local function shellquote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- ------------------------------------------------------------------------------
-- Low-Level MQTT Publishing (Compatible with mosquitto_pub or Lua socket)
-- ------------------------------------------------------------------------------
function HABridge.mqtt_publish(topic, payload, retain, mqtt_cfg)
    mqtt_cfg = mqtt_cfg or {}
    local host = mqtt_cfg.host or mqtt_cfg.server or "127.0.0.1"
    local port = tonumber(mqtt_cfg.port) or 1883
    local auth = ""
    if mqtt_cfg.user and mqtt_cfg.user ~= "" then
        auth = auth .. " -u " .. shellquote(mqtt_cfg.user)
    end
    if mqtt_cfg.password and mqtt_cfg.password ~= "" then
        auth = auth .. " -P " .. shellquote(mqtt_cfg.password)
    end

    local retain_flag = retain and "-r" or ""
    local cmd = string.format(
        "mosquitto_pub -h %s -p %d %s -t %s -m %s %s 2>/dev/null &",
        shellquote(host),
        port,
        auth,
        shellquote(topic),
        shellquote(payload or ""),
        retain_flag
    )
    os.execute(cmd)
end

-- ------------------------------------------------------------------------------
-- Home Assistant Telemetry State Dispatch (Immediate / Sub-5ms)
-- ------------------------------------------------------------------------------
function HABridge.publish_telemetry(node_id, metrics, mqtt_cfg)
    if not node_id or not metrics then return end
    local prefix = (mqtt_cfg and (mqtt_cfg.state_prefix or mqtt_cfg.prefix)) or HABridge.DEFAULT_STATE_TOPIC
    local topic = prefix .. "/" .. node_id .. "/state"
    local payload = json.stringify(metrics)
    HABridge.mqtt_publish(topic, payload, true, mqtt_cfg)
end

-- ------------------------------------------------------------------------------
-- Home Assistant Auto-Discovery Registration
-- ------------------------------------------------------------------------------
function HABridge.publish_discovery(node, metrics, mqtt_cfg)
    local ha_pfx = (mqtt_cfg and mqtt_cfg.ha_prefix) or HABridge.DEFAULT_HA_PREFIX
    local state_pfx = (mqtt_cfg and (mqtt_cfg.state_prefix or mqtt_cfg.prefix)) or HABridge.DEFAULT_STATE_TOPIC

    local node_id = node.node_id or metrics.node_id
    if not node_id then return end

    local node_name = node.name or ("LoRa Node " .. node_id)
    local cls = (node.node_class or metrics.node_class or "A"):upper()
    local state_topic = state_pfx .. "/" .. node_id .. "/state"

    local device_obj = {
        identifiers  = { "lora_" .. node_id },
        name         = node_name,
        model        = node.model or ("LoRa Device (Class " .. cls .. ")"),
        manufacturer = "Custom LoRa Gateway",
        sw_version   = "v2.1.0"
    }
    if node.suggested_area and node.suggested_area ~= "" then
        device_obj.suggested_area = node.suggested_area
    end

    -- 1. Temperature Sensor
    if metrics.temperature ~= nil or metrics.temp ~= nil then
        local cfg = {
            name = "Temperature",
            has_entity_name = true,
            unique_id = "lora_" .. node_id .. "_temperature",
            state_topic = state_topic,
            value_template = "{{ value_json.temperature | default(value_json.temp) | default(none) }}",
            unit_of_measurement = "°C",
            device_class = "temperature",
            state_class = "measurement",
            device = device_obj
        }
        HABridge.mqtt_publish(string.format("%s/sensor/lora_%s/temp/config", ha_pfx, node_id), json.stringify(cfg), true, mqtt_cfg)
    end

    -- 2. Battery Voltage (V)
    if metrics.battery ~= nil or metrics.batt ~= nil then
        local cfg = {
            name = "Battery Voltage",
            has_entity_name = true,
            unique_id = "lora_" .. node_id .. "_battery",
            state_topic = state_topic,
            value_template = "{{ value_json.battery | default(value_json.batt) | default(none) }}",
            unit_of_measurement = "V",
            device_class = "voltage",
            state_class = "measurement",
            device = device_obj
        }
        HABridge.mqtt_publish(string.format("%s/sensor/lora_%s/batt/config", ha_pfx, node_id), json.stringify(cfg), true, mqtt_cfg)
    end

    -- 3. Accelerometer (X, Y, Z)
    if metrics.accel_x ~= nil or metrics.accel_y ~= nil or metrics.accel_z ~= nil then
        for _, axis in ipairs({"x", "y", "z"}) do
            local key = "accel_" .. axis
            local cfg = {
                name = "Acceleration " .. axis:upper(),
                has_entity_name = true,
                unique_id = "lora_" .. node_id .. "_" .. key,
                state_topic = state_topic,
                value_template = "{{ value_json." .. key .. " | default(none) }}",
                unit_of_measurement = "g",
                icon = "mdi:axis-arrow",
                state_class = "measurement",
                device = device_obj
            }
            HABridge.mqtt_publish(string.format("%s/sensor/lora_%s/%s/config", ha_pfx, node_id, key), json.stringify(cfg), true, mqtt_cfg)
        end
    end

    -- 4. Humidity Sensor
    if metrics.humidity ~= nil or metrics.hum ~= nil then
        local cfg = {
            name = "Humidity",
            has_entity_name = true,
            unique_id = "lora_" .. node_id .. "_humidity",
            state_topic = state_topic,
            value_template = "{{ value_json.humidity | default(value_json.hum) | default(none) }}",
            unit_of_measurement = "%",
            device_class = "humidity",
            state_class = "measurement",
            device = device_obj
        }
        HABridge.mqtt_publish(string.format("%s/sensor/lora_%s/humidity/config", ha_pfx, node_id), json.stringify(cfg), true, mqtt_cfg)
    end

    -- 5. Pressure Sensor
    if metrics.pressure ~= nil or metrics.baro ~= nil then
        local cfg = {
            name = "Pressure",
            has_entity_name = true,
            unique_id = "lora_" .. node_id .. "_pressure",
            state_topic = state_topic,
            value_template = "{{ value_json.pressure | default(value_json.baro) | default(none) }}",
            unit_of_measurement = "hPa",
            device_class = "pressure",
            state_class = "measurement",
            device = device_obj
        }
        HABridge.mqtt_publish(string.format("%s/sensor/lora_%s/pressure/config", ha_pfx, node_id), json.stringify(cfg), true, mqtt_cfg)
    end

    -- 6. Diagnostics (RSSI, SNR, Frequency, Data Rate, Sequence, Last Seen)
    local diag_list = {
        { key = "rssi", name = "Signal RSSI", unit = "dBm", dev_cls = "signal_strength", tmpl = "{{ value_json.rssi | default(none) }}" },
        { key = "snr", name = "Signal SNR", unit = "dB", icon = "mdi:signal-distance-variant", tmpl = "{{ value_json.snr | default(none) }}" },
        { key = "freq", name = "Frequency", unit = "MHz", icon = "mdi:radio-tower", tmpl = "{{ value_json.freq | default(none) }}" },
        { key = "datr", name = "Data Rate", icon = "mdi:antenna", tmpl = "{{ value_json.datr | default(none) }}" },
        { key = "seq", name = "Packet Sequence", icon = "mdi:counter", tmpl = "{{ value_json.seq | default(none) }}", st_cls = "total_increasing" },
        { key = "last_seen", name = "Last Seen", dev_cls = "timestamp", tmpl = "{{ value_json.last_seen | default(none) }}" }
    }

    for _, d in ipairs(diag_list) do
        local cfg = {
            name = d.name,
            has_entity_name = true,
            unique_id = "lora_" .. node_id .. "_" .. d.key,
            state_topic = state_topic,
            value_template = d.tmpl,
            unit_of_measurement = d.unit,
            device_class = d.dev_cls,
            icon = d.icon,
            state_class = d.st_cls,
            entity_category = "diagnostic",
            device = device_obj
        }
        HABridge.mqtt_publish(string.format("%s/sensor/lora_%s/%s/config", ha_pfx, node_id, d.key), json.stringify(cfg), true, mqtt_cfg)
    end
end

-- ------------------------------------------------------------------------------
-- Purge / Unpublish Node from Home Assistant Registry
-- ------------------------------------------------------------------------------
function HABridge.unpublish_discovery(node_id, mqtt_cfg)
    local ha_pfx = (mqtt_cfg and mqtt_cfg.ha_prefix) or HABridge.DEFAULT_HA_PREFIX
    local entity_keys = {
        { comp = "sensor", key = "temp" },
        { comp = "sensor", key = "batt" },
        { comp = "sensor", key = "batt_mv" },
        { comp = "sensor", key = "rssi" },
        { comp = "sensor", key = "snr" },
        { comp = "sensor", key = "freq" },
        { comp = "sensor", key = "datr" },
        { comp = "sensor", key = "seq" },
        { comp = "sensor", key = "class" },
        { comp = "sensor", key = "humidity" },
        { comp = "sensor", key = "pressure" },
        { comp = "sensor", key = "accel_x" },
        { comp = "sensor", key = "accel_y" },
        { comp = "sensor", key = "accel_z" },
        { comp = "sensor", key = "last_seen" },
        { comp = "switch", key = "switch" },
        { comp = "sensor", key = "net_id" },
        { comp = "sensor", key = "sender_id" },
        { comp = "sensor", key = "target_id" },
        { comp = "sensor", key = "ch1_val" },
        { comp = "sensor", key = "raw_hex" }
    }
    for _, item in ipairs(entity_keys) do
        local topic = string.format("%s/%s/lora_%s/%s/config", ha_pfx, item.comp, node_id, item.key)
        HABridge.mqtt_publish(topic, "", true, mqtt_cfg)
    end
end

return HABridge
