#!/usr/bin/env lua
-- ==============================================================================
-- service.lua — Standalone LoRa Decoder, Pipeline & Home Assistant Bridge Runner
-- ==============================================================================
-- Portable standalone runner for:
--   1. LoraDecoder (lora_decoder.lua) — Multi-Scheme Decoder Engine
--   2. Pipeline (pipeline.lua)       — Strict Hardware CRC Gate & Condition Checks
--   3. HABridge (ha_bridge.lua)      — Home Assistant MQTT Discovery & Telemetry Dispatch
--
-- Can run on any Linux, Mac, Raspberry Pi, Home Assistant OS, or OpenWrt gateway.
-- Pure standard Lua compatible (Lua 5.1, 5.2, 5.3, 5.4, LuaJIT).
-- ==============================================================================

-- Setup local package path to always resolve sibling modules first
local script_dir = debug.getinfo(1, "S").source:match("@?(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. package.path

local LoraDecoder = require "lora_decoder"
local Pipeline    = require "pipeline"
local HABridge    = require "ha_bridge"

local json = LoraDecoder.json

local DEFAULT_DECODERS_PATH = script_dir .. "decoders.json"
if not io.open(DEFAULT_DECODERS_PATH, "r") then
    DEFAULT_DECODERS_PATH = "/etc/lora/decoders.json"
end

local Config = {
    decoders_file = DEFAULT_DECODERS_PATH,
    broker_host   = "127.0.0.1",
    broker_port   = 1883,
    broker_user   = "",
    broker_pass   = "",
    ha_prefix     = "homeassistant",
    state_prefix  = "lora",
    watch_file    = nil,
    auto_enroll   = false, -- Strict security: Only enroll nodes with defined custom schemes
    quiet         = false
}

local function print_err(msg)
    io.stderr:write("[ERROR] " .. tostring(msg) .. "\n")
end

local function print_log(msg)
    if not Config.quiet then
        io.stdout:write(string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), tostring(msg)))
        io.stdout:flush()
    end
end

-- ------------------------------------------------------------------------------
-- CLI Argument Parser
-- ------------------------------------------------------------------------------
local function print_usage()
    io.stdout:write([[
Standalone LoRa Decoder & Home Assistant Pipeline Runner v2.1.0

USAGE:
  lua service.lua [OPTIONS]

COMMANDS:
  --test                     Run internal self-tests and CRC verification
  --hex <HEX>                Decode a single raw HEX payload and output JSON
  --packet '<JSON>'          Process a raw packet JSON object through pipeline
  --watch <FILE>             Continuously watch a packet JSON file (e.g. /tmp/lora_packets.json)
  --daemon                   Run as continuous background service with watcher/MQTT

OPTIONS:
  --decoders <PATH>          Path to decoders.json (default: ./decoders.json or /etc/lora/decoders.json)
  --broker <HOST>            MQTT Broker IP/hostname (default: 127.0.0.1)
  --port <PORT>              MQTT Broker Port (default: 1883)
  --user <USERNAME>          MQTT Username
  --pass <PASSWORD>          MQTT Password
  --ha-prefix <PREFIX>       Home Assistant discovery prefix (default: homeassistant)
  --state-prefix <PREFIX>    MQTT state topic root (default: lora)
  --auto-enroll              Auto-enroll ANY node seen (default: disabled; only defined schemes enroll)
  --quiet                    Suppress informational log messages
  --help, -h                 Show this help message

EXAMPLES:
  lua service.lua --hex CAFE96B840EB010201490271FFFB00180421036700B404880000000000000000
  lua service.lua --watch /tmp/lora_packets.json --broker 192.168.1.13 --user admin --pass admin
]])
end

local function parse_args(args)
    local mode = nil
    local target_val = nil
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--help" or a == "-h" then
            print_usage()
            os.exit(0)
        elseif a == "--test" then
            mode = "test"
        elseif a == "--hex" then
            mode = "hex"
            i = i + 1
            target_val = args[i]
        elseif a == "--packet" then
            mode = "packet"
            i = i + 1
            target_val = args[i]
        elseif a == "--watch" then
            mode = "watch"
            i = i + 1
            Config.watch_file = args[i]
        elseif a == "--daemon" then
            mode = "daemon"
        elseif a == "--decoders" then
            i = i + 1
            Config.decoders_file = args[i]
        elseif a == "--broker" then
            i = i + 1
            Config.broker_host = args[i]
        elseif a == "--port" then
            i = i + 1
            Config.broker_port = tonumber(args[i]) or 1883
        elseif a == "--user" then
            i = i + 1
            Config.broker_user = args[i]
        elseif a == "--pass" then
            i = i + 1
            Config.broker_pass = args[i]
        elseif a == "--ha-prefix" then
            i = i + 1
            Config.ha_prefix = args[i]
        elseif a == "--state-prefix" then
            i = i + 1
            Config.state_prefix = args[i]
        elseif a == "--auto-enroll" then
            Config.auto_enroll = true
        elseif a == "--quiet" then
            Config.quiet = true
        end
        i = i + 1
    end
    return mode or "test", target_val
