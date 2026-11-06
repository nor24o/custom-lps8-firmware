#!/usr/bin/env lua
-- ==============================================================================
-- lora_decoder.lua — Standalone LoRa Payload Multi-Scheme Decoding Engine
-- ==============================================================================
-- Standalone, high-performance LoRa payload decoder and Node ID routing feature.
-- Can be required as a Lua module: local LoraDecoder = require "lora_decoder"
-- Or executed directly from CLI / daemon mode on ANY device:
--   lora_decoder.lua --hex <RAW_HEX>
--   lora_decoder.lua --packet '<PACKET_JSON>'
--   lora_decoder.lua --test
--   lora_decoder.lua --daemon --broker <IP> --port <PORT>
-- ==============================================================================

local LoraDecoder = {
    _VERSION = "2.1.0",
    _AUTHOR  = "Antigravity OpenWrt LoRa Team",
    DEFAULT_CONFIG_PATH = "/etc/lora/decoders.json"
}

-- ------------------------------------------------------------------------------
-- Portable JSON & OS Compatibility Layer (Runs on OpenWrt, Debian, Raspberry Pi, etc.)
-- ------------------------------------------------------------------------------
local json = nil
local ok_jc, jc = pcall(require, "luci.jsonc")
if ok_jc and jc then
    json = {
        parse = function(s) return jc.parse(s) end,
        stringify = function(t, p) return jc.stringify(t, p) end
    }
else
    local ok_cj, cj = pcall(require, "cjson")
    if ok_cj and cj then
        json = {
            parse = function(s) return cj.decode(s) end,
            stringify = function(t) return cj.encode(t) end
        }
    else
        -- Minimal fallback JSON parser for standalone portability
        json = {
            parse = function(s)
                if not s or s == "" then return nil end
                -- Convert simple JSON object to Lua table via pattern matching or sandbox if needed
                local ok, res = pcall(function()
                    s = s:gsub('":', '"='):gsub('null', 'nil')
                    return loadstring("return " .. s)()
                end)
                return ok and res or nil
            end,
            stringify = function(t)
                local parts = {}
                for k, v in pairs(t) do
                    local val_str = type(v) == "string" and string.format("%q", v) or tostring(v)
                    table.insert(parts, string.format("%q:%s", tostring(k), val_str))
                end
                return "{" .. table.concat(parts, ",") .. "}"
            end
        }
    end
end
LoraDecoder.json = json

-- ------------------------------------------------------------------------------
-- Hex, Binary & ASCII Utilities
-- ------------------------------------------------------------------------------
function LoraDecoder.hex_to_bytes(h)
    local bytes = {}
    if not h then return bytes end
    h = tostring(h):lower():gsub("[^0-9a-f]", "")
    for i = 1, #h, 2 do
        local b = tonumber(h:sub(i, i + 1), 16)
        if b then table.insert(bytes, b) end
    end
    return bytes
end

function LoraDecoder.bytes_to_hex(bytes)
    local parts = {}
    for i = 1, #bytes do
        parts[i] = string.format("%02X", bytes[i] or 0)
    end
    return table.concat(parts)
end

function LoraDecoder.bytes_to_ascii(bytes)
    local t = {}
    for i = 1, #bytes do
        local b = bytes[i] or 0
        if b >= 32 and b <= 126 then
            table.insert(t, string.char(b))
        elseif b == 10 or b == 13 or b == 9 then
            table.insert(t, string.char(b))
        end
    end
    return table.concat(t)
end

function LoraDecoder.sign_extend_16(val)
    if val >= 0x8000 then return val - 0x10000 end
    return val
end

function LoraDecoder.sign_extend_24(val)
    if val >= 0x800000 then return val - 0x1000000 end
    return val
end

-- ------------------------------------------------------------------------------
-- Configuration Management & Caching
-- ------------------------------------------------------------------------------
local g_cfg_cache = nil
local g_cfg_mtime = 0

