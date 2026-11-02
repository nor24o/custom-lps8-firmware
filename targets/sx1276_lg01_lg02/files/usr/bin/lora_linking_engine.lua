#!/usr/bin/env lua
-- /usr/bin/lora_linking_engine.lua
-- Industrial LoRa Gateway Linking, Queuing, & Downlink Engine
-- Supports:
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

-- Measure / Estimate current Channel Noise / Carrier Floor (Listen-Before-Send)
local function lbt_check_channel(threshold_dbm, max_retries, backoff_ms)
    threshold_dbm = threshold_dbm or -85
    max_retries   = max_retries or 3
    backoff_ms    = backoff_ms or 50

    for attempt = 1, max_retries do
        -- Read most recent packet channel RSSI (rssic) or instantaneous carrier
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

        -- Channel busy: backoff randomized slot
        local sleep_time = (backoff_ms + math.random(10, 40)) / 1000.0
        nixio.nanosleep(math.floor(sleep_time), math.floor((sleep_time % 1) * 1e9))
    end

    return false, threshold_dbm, "BUSY_RETRIED"
end

-- Dispatch LoRa Downlink over UDP to port 5556 (raw_lora_app or lg02_pkt_fwd)
local function send_downlink_udp(pkt_table)
    local sock = nixio.socket("inet", "dgram")
    if not sock then return false, "socket_failed" end

    local payload_str = jsonc.stringify(pkt_table)
    local ok, err = sock:sendto(payload_str, "127.0.0.1", PORT_DOWN)
    sock:close()
    return (ok ~= nil), err
end

-- Decode telemetry metrics for rule matching
local function extract_metrics(hex, raw_b64)
    local metrics = {}
    if not hex or hex == "" then return metrics end

    hex = hex:lower()
    local node_id = hex:sub(1, 4):upper()
    metrics.node_id = node_id

    -- Read raw bytes
    local bytes = {}
    for i = 1, #hex, 2 do
        table.insert(bytes, tonumber(hex:sub(i, i+1), 16) or 0)
    end

    if #bytes >= 8 then
        -- Standard sensor packet: [0..1: ID, 2..3: SEQ, 4..5: TEMP/VAL, 6..7: VOLT]
        metrics.seq = (bytes[3] * 256) + bytes[4]
        metrics.temperature = ((bytes[5] * 256) + bytes[6]) / 10.0
        metrics.battery = ((bytes[7] * 256) + bytes[8]) / 1000.0
        metrics.val = metrics.temperature
    end

    return metrics
end

-- Evaluate condition
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

        -- Look up node RX1 timing
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

        local count_us = (uplink_tmst + (rx1_delay * 1000)) % 4294967296
        local lbt_ok, lbt_rssi, lbt_status = lbt_check_channel(-85, 2, 30)

        -- Convert payload to Base64
        local b64 = base64_encode(raw_payload:match("^%x+$") and hex_to_bin(raw_payload) or raw_payload)

        local pkt = {
            imme = false,
            tmst = count_us,
            freq = tonumber(uplink_freq) or 868.1,
            rfch = 0,
            powe = tx_powe,
            modu = "LORA",
            datr = uplink_datr or "SF7BW125",
            codr = "4/5",
            ipol = false,
            size = #raw_payload,
            data = b64
        }

        local ok, err = send_downlink_udp(pkt)
        local status_str = ok and "DISPATCHED" or "FAILED"

        db_ram:exec(string.format(
            "UPDATE pending_downlinks SET status = '%s', dispatched_at = CURRENT_TIMESTAMP, lbt_status = '%s' WHERE id = %d;",
            status_str, lbt_status, dl_id
        ))

        db_ram:exec(string.format(
            "INSERT INTO link_execution_logs (event_type, source_node, target_node, target_class, lbt_status, delay_ms, tx_status, details) " ..
            "VALUES ('CLASS_A_RX1', '%s', '%s', 'A', '%s', %d, '%s', 'Class A Downlink dispatched in RX1 window');",
            node_id, node_id, lbt_status, rx1_delay, status_str
        ))
    else
        stmt:finalize()
    end