end

-- ------------------------------------------------------------------------------
-- Condition Gate: Strict Zero-Auto-Enrollment Verification
-- ------------------------------------------------------------------------------
-- Ensures random nodes or corrupted frames never pollute Home Assistant
local g_enrolled_nodes = {}

local function is_node_allowed_for_ha(node_id, scheme_id, decoders_doc)
    if Config.auto_enroll then return true end
    if not node_id or node_id == "UNKNOWN" then return false end

    -- Already verified in memory
    if g_enrolled_nodes[node_id] then return true end

    -- Check if scheme is a custom, specific defined scheme (not generic fallback)
    if scheme_id and scheme_id ~= "scheme_2b_node_tlv" and 
       scheme_id ~= "scheme_cayenne_lpp" and 
       scheme_id ~= "scheme_ascii_ping" and 
       scheme_id ~= "none" then
        g_enrolled_nodes[node_id] = true
        return true
    end

    -- Check if node_id matches any defined scheme in decoders.json
    if decoders_doc and decoders_doc.schemes then
        local nid_up = node_id:upper()
        for _, s in ipairs(decoders_doc.schemes) do
            if s.enabled ~= false then
                local sid = s.id or ""
                if sid ~= "scheme_2b_node_tlv" and sid ~= "scheme_cayenne_lpp" and sid ~= "scheme_ascii_ping" then
                    if s.matchType == "prefix" and s.matchValue and s.matchValue ~= "" then
                        local pfx = s.matchValue:upper():gsub("%s+", "")
                        if nid_up:find("^" .. pfx) or pfx:find("^" .. nid_up) then
                            g_enrolled_nodes[node_id] = true
                            return true
                        end
                    elseif s.name and s.name:upper():find(nid_up, 1, true) then
                        g_enrolled_nodes[node_id] = true
                        return true
                    end
                end
            end
        end
    end

    return false
end

-- ------------------------------------------------------------------------------
-- Pipeline Processor & HA Dispatcher
-- ------------------------------------------------------------------------------
local function process_and_dispatch(pkt, decoders_doc)
    local ok, res = Pipeline.process_packet(pkt, decoders_doc)
    if not ok then
        return false, res -- Error or dropped CRC
    end

    local node_id   = res.node_id
    local metrics   = res.metrics
    local scheme_id = res.scheme_id

    local mqtt_cfg = {
        host         = Config.broker_host,
        port         = Config.broker_port,
        user         = Config.broker_user,
        password     = Config.broker_pass,
        ha_prefix    = Config.ha_prefix,
        state_prefix = Config.state_prefix
    }

    -- Strict Condition Check: Is node approved/defined for Home Assistant?
    local ha_allowed = is_node_allowed_for_ha(node_id, scheme_id, decoders_doc)

    if ha_allowed then
        -- 1. Ensure Tailored Home Assistant Discovery is published
        HABridge.publish_discovery({
            node_id    = node_id,
            name       = "LoRa Node " .. node_id,
            node_class = metrics.node_class or "A",
            model      = metrics.capability and ("LoRa " .. metrics.capability) or nil
        }, metrics, mqtt_cfg)

        -- 2. Immediate Telemetry State Dispatch (< 5ms)
        HABridge.publish_telemetry(node_id, metrics, mqtt_cfg)
    end

    return true, res, ha_allowed
end

