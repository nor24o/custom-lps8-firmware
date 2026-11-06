#!/usr/bin/env lua
-- /usr/bin/lora_linking_engine.lua
-- Industrial LoRa Gateway Linking, Queuing, & Downlink Engine
-- Supports:
--   - Multi-Scheme Payload Decoder (/etc/lora/decoders.json)
--   - Configurable Node ID Extraction (NetID+SenderID, Offset/Length, Decoded Field, Auto)
--   - Dual SQLite: /etc/lora/nodes.db (Flash) & /tmp/lora_messages.db (RAM)
--   - Rolling 50-message circular buffer per node
--   - LPWAN Classes: Class A (Queued RX1/RX2), Class B (Ping Slots), Class C (Instant)
--   - Listen-Before-Send (LBT / Carrier Sense) & Collision Avoidance
--   - Turnaround delays, debounce cooldowns, and automatic pulse resets

local sqlite3 = require "lsqlite3"
local nixio   = require "nixio"
local jsonc   = require "luci.jsonc"

local DB_NODES_PATH = "/etc/lora/nodes.db"
local DB_RAM_PATH   = "/tmp/lora_messages.db"
local PACKETS_JSON  = "/tmp/lora_packets.json"
local CONFIG_PATH   = "/etc/lora/config.json"
local DECODERS_PATH = "/etc/lora/decoders.json"
local PORT_DOWN     = 5556

-- Open Databases
local db_nodes = sqlite3.open(DB_NODES_PATH)
local db_ram   = sqlite3.open(DB_RAM_PATH)

if not db_nodes or not db_ram then
    io.stderr:write("[ENGINE] Failed to open SQLite databases!\n")
    os.exit(1)
end
db_nodes:busy_timeout(5000)
db_ram:busy_timeout(5000)
db_nodes:exec("PRAGMA journal_mode = MEMORY;")
db_nodes:exec("PRAGMA synchronous = OFF;")
db_ram:exec("PRAGMA journal_mode = MEMORY;")
db_ram:exec("PRAGMA synchronous = OFF;")

-- Ensure databases are initialized
os.execute("/usr/bin/lora_db_init.sh >/dev/null 2>&1")