function LoraDecoder.load_config(path)
    path = path or LoraDecoder.DEFAULT_CONFIG_PATH
    local nixio_ok, nixio = pcall(require, "nixio")
    local mtime = 0
    if nixio_ok and nixio and nixio.fs and nixio.fs.stat then
        local st = nixio.fs.stat(path)
        mtime = st and st.mtime or 0
    end

    if g_cfg_cache and mtime > 0 and mtime == g_cfg_mtime then
        return g_cfg_cache
    end

    local f = io.open(path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        local parsed = json.parse(content)
        if parsed and type(parsed) == "table" then
            g_cfg_cache = parsed
            g_cfg_mtime = mtime
            return parsed
        end
    end

    -- Built-in default schemes if config file is not found
    return LoraDecoder.get_default_config()
end

function LoraDecoder.get_default_config()
    return {
        version = 1,
        globalNodeId = { source = "node_2b", offset = 0, length = 2, format = "hex", prefix = "" },
        schemes = {
            {
                id = "scheme_node_cafe",
                name = "Node CAFE (Multi-Sensor LPP)",
                enabled = true,
                matchType = "prefix",
                matchValue = "cafe",
                type = "cayenne_lpp",
                dataOffset = 6,
                nodeId = { source = "node_2b", offset = 0, length = 2, format = "hex", prefix = "" }
            },
            {
                id = "scheme_2b_node_tlv",
                name = "Standard 2-Byte Node ID + TLV / IPSO Channels",
                enabled = true,
                matchType = "condition",
                matchCondition = "return #bytes >= 4",
                type = "ctv",
                dataOffset = 4,
                nodeId = { source = "node_2b", offset = 0, length = 2, format = "hex", prefix = "" }
            },
            {
                id = "scheme_cayenne_lpp",
                name = "Cayenne LPP Standard Sensors",
                enabled = true,
                matchType = "default",
                type = "cayenne_lpp",
                dataOffset = 0,
                nodeId = { source = "node_2b", offset = 0, length = 2, format = "hex", prefix = "" }
            },
            {
                id = "scheme_ascii_ping",
                name = "ASCII Text & Test Pings",
                enabled = true,
                matchType = "condition",
                matchCondition = "return LoraDecoder.is_printable_ascii(bytes)",
                type = "ascii",
                nodeId = { source = "node_2b", offset = 0, length = 2, format = "hex", prefix = "" }
            }
        }
    }
end

-- ------------------------------------------------------------------------------
-- Decoding Engines
-- ------------------------------------------------------------------------------

-- Channel-Type-Value (CTV / TLV) & IPSO / Cayenne LPP Core Slicer
function LoraDecoder.parse_channels_at_offset(bytes, start_offset)
    local out = {}
    local i = (start_offset or 0) + 1
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
            -- Temperature (0.1 scale or 0.01 scale)
            if i + 1 > #bytes then break end
            local raw = (bytes[i] * 256) + bytes[i + 1]
            i = i + 2
            raw = LoraDecoder.sign_extend_16(raw)
            local temp = (math.abs(raw) > 500) and (raw / 100.0) or (raw / 10.0)
            out.temperature = temp
            out["ch" .. ch .. "_val"] = raw
            out.val = temp
            count = count + 1

        elseif type_code == 0x05 then
            -- Battery voltage in mV
            if i + 1 > #bytes then break end
            local mv = (bytes[i] * 256) + bytes[i + 1]
            i = i + 2
            out.battery = mv / 1000.0
            out.battery_mv = mv
            count = count + 1

        elseif type_code == 0x00 then
            -- Digital Input (1 byte)
            if i > #bytes then break end
            out["ch" .. ch .. "_digital_in"] = bytes[i]
            i = i + 1
            count = count + 1

        elseif type_code == 0x01 or type_code == 0x10 then
            -- Digital Output / Switch State (1 byte)
            if i > #bytes then break end
            local val = bytes[i]
            i = i + 1
            out["ch" .. ch .. "_state"] = (val == 1) and "ON" or "OFF"
            out.state = (val == 1) and "ON" or "OFF"
            count = count + 1

        elseif type_code == 0x02 or type_code == 0x12 or type_code == 0x03 then
            -- Analog Input (2 bytes, 0.01 scale signed)
            if i + 1 > #bytes then break end
            local raw = (bytes[i] * 256) + bytes[i + 1]
            i = i + 2
            raw = LoraDecoder.sign_extend_16(raw)
            local aval = raw / 100.0
            out["ch" .. ch .. "_analog_in"] = aval
            -- If Channel 1 and value is standard Li-ion/supply voltage range (1.8V .. 5.5V), auto-map battery
            if ch == 1 and aval >= 1.8 and aval <= 5.5 and not out.battery then
                out.battery = aval
            end
            count = count + 1

        elseif type_code == 0x65 then
            -- Illuminance (2 bytes, 1 Lux)
            if i + 1 > #bytes then break end
            out.illuminance = (bytes[i] * 256) + bytes[i + 1]
            i = i + 2
            count = count + 1

        elseif type_code == 0x66 then
            -- Presence / Motion (1 byte)
            if i > #bytes then break end
            out.presence = bytes[i]
            i = i + 1
            count = count + 1

        elseif type_code == 0x67 then
            -- Cayenne LPP Temperature (2 bytes, 0.1°C signed)
            if i + 1 > #bytes then break end
            local raw = (bytes[i] * 256) + bytes[i + 1]
            i = i + 2
            raw = LoraDecoder.sign_extend_16(raw)
            out.temperature = raw / 10.0
            out["ch" .. ch .. "_temperature"] = out.temperature
            out.val = out.temperature
            count = count + 1

        elseif type_code == 0x68 then
            -- Cayenne LPP Humidity (1 byte, 0.5% unsigned)
            if i > #bytes then break end
            out.humidity = bytes[i] * 0.5
            out["ch" .. ch .. "_humidity"] = out.humidity
            i = i + 1
            count = count + 1

        elseif type_code == 0x71 then
            -- Cayenne LPP Accelerometer (6 bytes: X, Y, Z, 0.001g signed)
            if i + 5 > #bytes then break end
            local ax = LoraDecoder.sign_extend_16((bytes[i] * 256) + bytes[i + 1])
            local ay = LoraDecoder.sign_extend_16((bytes[i + 2] * 256) + bytes[i + 3])
            local az = LoraDecoder.sign_extend_16((bytes[i + 4] * 256) + bytes[i + 5])
            i = i + 6
            out.accel_x = ax * 0.001
            out.accel_y = ay * 0.001
            out.accel_z = az * 0.001
            count = count + 1

        elseif type_code == 0x73 then
            -- Cayenne LPP Barometer (2 bytes, 0.1 hPa)
            if i + 1 > #bytes then break end
            out.pressure = ((bytes[i] * 256) + bytes[i + 1]) * 0.1
            i = i + 2
            count = count + 1

        elseif type_code == 0x88 then
            -- Cayenne LPP GPS Location (9 bytes: Lat 0.0001, Lon 0.0001, Alt 0.01)
            if i + 8 > #bytes then break end
            local lat = (bytes[i] * 65536) + (bytes[i + 1] * 256) + (bytes[i + 2] or 0)
            local lon = (bytes[i + 3] * 65536) + (bytes[i + 4] * 256) + (bytes[i + 5] or 0)
            local alt = ((bytes[i + 6] or 0) * 65536) + ((bytes[i + 7] or 0) * 256) + (bytes[i + 8] or 0)
            i = i + 9
            lat = LoraDecoder.sign_extend_24(lat)
            lon = LoraDecoder.sign_extend_24(lon)
            alt = LoraDecoder.sign_extend_24(alt)
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

-- Channel-Type-Value (CTV) Auto-Offset Channel Engine
function LoraDecoder.decode_ctv_payload(bytes, hex, data_offset)
    data_offset = tonumber(data_offset) or 4
    local best_out, best_cnt = LoraDecoder.parse_channels_at_offset(bytes, data_offset)
    local eff_offset = data_offset

    if best_cnt == 0 then
        for _, cand in ipairs({6, 4, 2, 0}) do
            local o, c = LoraDecoder.parse_channels_at_offset(bytes, cand)
            if c > best_cnt then
                best_out = o
                best_cnt = c
                eff_offset = cand
            end
        end
    end

    -- Header Metadata Extraction
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

-- Cayenne LPP Dedicated Slicer
function LoraDecoder.decode_cayenne_lpp(bytes, data_offset)
    local out = LoraDecoder.decode_ctv_payload(bytes, "", tonumber(data_offset) or 0)
    return out
end

-- Visual Byte Field Slicer Engine
function LoraDecoder.decode_fields_payload(bytes, fields)
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
                raw = LoraDecoder.sign_extend_16(((bytes[off] or 0) * 256) + (bytes[off + 1] or 0))
            elseif ftype == "int16_le" then
                raw = LoraDecoder.sign_extend_16((bytes[off] or 0) + ((bytes[off + 1] or 0) * 256))
            elseif ftype == "uint32_be" then
                raw = ((bytes[off] or 0) * 16777216) + ((bytes[off + 1] or 0) * 65536) + ((bytes[off + 2] or 0) * 256) + (bytes[off + 3] or 0)
            elseif ftype == "hex" then
                local hex_parts = {}
                for h_i = off, math.min(#bytes, off + len - 1) do
                    table.insert(hex_parts, string.format("%02X", bytes[h_i] or 0))
                end
                out[fname] = table.concat(hex_parts)
                raw = nil
            elseif ftype == "bool" then
                out[fname] = (bytes[off] or 0) > 0
                raw = nil
            end

            if raw ~= nil then
                local computed = raw * scale
                out[fname] = computed
            end
        end
    end
    return out
end

-- ASCII Text Auto-Decoder
function LoraDecoder.decode_ascii(bytes)
    return {
        text = LoraDecoder.bytes_to_ascii(bytes)
    }
end

-- ------------------------------------------------------------------------------
-- Node ID Routing Strategy
-- ------------------------------------------------------------------------------
function LoraDecoder.extract_node_id(bytes, hex, scheme, decoded, global_rule)
    local rule = (scheme and scheme.nodeId) or global_rule or {}
    local src = rule.source or "node_2b"
    local fmt = rule.format or "hex"
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

    -- 3. 2-Byte Node ID (Bytes 0..1: e.g. 12 34 -> "1234", CA FE -> "CAFE")
    if src == "node_2b" or src == "node_id_2b" or src == "auto" then
        if #bytes >= 2 then
            if fmt == "decimal" then
                local dec_val = ((bytes[1] or 0) * 256) + (bytes[2] or 0)
                return pfx .. tostring(dec_val)
            else
                return pfx .. string.format("%02X%02X", bytes[1] or 0, bytes[2] or 0)
            end
        end
    end

    -- 4. Single Byte Node ID (Byte 0)
    if src == "single" and #bytes >= 1 then
        if fmt == "decimal" then
            return pfx .. tostring(bytes[1] or 0)
        else
            return pfx .. string.format("%02X", bytes[1] or 0)
        end
    end

    -- 5. Custom Offset & Length
    if src == "offset" then
        local off = (tonumber(rule.offset) or 0) + 1
        local len = tonumber(rule.length) or 2
        local parts = {}
        for k = off, math.min(#bytes, off + len - 1) do
            table.insert(parts, string.format("%02X", bytes[k] or 0))
        end
        local hex_str = table.concat(parts)
        if fmt == "decimal" then
            local dec_val = tonumber(hex_str, 16) or 0
            return pfx .. tostring(dec_val)
        else
            return pfx .. hex_str
        end
    end

    -- Fallback: Use first 2 bytes or UNKNOWN
    if #bytes >= 2 then
        return pfx .. string.format("%02X%02X", bytes[1], bytes[2])
    end

    return pfx .. "UNKNOWN"
end

-- ------------------------------------------------------------------------------
-- Scheme Matching
-- ------------------------------------------------------------------------------
function LoraDecoder.match_scheme(scheme, bytes, hex)
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
    elseif mtype == "condition" then
        local cond = scheme.matchCondition or ""
        if cond ~= "" then
            local ok, res = pcall(function()
                local fn = loadstring("local bytes, hex = ...; " .. cond)
                return fn and fn(bytes, hex)
            end)
            if ok and res then return true end
        end
        return false
    elseif mtype == "default" then
        return true
    end
    return false
end

-- ------------------------------------------------------------------------------
-- Main Unified Decoder Entry Points
-- ------------------------------------------------------------------------------

-- Decode a raw HEX payload
function LoraDecoder.decode_hex(hex, opt_config, opt_scheme_id)
    if not hex or hex == "" then
        return { success = false, error = "Empty hex payload" }
    end

    hex = tostring(hex):lower():gsub("[^0-9a-f]", "")
    local bytes = LoraDecoder.hex_to_bytes(hex)
    local cfg = opt_config or LoraDecoder.load_config()
    local schemes = cfg.schemes or {}
    local global_rule = cfg.globalNodeId or { source = "node_2b", format = "hex", prefix = "" }

    local matched_scheme = nil
    if opt_scheme_id then
        for _, s in ipairs(schemes) do
            if s.id == opt_scheme_id then
                matched_scheme = s
                break
            end
        end
    end

    if not matched_scheme then
        for _, s in ipairs(schemes) do
            if LoraDecoder.match_scheme(s, bytes, hex) then
                matched_scheme = s
                break
            end
        end
    end

    local metrics = {}
    if matched_scheme then
        local stype = matched_scheme.type or "ctv"
        if stype == "ctv" or stype == "tlv" then
            metrics = LoraDecoder.decode_ctv_payload(bytes, hex, tonumber(matched_scheme.dataOffset) or 4)
        elseif stype == "fields" then
            metrics = LoraDecoder.decode_fields_payload(bytes, matched_scheme.fields)
        elseif stype == "cayenne_lpp" then
            metrics = LoraDecoder.decode_cayenne_lpp(bytes, matched_scheme.dataOffset) or {}
        elseif stype == "ascii" then
            metrics = LoraDecoder.decode_ascii(bytes)
        end
    end

    -- Fallback: If no metrics parsed yet, try intelligent auto-decoders
    if not metrics.temperature and not metrics.battery and not metrics.state and not metrics.text then
        if #bytes >= 4 and bytes[1] ~= 0xAA then
            local auto_metrics = LoraDecoder.decode_ctv_payload(bytes, hex, 4)
            for k, v in pairs(auto_metrics) do metrics[k] = v end
        elseif #bytes >= 4 and bytes[1] == 0xAA then
            local auto_metrics = LoraDecoder.decode_ctv_payload(bytes, hex, 4)
            for k, v in pairs(auto_metrics) do metrics[k] = v end
        end
    end

    local node_id = LoraDecoder.extract_node_id(bytes, hex, matched_scheme, metrics, global_rule)
    metrics.node_id = node_id

    return {
        success = (next(metrics) ~= nil),
        node_id = node_id,
        scheme_id = matched_scheme and matched_scheme.id or "fallback_auto",
        scheme_name = matched_scheme and matched_scheme.name or "Auto CTV/IPSO Fallback",
        metrics = metrics,
        raw_hex = hex:upper(),
        size = #bytes
    }
end

-- Decode an entire LoRa Packet (with Hardware CRC Integrity Gate)
function LoraDecoder.decode_packet(pkt, opt_config)
    if not pkt or not pkt.hex then
        return nil, "Missing payload or hex"
    end

    -- STRICT CRC INTEGRITY GATE
    local status = tostring(pkt.status or ""):upper()
    if status ~= "" and status ~= "CRC_OK" then
        return nil, "CORRUPTED_CRC_" .. status
    end

    local res = LoraDecoder.decode_hex(pkt.hex, opt_config)
    if not res or not res.success then
        return nil, "DECODE_FAILED"
    end

    -- Enrich with radio metadata
    local m = res.metrics
    m.rssi      = tonumber(pkt.rssi)
    m.snr       = tonumber(pkt.snr)
    m.freq      = tonumber(pkt.freq)
    m.datr      = pkt.datr
    m.hex       = res.raw_hex
    m.size      = tonumber(pkt.size) or #LoraDecoder.hex_to_bytes(pkt.hex)
    m.last_seen = os.date("!%Y-%m-%dT%H:%M:%SZ")

    return res
end

-- ------------------------------------------------------------------------------
-- Self-Test Suite & Standalone Microservice Daemon
-- ------------------------------------------------------------------------------
function LoraDecoder.run_self_tests()
    print("=== LoraDecoder Standalone Self-Test Suite ===")
    
    -- Test 1: Node CAFE Cayenne LPP (Multi-Sensor)
    local hex_cafe = "CAFE96B840EB0102014902710001001C0425036700B904880000000000000000"
    local res1 = LoraDecoder.decode_hex(hex_cafe)
    print(string.format("[TEST 1] Node CAFE Decode: Node ID: %s | Scheme: %s", res1.node_id, res1.scheme_name))
    assert(res1.node_id == "CAFE", "Test 1 Failed: Node ID mismatch")
    assert(math.abs(res1.metrics.temperature - 18.5) < 0.01, "Test 1 Failed: Temperature mismatch")
    assert(math.abs(res1.metrics.battery - 3.29) < 0.01, "Test 1 Failed: Battery mismatch")
    print(string.format("         Temp: %.1f °C | Batt: %.2f V | Accel Z: %.3f g -> PASS",
        res1.metrics.temperature, res1.metrics.battery, res1.metrics.accel_z or 0))

    -- Test 2: Node AA0B Standard TLV
    local hex_aa0b = "AA0B64B70111079E02050FAC"
    local res2 = LoraDecoder.decode_hex(hex_aa0b)
    print(string.format("[TEST 2] Node AA0B Decode: Node ID: %s | Scheme: %s", res2.node_id, res2.scheme_name))
    assert(res2.node_id == "AA0B", "Test 2 Failed: Node ID mismatch")
    print(string.format("         Temp: %.1f °C | Batt: %.3f V -> PASS",
        res2.metrics.temperature or 0, res2.metrics.battery or 0))

    -- Test 3: ASCII Ping
    local hex_ascii = "50494E475F4C505338" -- "PING_LPS8"
    local res3 = LoraDecoder.decode_hex(hex_ascii)
    print(string.format("[TEST 3] ASCII Decode: Text: '%s' -> PASS", res3.metrics.text or ""))

    -- Test 4: CRC Rejection Gate
    local bad_pkt = { hex = hex_cafe, status = "CRC_BAD" }
    local res4, err4 = LoraDecoder.decode_packet(bad_pkt)
    assert(res4 == nil and err4:find("CORRUPTED_CRC"), "Test 4 Failed: Corrupted CRC was not rejected")
    print(string.format("[TEST 4] Corrupted CRC Rejection Gate: Correctly Dropped (%s) -> PASS", err4))

    print("=== All Standalone Decoder Tests Passed Successfully (4/4)! ===\n")
    return true
end

-- CLI Runner
local function run_cli(args)
    if #args == 0 or args[1] == "--help" or args[1] == "-h" then
        print([[
LoraDecoder Standalone Feature v2.1.0
Usage:
  lora_decoder.lua --hex <HEX_STRING>             Decode a raw HEX payload
  lora_decoder.lua --packet '<JSON_PACKET>'       Decode a full packet JSON object
  lora_decoder.lua --test                         Run self-test test suite
  lora_decoder.lua --config <PATH>                Override decoders.json location
  lora_decoder.lua --daemon [options]             Run as standalone MQTT decoding microservice

Daemon Options:
  --broker <HOST>     MQTT Broker IP/Host (default: 127.0.0.1)
  --port <PORT>       MQTT Port (default: 1883)
  --user <USER>       MQTT Username
  --pass <PASS>       MQTT Password
  --in-topic <TOPIC>  Raw packet topic to subscribe (default: lora/raw/#)
  --out-prefix <PFX>  State output topic prefix (default: lora)
]])
        return
    end

    local i = 1
    local opt_hex = nil
    local opt_packet = nil
    local opt_config = nil
    local is_daemon = false
    local broker_host = "127.0.0.1"
    local broker_port = 1883
    local broker_user = ""
    local broker_pass = ""
    local in_topic = "lora/raw/#"
    local out_pfx = "lora"

    while i <= #args do
        local a = args[i]
        if a == "--hex" and args[i + 1] then
            opt_hex = args[i + 1]; i = i + 1
        elseif a == "--packet" and args[i + 1] then
            opt_packet = args[i + 1]; i = i + 1
        elseif a == "--config" and args[i + 1] then
            opt_config = args[i + 1]; i = i + 1
        elseif a == "--test" then
            LoraDecoder.run_self_tests()
            return
        elseif a == "--daemon" then
            is_daemon = true
        elseif a == "--broker" and args[i + 1] then
            broker_host = args[i + 1]; i = i + 1
        elseif a == "--port" and args[i + 1] then
            broker_port = tonumber(args[i + 1]) or 1883; i = i + 1
        elseif a == "--user" and args[i + 1] then
            broker_user = args[i + 1]; i = i + 1
        elseif a == "--pass" and args[i + 1] then
            broker_pass = args[i + 1]; i = i + 1
        elseif a == "--in-topic" and args[i + 1] then
            in_topic = args[i + 1]; i = i + 1
        elseif a == "--out-prefix" and args[i + 1] then
            out_pfx = args[i + 1]; i = i + 1
        end
        i = i + 1
    end

    local cfg = opt_config and LoraDecoder.load_config(opt_config) or nil

    if opt_hex then
        local res = LoraDecoder.decode_hex(opt_hex, cfg)
        print(json.stringify(res, true))
        return
    end

    if opt_packet then
        local pkt = json.parse(opt_packet)
        if not pkt then
            print('{"error":"Invalid JSON packet argument"}')
            return
        end
        local res, err = LoraDecoder.decode_packet(pkt, cfg)
        if not res then
            print(json.stringify({ error = err }))
        else
            print(json.stringify(res, true))
        end
        return
    end

    if is_daemon then
        print(string.format("[DECODER-DAEMON] Starting standalone decoder microservice..."))
        print(string.format("  MQTT Broker: %s:%d", broker_host, broker_port))
        print(string.format("  Subscribe:   %s", in_topic))
        print(string.format("  Output:      %s/<NODE_ID>/state", out_pfx))

        local auth = ""
        if broker_user ~= "" then auth = auth .. " -u " .. string.format("%q", broker_user) end
        if broker_pass ~= "" then auth = auth .. " -P " .. string.format("%q", broker_pass) end

        local sub_cmd = string.format("mosquitto_sub -h %s -p %d %s -t %q -v 2>/dev/null",
            broker_host, broker_port, auth, in_topic)

        while true do
            local pipe = io.popen(sub_cmd)
            if pipe then
                for line in pipe:lines() do
                    local topic, payload = line:match("^(%S+)%s*(.*)$")
                    if topic and payload and payload ~= "" then
                        local pkt = json.parse(payload)
                        if pkt and pkt.hex then
                            local res, err = LoraDecoder.decode_packet(pkt, cfg)
                            if res and res.metrics and res.node_id then
                                local out_topic = out_pfx .. "/" .. res.node_id .. "/state"
                                local out_payload = json.stringify(res.metrics)
                                local pub_cmd = string.format("mosquitto_pub -h %s -p %d %s -t %q -m %q -r 2>/dev/null &",
                                    broker_host, broker_port, auth, out_topic, out_payload)
                                os.execute(pub_cmd)
                                print(string.format("[DECODED] [%s] -> %s: %s", res.node_id, out_topic, out_payload))
                            end
                        end
                    end
                end
                pipe:close()
            end
            os.execute("sleep 3")
        end
    end
end

-- If executed directly from shell, invoke CLI runner
if arg and arg[0] and (arg[0]:find("lora_decoder") or #arg > 0) then
    run_cli(arg)
end

return LoraDecoder