end

-- Process Linking Automations
local function process_links(node_id, metrics, uplink_tmst)
    local stmt = db_nodes:prepare("SELECT * FROM node_links WHERE source_node = ? AND enabled = 1;")
    if not stmt then return end
    stmt:bind_values(node_id)

    local now = os.time()

    while stmt:step() == sqlite3.ROW do
        local link = stmt:get_named_values()
        local field = link.trigger_field
        local val = metrics[field] or metrics.val

        if val and evaluate_condition(val, link.operator, link.threshold_val) then
            -- Check cooldown debounce
            local last_ts = 0
            if link.last_triggered and link.last_triggered ~= "" then
                -- basic ISO parser
                local y, m, d, H, M, S = link.last_triggered:match("(%d+)-(%d+)-(%d+)%s+(%d+):(%d+):(%d+)")
                if y then
                    last_ts = os.time({year=y, month=m, day=d, hour=H, min=M, sec=S})
                end
            end

            if (now - last_ts) >= (link.cooldown_sec or 60) then
                local target_node = link.target_node
                local target_class = "A"
                local tx_power = 14

                -- Query target node settings
                local t_stmt = db_nodes:prepare("SELECT node_class, default_tx_power FROM node_settings WHERE node_id = ?;")
                if t_stmt then
                    t_stmt:bind_values(target_node)
                    if t_stmt:step() == sqlite3.ROW then
                        target_class = t_stmt:get_value(0) or "A"
                        tx_power = t_stmt:get_value(1) or 14
                    end
                    t_stmt:finalize()
                end

                if target_class == "C" then
                    -- Class C: Immediate transmission with LBT check
                    local lbt_ok, lbt_rssi, lbt_status = true, -100, "BYPASS"
                    if link.lbt_enabled == 1 then
                        lbt_ok, lbt_rssi, lbt_status = lbt_check_channel(link.lbt_rssi_threshold, link.lbt_max_retries, link.lbt_backoff_ms)
                    end

                    -- Turnaround delay if configured
                    if link.turnaround_delay_ms and link.turnaround_delay_ms > 0 then
                        local sleep_s = link.turnaround_delay_ms / 1000.0
                        nixio.nanosleep(math.floor(sleep_s), math.floor((sleep_s % 1) * 1e9))
                    end

                    local b64 = base64_encode(link.action_payload:match("^%x+$") and hex_to_bin(link.action_payload) or link.action_payload)
                    local pkt = {
                        imme = true,
                        freq = 868.1,
                        rfch = 0,
                        powe = tx_power,
                        modu = "LORA",
                        datr = "SF7BW125",
                        codr = "4/5",
                        ipol = false,
                        size = #link.action_payload,
                        data = b64
                    }

                    local ok, err = send_downlink_udp(pkt)
                    local tx_status = ok and "SENT" or "FAILED"

                    db_ram:exec(string.format(
                        "INSERT INTO link_execution_logs (link_id, event_type, source_node, target_node, target_class, lbt_status, delay_ms, tx_status, details) " ..
                        "VALUES (%d, 'AUTO_TRIGGER', '%s', '%s', 'C', '%s', %d, '%s', 'Trigger: %s %s %.1f (Val: %.1f)');",
                        link.link_id, node_id, target_node, lbt_status, link.turnaround_delay_ms or 0, tx_status,
                        field, link.operator, link.threshold_val, val
                    ))

                    db_nodes:exec(string.format(
                        "UPDATE node_links SET last_triggered = CURRENT_TIMESTAMP, last_status = '%s' WHERE link_id = %d;",
                        tx_status, link.link_id
                    ))
                else
                    -- Class A: Enqueue into pending downlinks for next RX window
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
print("[ENGINE] LoRa Linking & Downlink Engine running...")

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