-- ------------------------------------------------------------------------------
-- Main Execution Modes
-- ------------------------------------------------------------------------------
local function run_hex_mode(hex_val, decoders_doc)
    if not hex_val or hex_val == "" then
        print_err("Missing HEX payload. Provide string with --hex <HEX>")
        os.exit(1)
    end

    local pkt = {
        hex    = hex_val,
        status = "CRC_OK",
        rssi   = -55.0,
        snr    = 9.0,
        freq   = 868.5,
        datr   = "SF7BW125",
        size   = math.floor(#hex_val / 2)
    }

    local ok, res, ha_allowed = process_and_dispatch(pkt, decoders_doc)
    if not ok then
        print_err("Pipeline failed: " .. tostring(res))
        os.exit(1)
    end

    io.stdout:write(json.stringify({
        status      = "SUCCESS",
        node_id     = res.node_id,
        scheme_id   = res.scheme_id,
        scheme_name = res.scheme_name,
        ha_enrolled = ha_allowed,
        metrics     = res.metrics
    }, true) .. "\n")
end

local function run_packet_mode(raw_json, decoders_doc)
    if not raw_json or raw_json == "" then
        print_err("Missing packet JSON string. Provide with --packet '<JSON>'")
        os.exit(1)
    end

    local pkt = json.parse(raw_json)
    if not pkt or not pkt.hex then
        print_err("Invalid packet JSON format")
        os.exit(1)
    end

    local ok, res, ha_allowed = process_and_dispatch(pkt, decoders_doc)
    if not ok then
        io.stdout:write(json.stringify({ status = "DROPPED", reason = res }, true) .. "\n")
        return
    end

    io.stdout:write(json.stringify({
        status      = "DISPATCHED",
        node_id     = res.node_id,
        scheme_name = res.scheme_name,
        ha_enrolled = ha_allowed,
        metrics     = res.metrics
    }, true) .. "\n")
end

local function run_watch_mode(file_path, decoders_doc)
    file_path = file_path or Config.watch_file or "/tmp/lora_packets.json"
    print_log("Watching packet buffer: " .. file_path)
    print_log(string.format("MQTT Target: %s:%d (HA: %s, State: %s)", 
        Config.broker_host, Config.broker_port, Config.ha_prefix, Config.state_prefix))
    print_log("Zero Auto-Enrollment Gate: " .. (Config.auto_enroll and "DISABLED (All Enroll)" or "ACTIVE (Strict Scheme Verification)"))

    local seen_tmst = {}
    local last_content = ""

    while true do
        local f = io.open(file_path, "r")
        if f then
            local content = f:read("*a")
            f:close()
            if content and content ~= "" and content ~= last_content then
                last_content = content
                local list = json.parse(content)
                if list and type(list) == "table" and #list > 0 then
                    for i = #list, 1, -1 do
                        local p = list[i]
                        local tm = tonumber(p.tmst) or 0
                        local key = (tm > 0) and tostring(tm) or (tostring(p.time or "") .. "_" .. tostring(p.hex or ""))
                        if not seen_tmst[key] then
                            seen_tmst[key] = true
                            local ok, res, ha_en = process_and_dispatch(p, decoders_doc)
                            if ok then
                                print_log(string.format("DECODED [%s] via '%s' -> HA: %s | Temp: %s°C, Batt: %sV",
                                    res.node_id,
                                    res.scheme_name or "Standard",
                                    ha_en and "ENROLLED" or "BLOCKED",
                                    tostring(res.metrics.temperature or res.metrics.temp or "—"),
                                    tostring(res.metrics.battery or "—")
                                ))
                            else
                                if res:find("CORRUPTED_CRC") then
                                    print_log(string.format("CRC GATE DROPPED frame: %s", res))
                                end
                            end
                        end
                    end

                    -- Bound tracking table to avoid memory leaks
                    local count = 0
                    for _ in pairs(seen_tmst) do count = count + 1 end
                    if count > 500 then seen_tmst = {} end
                end
            end
        end

        -- Sleep 100ms
        os.execute("sleep 0.1 2>/dev/null || ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1")
    end
end

-- ------------------------------------------------------------------------------
-- Runner Entry Point
-- ------------------------------------------------------------------------------
local function main()
    local mode, target_val = parse_args(arg)

    if mode == "test" then
        io.stdout:write("=== Standalone Decoder, Pipeline & HA Bridge Verification ===\n")
        LoraDecoder.run_self_tests()

        -- Pipeline Test: Valid packet
        local test_pkt = {
            hex    = "CAFE96B840EB010201490271FFFB000C0425036700BB04880000000000000000",
            status = "CRC_OK",
            rssi   = -28.4,
            snr    = 6.0,
            freq   = 868.5
        }
        local ok, res = Pipeline.process_packet(test_pkt)
        assert(ok, "Pipeline valid packet failed")
        assert(res.node_id == "CAFE", "Node ID mismatch: " .. tostring(res.node_id))
        assert(res.metrics.temperature == 18.7, "Temperature decode mismatch")
        io.stdout:write("[TEST 5] Pipeline Valid Packet Execution: PASS\n")

        -- Pipeline Test: Corrupted CRC Rejection
        local bad_pkt = { hex = "CAFE112233", status = "CRC_BAD" }
        local bad_ok, bad_err = Pipeline.process_packet(bad_pkt)
        assert(not bad_ok, "Pipeline accepted corrupted CRC packet!")
        assert(bad_err:find("CORRUPTED_CRC"), "Wrong error for bad CRC: " .. tostring(bad_err))
        io.stdout:write("[TEST 6] Strict Hardware CRC Integrity Gate: PASS\n")

        io.stdout:write("=== All Standalone Feature Tests Passed (6/6)! ===\n")
        return
    end

    -- Load Decoders Document
    local decoders_doc = LoraDecoder.load_config(Config.decoders_file)
    if not decoders_doc then
        print_log("Warning: Could not open decoders file '" .. Config.decoders_file .. "', using default schemes.")
    else
        print_log(string.format("Loaded %d schemes from %s", 
            decoders_doc.schemes and #decoders_doc.schemes or 0, Config.decoders_file))
    end

    if mode == "hex" then
        run_hex_mode(target_val, decoders_doc)
    elseif mode == "packet" then
        run_packet_mode(target_val, decoders_doc)
    elseif mode == "watch" or mode == "daemon" then
        run_watch_mode(Config.watch_file, decoders_doc)
    end
end

main()
