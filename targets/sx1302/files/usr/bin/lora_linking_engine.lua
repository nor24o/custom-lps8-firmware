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
        "mosquitto_pub -h %s -p %d %s -t %s -m %s 2>/dev/null &",
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

-- Channel-Type-Value (CTV / TLV) Decoder:
-- Parses packets such as: AA 0C 64 00 01 11 09 C4 02 05 0C E4
local function decode_ctv_payload(bytes, hex, data_offset)
    data_offset = data_offset or 4
    local out = {}

    if #bytes >= 4 then
        out.net_id    = string.format("0x%02X", bytes[1] or 0)
        out.sender_id = bytes[2] or 0
        out.target_id = bytes[3] or 0
        out.seq       = bytes[4] or 0
    end

    local i = data_offset + 1
    while i <= #bytes do
        local ch = bytes[i]
        i = i + 1
        if i > #bytes then break end
        local type_code = bytes[i]
        i = i + 1

        if type_code == 0x11 then
            -- 2-byte Generic Integer / Temperature
            if i + 1 > #bytes then break end
            local raw = (bytes[i] * 256) + bytes[i + 1]
            i = i + 2
            if raw >= 0x8000 then raw = raw - 0x10000 end
            local temp = (math.abs(raw) > 500) and (raw / 100.0) or (raw / 10.0)
            out.temperature = temp
            out["ch" .. ch .. "_val"] = raw
            out.val = temp
        elseif type_code == 0x05 then
            -- 2-byte Battery in mV
            if i + 1 > #bytes then break end
            local mv = (bytes[i] * 256) + bytes[i + 1]
            i = i + 2
            out.battery = mv / 1000.0
            out.battery_mv = mv
        elseif type_code == 0x01 or type_code == 0x10 then
            -- 1-byte Digital / Switch State
            if i > #bytes then break end
            local val = bytes[i]
            i = i + 1
            out["ch" .. ch .. "_state"] = (val == 1) and "ON" or "OFF"
            out.state = (val == 1) and "ON" or "OFF"
        elseif type_code == 0x02 or type_code == 0x12 then
            -- 2-byte Analog Input
            if i + 1 > #bytes then break end
            local raw = (bytes[i] * 256) + bytes[i + 1]
            i = i + 2
            if raw >= 0x8000 then raw = raw - 0x10000 end
            out["ch" .. ch .. "_analog"] = raw / 100.0
        elseif type_code == 0x67 then
            -- Cayenne Temperature (0.1 °C signed)
            if i + 1 > #bytes then break end
            local raw = (bytes[i] * 256) + bytes[i + 1]
            i = i + 2
            if raw >= 0x8000 then raw = raw - 0x10000 end
            out.temperature = raw / 10.0
            out.val = out.temperature
        elseif type_code == 0x68 then
            -- Cayenne Humidity (0.5 %)
            if i > #bytes then break end
            out.humidity = bytes[i] * 0.5
            i = i + 1
        else
            break
        end
    end

    return out
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
local function decode_cayenne_lpp(bytes)
    local out = {}
    local i = 1
    local parsed = false
    while i <= #bytes do
        local ch = bytes[i]
        i = i + 1
        if i > #bytes then break end
        local type_code = bytes[i]
        i = i + 1

        if type_code == 0x00 then -- Digital In (1B)
            if i > #bytes then break end
            out["ch" .. ch .. "_digital_in"] = bytes[i]
            i = i + 1
            parsed = true
        elseif type_code == 0x01 then -- Digital Out (1B)
            if i > #bytes then break end
            out["ch" .. ch .. "_digital_out"] = bytes[i]
            i = i + 1
            parsed = true
        elseif type_code == 0x02 then -- Analog In (2B)
            if i + 1 > #bytes then break end
            local val = (bytes[i] * 256) + bytes[i + 1]
            i = i + 2
            if val >= 32768 then val = val - 65536 end
            out["ch" .. ch .. "_analog_in"] = val * 0.01
            parsed = true
        elseif type_code == 0x67 then -- Temp (2B, 0.1°C signed)
            if i + 1 > #bytes then break end
            local val = (bytes[i] * 256) + bytes[i + 1]
            i = i + 2
            if val >= 32768 then val = val - 65536 end
            out.temperature = val * 0.1
            out.val = out.temperature
            parsed = true
        elseif type_code == 0x68 then -- Humidity (1B, 0.5%)
            if i > #bytes then break end
            out.humidity = bytes[i] * 0.5
            i = i + 1
            parsed = true
        else
            break
        end
    end
    return parsed and out or nil
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
            local cand = decoded[rule.fieldName or "senderId"] or decoded.sender_id or
                         decoded.node_id or decoded.id or decoded.dev_id or decoded.address
            if cand and tostring(cand):match("%S") then
                return pfx .. tostring(cand):upper()
            end
        end
    end

    -- 2. NetID + SenderID (Byte 0 = NetID 0xAA, Byte 1 = SenderID)
    if src == "net_sender" or (src == "auto" and #bytes >= 2 and bytes[1] == 0xAA) then
        local netHex = string.format("%02X", bytes[1] or 0)
        local senderHex = string.format("%02X", bytes[2] or 0)
        if fmt == "decimal" then
            return pfx .. tostring(bytes[2] or 0)
        elseif fmt == "sender_only" or src == "sender_only" or rule.senderOnly then
            return pfx .. senderHex
        end
        return pfx .. netHex .. senderHex
    end

    -- 3. SenderID Only (Byte 1)
    if src == "sender_only" and #bytes >= 2 then
        local sHex = string.format("%02X", bytes[2] or 0)
        if fmt == "decimal" then
            return pfx .. tostring(bytes[2] or 0)
        end
        return pfx .. sHex
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
            metrics = decode_cayenne_lpp(bytes) or {}
        end
    end

    -- Fallback: If no metrics parsed yet, try intelligent auto-decoders
    if not metrics.temperature and not metrics.battery then
        if #bytes >= 4 and bytes[1] == 0xAA then
            -- Packet begins with NetID 0xAA: decode Channel-Type-Value sensors
            local auto_metrics = decode_ctv_payload(bytes, hex, 4)
            for k, v in pairs(auto_metrics) do metrics[k] = v end
        elseif #bytes >= 8 then
            -- Legacy fixed 8-byte format: [0..1: ID, 2..3: SEQ, 4..5: TEMP, 6..7: VOLT]
            metrics.seq = (bytes[3] * 256) + bytes[4]
            metrics.temperature = ((bytes[5] * 256) + bytes[6]) / 10.0
            metrics.battery = ((bytes[7] * 256) + bytes[8]) / 1000.0
            metrics.val = metrics.temperature
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
    db_nodes:exec(string.format(
        "INSERT OR IGNORE INTO node_settings (node_id, name, node_class, is_configured, group_name) VALUES ('%s', 'New Node %s', 'A', 0, 'Unassigned');",
        node_id, node_id
    ))
    db_nodes:exec(string.format(
        "UPDATE node_settings SET last_seen = CURRENT_TIMESTAMP, last_rssi = %.1f, last_snr = %.1f WHERE node_id = '%s';",
        tonumber(pkt.rssi) or -100.0, tonumber(pkt.snr) or 0.0, node_id
    ))

    -- 2.1 Publish Live Telemetry to MQTT for Home Assistant
    metrics.rssi = tonumber(pkt.rssi)
    metrics.snr  = tonumber(pkt.snr)
    metrics.freq = tonumber(pkt.freq)
    publish_mqtt_telemetry(node_id, metrics)

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