local function shellquote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function publish_mqtt_telemetry(node_id, metrics)
    local f = io.open(CONFIG_PATH, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    local cfg = jsonc.parse(content) or {}
    local m = cfg.mqtt or {}
    if m.enabled == false then return end

    local host = m.server or "127.0.0.1"
    local port = tonumber(m.port) or 1883
    local prefix = m.state_prefix or "lora"
    local auth = ""
    if m.user and m.user ~= "" then
        auth = auth .. " -u " .. shellquote(m.user)
    end
    if m.password and m.password ~= "" then
        auth = auth .. " -P " .. shellquote(m.password)
    end

    local payload = jsonc.stringify(metrics)
    local topic = prefix .. "/" .. node_id .. "/state"
    local cmd = string.format(
        "mosquitto_pub -h %s -p %d %s -t %s -m %s -r 2>/dev/null &",
        shellquote(host),
        port,
        auth,
        shellquote(topic),
        shellquote(payload)
    )
    os.execute(cmd)
end

local function base64_encode(data)
    return nixio.bin.b64encode(data)
end

local function hex_to_bin(hex)
    return (hex:gsub('..', function(cc)
        return string.char(tonumber(cc, 16))
    end))
end

local function hex_to_bytes(h)
    local bytes = {}
    if not h then return bytes end
    for i = 1, #h, 2 do
        table.insert(bytes, tonumber(h:sub(i, i+1), 16) or 0)
    end
    return bytes
end

-- ==============================================================================
-- Decoders Configuration & Dynamic Parsing Engine
-- ==============================================================================

local g_decoders_cache = nil
local g_decoders_mtime = 0

local function get_decoders_config()
    local st = nixio.fs.stat(DECODERS_PATH)
    local mtime = st and st.mtime or 0
    if not g_decoders_cache or mtime ~= g_decoders_mtime then
        local f = io.open(DECODERS_PATH, "r")
        if f then
            local c = f:read("*a")
            f:close()
            g_decoders_cache = jsonc.parse(c) or {}
            g_decoders_mtime = mtime
        end
    end
    return g_decoders_cache or {}
end

-- Channel-Type-Value (CTV / TLV) & Cayenne LPP Unified Decoder:
local function parse_channels_at_offset(bytes, start_offset)
    local out = {}
    local i = start_offset + 1
    local count = 0
    while i <= #bytes do
        local ch = bytes[i]
        if ch == 0 and count > 0 then break end
        if ch < 1 or ch > 32 then break end
        i = i + 1
        if i > #bytes then break end
        local type_code = bytes[i]
        i = i + 1

        if type_code == 0x11 then
            if i + 1 > #bytes then break end
            local raw = (bytes[i] * 256) + bytes[i + 1]
            i = i + 2
            if raw >= 0x8000 then raw = raw - 0x10000 end
            local temp = (math.abs(raw) > 500) and (raw / 100.0) or (raw / 10.0)
            out.temperature = temp
            out["ch" .. ch .. "_val"] = raw
            out.val = temp
            count = count + 1
        elseif type_code == 0x05 then
            if i + 1 > #bytes then break end
            local mv = (bytes[i] * 256) + bytes[i + 1]
            i = i + 2
            out.battery = mv / 1000.0
            out.battery_mv = mv
            count = count + 1
        elseif type_code == 0x00 then
            if i > #bytes then break end
            out["ch" .. ch .. "_digital_in"] = bytes[i]
            i = i + 1
            count = count + 1
        elseif type_code == 0x01 or type_code == 0x10 then
            if i > #bytes then break end
            local val = bytes[i]
            i = i + 1
            out["ch" .. ch .. "_state"] = (val == 1) and "ON" or "OFF"
            out.state = (val == 1) and "ON" or "OFF"
            count = count + 1
        elseif type_code == 0x02 or type_code == 0x12 or type_code == 0x03 then
            if i + 1 > #bytes then break end
            local raw = (bytes[i] * 256) + bytes[i + 1]
            i = i + 2
            if raw >= 0x8000 then raw = raw - 0x10000 end
            local aval = raw / 100.0
            out["ch" .. ch .. "_analog_in"] = aval
            if ch == 1 and aval >= 1.8 and aval <= 5.5 and not out.battery then
                out.battery = aval
            end
            count = count + 1
        elseif type_code == 0x65 then
            if i + 1 > #bytes then break end
            out.illuminance = (bytes[i] * 256) + bytes[i + 1]
            i = i + 2
            count = count + 1
        elseif type_code == 0x66 then
            if i > #bytes then break end
            out.presence = bytes[i]
            i = i + 1
            count = count + 1
        elseif type_code == 0x67 then
            if i + 1 > #bytes then break end
            local raw = (bytes[i] * 256) + bytes[i + 1]
            i = i + 2
            if raw >= 0x8000 then raw = raw - 0x10000 end
            out.temperature = raw / 10.0
            out.val = out.temperature
            count = count + 1
        elseif type_code == 0x68 then
            if i > #bytes then break end
            out.humidity = bytes[i] * 0.5
            i = i + 1
            count = count + 1
        elseif type_code == 0x71 then
            if i + 5 > #bytes then break end
            local ax = (bytes[i] * 256) + bytes[i + 1]
            local ay = (bytes[i + 2] * 256) + bytes[i + 3]
            local az = (bytes[i + 4] * 256) + bytes[i + 5]
            i = i + 6
            if ax >= 0x8000 then ax = ax - 0x10000 end
            if ay >= 0x8000 then ay = ay - 0x10000 end
            if az >= 0x8000 then az = az - 0x10000 end
            out.accel_x = ax * 0.001
            out.accel_y = ay * 0.001
            out.accel_z = az * 0.001
            count = count + 1
        elseif type_code == 0x73 then
            if i + 1 > #bytes then break end
            out.pressure = ((bytes[i] * 256) + bytes[i + 1]) * 0.1
            i = i + 2
            count = count + 1
        elseif type_code == 0x88 then
            if i + 7 > #bytes then break end
            local lat = (bytes[i] * 65536) + (bytes[i + 1] * 256) + (bytes[i + 2] or 0)
            if lat >= 0x800000 then lat = lat - 0x1000000 end
            local lon = (bytes[i + 3] * 65536) + (bytes[i + 4] * 256) + (bytes[i + 5] or 0)
            if lon >= 0x800000 then lon = lon - 0x1000000 end
            local alt = ((bytes[i + 6] or 0) * 65536) + ((bytes[i + 7] or 0) * 256) + (bytes[i + 8] or 0)
            if alt >= 0x800000 then alt = alt - 0x1000000 end
            i = i + 9
            out.latitude = lat * 0.0001
            out.longitude = lon * 0.0001
            out.altitude = alt * 0.01
            count = count + 1
        else
            break
        end
    end
    return out, count
end

local function decode_ctv_payload(bytes, hex, data_offset)
    data_offset = data_offset or 4
    local best_out, best_cnt = parse_channels_at_offset(bytes, data_offset)
    local eff_offset = data_offset

    if best_cnt == 0 then
        for _, cand in ipairs({6, 4, 2, 0}) do
            local o, c = parse_channels_at_offset(bytes, cand)
            if c > best_cnt then
                best_out = o
                best_cnt = c
                eff_offset = cand
            end
        end
    end

    if #bytes >= 6 and eff_offset == 6 then
        best_out.node_id = string.format("%02X%02X", bytes[1] or 0, bytes[2] or 0)
        best_out.device_serial = string.format("%02X%02X%02X%02X", bytes[3] or 0, bytes[4] or 0, bytes[5] or 0, bytes[6] or 0)
        best_out.node_class = "A"
        best_out.capability = "Sensor"
    elseif #bytes >= 4 then
        best_out.node_id = string.format("%02X%02X", bytes[1] or 0, bytes[2] or 0)
        local dev_type = bytes[3] or 0
        best_out.device_type = string.format("0x%02X", dev_type)
        local class_code = math.floor(dev_type / 16)
        local cap_code = dev_type % 16
        if class_code == 1 then best_out.node_class = "A"
        elseif class_code == 2 then best_out.node_class = "B"
        elseif class_code == 3 then best_out.node_class = "C" end
        local cap_map = { [1] = "Sensor", [2] = "Actuator", [3] = "Combo", [4] = "Meter", [5] = "Security", [6] = "Dimmer" }
        best_out.capability = cap_map[cap_code] or "Generic"
        best_out.seq = bytes[4] or 0
    end

    return best_out
end

-- Visual Field Slicer Decoder
local function decode_fields_payload(bytes, fields)
    local out = {}
    for _, f in ipairs(fields or {}) do
        local off = (tonumber(f.offset) or 0) + 1
        local len = tonumber(f.length) or 1
        local ftype = f.type or "uint8"
        local scale = tonumber(f.scale) or 1.0
        local fname = f.name or ("field_" .. off)

        if off <= #bytes then
            local raw = 0
            if ftype == "uint8" then
                raw = bytes[off] or 0
            elseif ftype == "int8" then
                raw = bytes[off] or 0
                if raw >= 128 then raw = raw - 256 end
            elseif ftype == "uint16_be" then
                raw = ((bytes[off] or 0) * 256) + (bytes[off + 1] or 0)
            elseif ftype == "uint16_le" then
                raw = (bytes[off] or 0) + ((bytes[off + 1] or 0) * 256)
            elseif ftype == "int16_be" then
                raw = ((bytes[off] or 0) * 256) + (bytes[off + 1] or 0)
                if raw >= 32768 then raw = raw - 65536 end
            elseif ftype == "int16_le" then
                raw = (bytes[off] or 0) + ((bytes[off + 1] or 0) * 256)
                if raw >= 32768 then raw = raw - 65536 end
            elseif ftype == "hex" then
                local h = ""
                for j = 0, len - 1 do
                    if off + j <= #bytes then
                        h = h .. string.format("%02X", bytes[off + j])
                    end
                end
                out[fname] = h
            end
            if ftype ~= "hex" then
                out[fname] = raw * scale
                if fname == "temperature" or fname == "temp" then out.temperature = raw * scale; out.val = out.temperature end
                if fname == "battery" or fname == "volt" then out.battery = raw * scale end
                if fname == "seq" or fname == "counter" then out.seq = raw end
            end
        end
    end
    return out
end

-- Cayenne LPP Decoder
local function decode_cayenne_lpp(bytes, data_offset)
    local out = decode_ctv_payload(bytes, "", tonumber(data_offset) or 0)
    return out
end

-- Scheme Matching
local function match_scheme(scheme, bytes, hex)
    if not scheme or scheme.enabled == false then return false end
    local mtype = scheme.matchType or "default"
    local mval = tostring(scheme.matchValue or ""):lower():gsub("%s+", "")

    if mtype == "prefix" then
        if mval == "" then return false end
        return hex:lower():find("^" .. mval) ~= nil
    elseif mtype == "size" then
        local target = tonumber(mval)
        return target and (#bytes == target)
    elseif mtype == "regex" then
        if mval == "" then return false end
        local ok, res = pcall(function() return hex:match(mval) ~= nil end)
        return ok and res
    elseif mtype == "default" then
        return true
    end
    return false
end

-- Node ID Extraction
local function extract_node_id(bytes, hex, scheme, decoded, global_rule)
    local rule = (scheme and scheme.nodeId) or global_rule or {}
    local src = rule.source or "auto"
    local fmt = rule.format or "net_hex"
    local pfx = rule.prefix or ""

    -- 1. From Decoded Property
    if src == "field" or (src == "auto" and decoded) then
        if decoded then
            local cand = decoded[rule.fieldName or "node_id"] or decoded.node_id or
                         decoded.nodeId or decoded.sender_id or decoded.senderId or
                         decoded.id or decoded.dev_id or decoded.address
            if cand and tostring(cand):match("%S") then
                return pfx .. tostring(cand):upper()
            end
        end
    end

    -- 2. Presets: 4-Byte Serial (Bytes 2..5) & 6-Byte MAC (Bytes 0..5)
    if src == "serial_4b" and #bytes >= 6 then
        return pfx .. string.format("%02X%02X%02X%02X", bytes[3] or 0, bytes[4] or 0, bytes[5] or 0, bytes[6] or 0)
    end
    if src == "mac_6b" and #bytes >= 6 then
        return pfx .. string.format("%02X%02X%02X%02X%02X%02X", bytes[1] or 0, bytes[2] or 0, bytes[3] or 0, bytes[4] or 0, bytes[5] or 0, bytes[6] or 0)
    end

    -- 3. 2-Byte Node ID (Bytes 1..2: e.g. 12 34 -> "1234", AA 0C -> "AA0C")
    if src == "node_2b" or src == "node_id_2b" or src == "auto" then
        if #bytes >= 2 then
            local idHex = string.format("%02X%02X", bytes[1] or 0, bytes[2] or 0)
            if fmt == "decimal" then
                return pfx .. tostring(((bytes[1] or 0) * 256) + (bytes[2] or 0))
            end
            return pfx .. idHex
        elseif #bytes == 1 then
            local sHex = string.format("%02X", bytes[1] or 0)
            return pfx .. sHex
        end
    end

    -- 4. Custom Byte Offset & Length
    if src == "offset" then
        local off = tonumber(rule.offset) or 0
        local len = tonumber(rule.length) or 1
        local lua_off = off + 1
        if lua_off <= #bytes then
            local slice_len = math.min(len, #bytes - off)
            if fmt == "decimal" then
                local num = 0
                for j = 0, slice_len - 1 do
                    num = (num * 256) + (bytes[lua_off + j] or 0)
                end
                return pfx .. tostring(num)
            elseif fmt == "net_hex" and rule.netIdOffset ~= nil then
                local nOff = (tonumber(rule.netIdOffset) or 0) + 1
                local netByte = bytes[nOff] or 0
                local nHex = string.format("%02X", netByte)
                local sHex = ""
                for j = 0, slice_len - 1 do
                    sHex = sHex .. string.format("%02X", bytes[lua_off + j] or 0)
                end
                return pfx .. nHex .. sHex
            else
                local sHex = ""
                for j = 0, slice_len - 1 do
                    sHex = sHex .. string.format("%02X", bytes[lua_off + j] or 0)
                end
                return pfx .. sHex
            end
        end
    end

    -- 5. Header (First 2 Bytes)
    if src == "header" and #bytes >= 2 then
        return pfx .. hex:sub(1, 4):upper()
    end

    -- 6. Single Byte (Offset 0)
    if src == "single" and #bytes >= 1 then
        if fmt == "decimal" then
            return pfx .. tostring(bytes[1] or 0)
        end
        return pfx .. string.format("%02X", bytes[1] or 0)
    end

    -- 7. DevAddr (4 Bytes at Offset 1)
    if src == "devaddr" and #bytes >= 5 then
        return pfx .. hex:sub(3, 10):upper()
    end

    -- 8. Fallback: first 4 hex chars
    if #hex >= 4 then
        return pfx .. hex:sub(1, 4):upper()
    end
    return pfx .. hex:upper()
end

-- Primary Telemetry & Payload Metric Extraction
local function extract_metrics(hex, raw_b64)
    local metrics = {}
    if not hex or hex == "" then return metrics end

    hex = hex:lower()
    local bytes = hex_to_bytes(hex)
    local cfg = get_decoders_config()
    local schemes = cfg.schemes or {}
    local global_rule = cfg.globalNodeId or { source = "auto", format = "net_hex" }

    local matched_scheme = nil
    for _, s in ipairs(schemes) do
        if match_scheme(s, bytes, hex) then
            matched_scheme = s
            break
        end
    end

    -- Execute Scheme Decoder
    if matched_scheme then
        local stype = matched_scheme.type or "ctv"
        if stype == "ctv" or stype == "tlv" then
            metrics = decode_ctv_payload(bytes, hex, tonumber(matched_scheme.dataOffset) or 4)
        elseif stype == "fields" then
            metrics = decode_fields_payload(bytes, matched_scheme.fields)
        elseif stype == "cayenne_lpp" then
            metrics = decode_cayenne_lpp(bytes, matched_scheme.dataOffset) or {}
        end
    end

    -- Fallback: If no metrics parsed yet, try intelligent auto-decoders
    if not metrics.temperature and not metrics.battery and not metrics.state then
        if #bytes >= 4 and bytes[1] ~= 0xAA then
            -- Modern format: 2-byte Node ID + 1-byte Device Type + 1-byte Seq + CTV
            local auto_metrics = decode_ctv_payload(bytes, hex, 4)
            for k, v in pairs(auto_metrics) do metrics[k] = v end
        elseif #bytes >= 4 and bytes[1] == 0xAA then
            -- Legacy format: NetID 0xAA + SenderID + TargetID + Seq + CTV
            local auto_metrics = decode_ctv_payload(bytes, hex, 4)
            for k, v in pairs(auto_metrics) do metrics[k] = v end
        end
    end

    -- Extract Node ID based on scheme's rule or global rule
    local node_id = extract_node_id(bytes, hex, matched_scheme, metrics, global_rule)
    metrics.node_id = node_id

    return metrics
end

-- ==============================================================================
-- Radio Channel LBT & Downlinks
-- ==============================================================================

local function lbt_check_channel(threshold_dbm, max_retries, backoff_ms)
    threshold_dbm = threshold_dbm or -85
    max_retries   = max_retries or 3
    backoff_ms    = backoff_ms or 50

    for attempt = 1, max_retries do
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

        if current_rssi < threshold_dbm then
            return true, current_rssi, "CLEAR"
        end

        local sleep_time = (backoff_ms + math.random(10, 40)) / 1000.0
        nixio.nanosleep(math.floor(sleep_time), math.floor((sleep_time % 1) * 1e9))
    end

    return false, threshold_dbm, "BUSY_RETRIED"
end

local function send_downlink_udp(pkt_table)
    local sock = nixio.socket("inet", "dgram")
    if not sock then return false, "socket_failed" end

    local payload_str = jsonc.stringify(pkt_table)
    local ok, err = sock:sendto(payload_str, "127.0.0.1", PORT_DOWN)
    sock:close()
    return (ok ~= nil), err
end

local function evaluate_condition(val, op, threshold)
    if val == nil then return false end
    if op == ">" then return val > threshold end
    if op == "<" then return val < threshold end
    if op == ">=" then return val >= threshold end
    if op == "<=" then return val <= threshold end
    if op == "==" then return math.abs(val - threshold) < 0.001 end
    if op == "!=" then return math.abs(val - threshold) >= 0.001 end
    if op == "always" then return true end
    return false
end

-- Process Pending Class A / B Downlinks
local function handle_class_a_downlink(node_id, uplink_tmst, uplink_freq, uplink_datr)
    local stmt = db_ram:prepare("SELECT id, payload FROM pending_downlinks WHERE target_node = ? AND status = 'QUEUED' ORDER BY id ASC LIMIT 1;")
    if not stmt then return end
    stmt:bind_values(node_id)

    if stmt:step() == sqlite3.ROW then
        local dl_id = stmt:get_value(0)
        local raw_payload = stmt:get_value(1) or ""
        stmt:finalize()

        local rx1_delay = 1000
        local tx_powe = 14
        local n_stmt = db_nodes:prepare("SELECT rx1_delay_ms, default_tx_power FROM node_settings WHERE node_id = ?;")
        if n_stmt then
            n_stmt:bind_values(node_id)
            if n_stmt:step() == sqlite3.ROW then
                rx1_delay = n_stmt:get_value(0) or 1000
                tx_powe = n_stmt:get_value(1) or 14
            end
            n_stmt:finalize()
        end

        local count_us = uplink_tmst + (rx1_delay * 1000)
        local is_hex = (raw_payload:match("^%x+$") and #raw_payload % 2 == 0)
        local raw_bin = is_hex and hex_to_bin(raw_payload) or raw_payload
        local b64_payload = base64_encode(raw_bin)

        local is_clear, rssi = lbt_check_channel(-85, 2, 20)
        local dl_pkt = {
            imme = false,
            tmst = count_us,
            freq = uplink_freq or 868.1,
            rfch = 0,
            powe = tx_powe,
            modu = "LORA",
            datr = uplink_datr or "SF7BW125",
            codr = "4/5",
            ipol = false,
            size = #raw_payload,
            data = b64_payload
        }

        local ok, err = send_downlink_udp(dl_pkt)
        local tx_status = ok and "SENT_RX1" or ("ERR_" .. (err or "UDP"))

        db_ram:exec(string.format("UPDATE pending_downlinks SET status = '%s', sent_at = CURRENT_TIMESTAMP WHERE id = %d;", tx_status, dl_id))
        db_ram:exec(string.format(
            "INSERT INTO link_execution_logs (link_id, event_type, target_node, target_class, tx_status, details) " ..
            "VALUES (0, 'CLASS_A_DISPATCH', '%s', 'A', '%s', 'Dispatched at tmst=%u (delay=%dms, LBT=%.1fdBm)');",
            node_id, tx_status, count_us, rx1_delay, rssi
        ))
    else
        stmt:finalize()
    end
end

-- Process Edge Linking Rules
local function process_links(node_id, metrics, uplink_tmst)
    local stmt = db_nodes:prepare([[
        SELECT l.*, n.node_class AS target_class, n.default_tx_power, n.rx1_delay_ms
        FROM node_links l
        LEFT JOIN node_settings n ON l.target_node = n.node_id
        WHERE l.source_node = ? AND l.enabled = 1;
    ]])
    if not stmt then return end

    stmt:bind_values(node_id)

    while stmt:step() == sqlite3.ROW do
        local link = {
            link_id          = stmt:get_value(0),
            name             = stmt:get_value(1),
            source_metric    = stmt:get_value(3),
            condition_op     = stmt:get_value(4),
            threshold_val    = stmt:get_value(5),
            target_node      = stmt:get_value(6),
            action_type      = stmt:get_value(7),
            action_payload   = stmt:get_value(8),
            delay_ms         = stmt:get_value(9) or 0,
            auto_reset_sec   = stmt:get_value(10) or 0,
            reset_payload    = stmt:get_value(11),
            cooldown_sec     = stmt:get_value(12) or 0,
            target_class     = stmt:get_value(16) or "C",
            default_tx_power = stmt:get_value(17) or 14,
            rx1_delay_ms     = stmt:get_value(18) or 1000
        }

        local val = metrics[link.source_metric] or metrics.val
        if evaluate_condition(val, link.condition_op, link.threshold_val) then
            local in_cooldown = false
            local log_stmt = db_ram:prepare("SELECT strftime('%s', 'now') - strftime('%s', timestamp) FROM link_execution_logs WHERE link_id = ? ORDER BY id DESC LIMIT 1;")
            if log_stmt then
                log_stmt:bind_values(link.link_id)
                if log_stmt:step() == sqlite3.ROW then
                    local elapsed = log_stmt:get_value(0) or 9999
                    if elapsed < link.cooldown_sec then
                        in_cooldown = true
                    end
                end
                log_stmt:finalize()
            end

            if not in_cooldown then
                local target_node = link.target_node
                local target_class = link.target_class or "C"

                if target_class == "C" then
                    if link.delay_ms > 0 then
                        nixio.nanosleep(math.floor(link.delay_ms / 1000), (link.delay_ms % 1000) * 1e6)
                    end

                    local is_clear, rssi = lbt_check_channel(-85, 3, 50)
                    local is_hex = (link.action_payload:match("^%x+$") and #link.action_payload % 2 == 0)
                    local raw_bin = is_hex and hex_to_bin(link.action_payload) or link.action_payload
                    local b64 = base64_encode(raw_bin)

                    local dl_pkt = {
                        imme = true,
                        freq = 868.1,
                        rfch = 0,
                        powe = link.default_tx_power or 14,
                        modu = "LORA",
                        datr = "SF7BW125",
                        codr = "4/5",
                        ipol = false,
                        size = #link.action_payload,
                        data = b64
                    }

                    local ok, err = send_downlink_udp(dl_pkt)
                    local tx_status = ok and "SENT_IMME" or ("ERR_" .. (err or "UDP"))

                    db_ram:exec(string.format(
                        "INSERT INTO link_execution_logs (link_id, event_type, source_node, target_node, target_class, trigger_value, tx_status, details) " ..
                        "VALUES (%d, 'AUTO_TRIGGER', '%s', '%s', 'C', %.2f, '%s', 'Immediate Class C Downlink (LBT=%.1fdBm)');",
                        link.link_id, node_id, target_node, val or 0.0, tx_status, rssi
                    ))

                    db_nodes:exec(string.format(
                        "UPDATE node_links SET last_triggered = CURRENT_TIMESTAMP, last_status = '%s' WHERE link_id = %d;",
                        tx_status, link.link_id
                    ))
                else
                    db_ram:exec(string.format(
                        "INSERT INTO pending_downlinks (target_node, target_class, payload, status) " ..
                        "VALUES ('%s', 'A', '%s', 'QUEUED');",
                        target_node, link.action_payload
                    ))

                    db_ram:exec(string.format(
                        "INSERT INTO link_execution_logs (link_id, event_type, source_node, target_node, target_class, tx_status, details) " ..
                        "VALUES (%d, 'AUTO_TRIGGER', '%s', '%s', 'A', 'QUEUED', 'Queued for next RX1 window of %s');",
                        link.link_id, node_id, target_node, target_node
                    ))

                    db_nodes:exec(string.format(
                        "UPDATE node_links SET last_triggered = CURRENT_TIMESTAMP, last_status = 'QUEUED' WHERE link_id = %d;",
                        link.link_id
                    ))
                end
            end
        end
    end
    stmt:finalize()
end

-- Ingest New Packet into SQLite
local function ingest_packet(pkt)
    if not pkt or not pkt.hex or pkt.status == "CRC_ERR" then return end

    local metrics = extract_metrics(pkt.hex, pkt.b64)
    local node_id = metrics.node_id or "UNKNOWN"
    local decoded_json = jsonc.stringify(metrics)

    -- 1. Insert into rolling 50 messages table in RAM
    local ins_stmt = db_ram:prepare(
        "INSERT INTO node_messages (node_id, rssi, snr, freq_hz, sf, payload_raw, payload_decoded, tmst) " ..
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
    )
    if ins_stmt then
        ins_stmt:bind_values(
            node_id,
            tonumber(pkt.rssi) or -100.0,
            tonumber(pkt.snr) or 0.0,
            math.floor((tonumber(pkt.freq) or 868.1) * 1e6),
            tonumber((pkt.datr or ""):match("SF(%d+)")) or 7,
            pkt.hex,
            decoded_json,
            tonumber(pkt.tmst) or 0
        )
        ins_stmt:step()
        ins_stmt:finalize()
    end

    -- 2. Update persistent node registry on Flash (Auto-Discovery)
    -- Newly discovered nodes default to ha_enabled = 0 and is_configured = 0 until adopted & categorized by user
    local detected_class = metrics.node_class or "A"
    local detected_model = metrics.capability and ("LoRa " .. metrics.capability) or nil
    db_nodes:exec(string.format(
        "INSERT OR IGNORE INTO node_settings (node_id, name, node_class, is_configured, group_name, ha_enabled) VALUES ('%s', 'Node %s', '%s', 0, 'Unassigned', 0);",
        node_id, node_id, detected_class
    ))
    if metrics.node_class then
        db_nodes:exec(string.format(
            "UPDATE node_settings SET node_class = '%s' WHERE node_id = '%s' AND is_configured = 0;",
            metrics.node_class, node_id
        ))
    end
    if detected_model then
        db_nodes:exec(string.format(
            "UPDATE node_settings SET model = '%s' WHERE node_id = '%s' AND (model IS NULL OR model = '' OR model = 'generic');",
            detected_model, node_id
        ))
    end
    db_nodes:exec(string.format(
        "UPDATE node_settings SET last_seen = CURRENT_TIMESTAMP, last_rssi = %.1f, last_snr = %.1f WHERE node_id = '%s';",
        tonumber(pkt.rssi) or -100.0, tonumber(pkt.snr) or 0.0, node_id
    ))

    -- 2.1 Publish Live Telemetry to MQTT for Home Assistant (only for adopted & categorized nodes)
    local should_pub = false
    local n_stmt = db_nodes:prepare("SELECT ha_enabled, is_configured, group_name FROM node_settings WHERE node_id = ?;")
    if n_stmt then
        n_stmt:bind_values(node_id)
        if n_stmt:step() == sqlite3.ROW then
            local ha_en = n_stmt:get_value(0) or 0
            local is_cfg = n_stmt:get_value(1) or 0
            local grp = n_stmt:get_value(2) or "Unassigned"
            if ha_en == 1 and is_cfg == 1 and grp ~= "Unassigned" and grp ~= "Uncategorized" and grp ~= "" then
                should_pub = true
            end
        end
        n_stmt:finalize()
    end

    if should_pub then
        metrics.rssi      = tonumber(pkt.rssi)
        metrics.snr       = tonumber(pkt.snr)
        metrics.freq      = tonumber(pkt.freq)
        metrics.datr      = pkt.datr
        metrics.hex       = pkt.hex
        metrics.size      = tonumber(pkt.size)
        metrics.last_seen = os.date("!%Y-%m-%dT%H:%M:%SZ")
        publish_mqtt_telemetry(node_id, metrics)
    end

    -- 3. Check for pending Class A downlinks
    if pkt.tmst then
        handle_class_a_downlink(node_id, tonumber(pkt.tmst), pkt.freq, pkt.datr)
    end

    -- 4. Process Linking Rules
    process_links(node_id, metrics, tonumber(pkt.tmst))
end

-- ==============================================================================
-- Main Engine Supervisor Loop
-- ==============================================================================
print("[ENGINE] LoRa Linking & Multi-Scheme Decoder Engine running...")

local last_processed_tmst = 0

while true do
    local f = io.open(PACKETS_JSON, "r")
    if f then
        local raw = f:read("*a")
        f:close()
        local list = raw and jsonc.parse(raw)
        if list and #list > 0 then
            local latest = list[1]
            local tmst = tonumber(latest.tmst) or 0
            if tmst ~= last_processed_tmst then
                last_processed_tmst = tmst
                ingest_packet(latest)
            end
        end
    end
    nixio.nanosleep(0, 500000000) -- Sleep 500ms
end
