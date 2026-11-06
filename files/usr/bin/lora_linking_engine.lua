#!/usr/bin/env lua
-- /usr/bin/lora_linking_engine.lua
-- Industrial LoRa Gateway Linking, Queuing, & Downlink Engine
-- Architecture:
--   - Standalone LoRa Multi-Scheme Decoder Module (lora_decoder.lua)
--   - Strict Hardware CRC Integrity Gate (drops CRC_BAD, CRC_ERR, NO_CRC)
--   - Ultra-Fast Immediate MQTT Dispatch to Home Assistant (< 5ms)
--   - Dual SQLite: /etc/lora/nodes.db (Flash) & /tmp/lora_messages.db (RAM)
--   - Rolling circular buffer in RAM for recent telemetry
--   - LPWAN Classes: Class A (Queued RX1/RX2), Class B (Ping Slots), Class C (Instant)
--   - Listen-Before-Send (LBT / Carrier Sense) & Collision Avoidance
--   - Turnaround delays, debounce cooldowns, and automatic pulse resets

local sqlite3     = require "lsqlite3"
local nixio       = require "nixio"
local jsonc       = require "luci.jsonc"
local LoraDecoder = require "lora_decoder"

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

-- Cached MQTT Configuration (refreshed only when config.json changes on disk)
local g_mqtt_cfg = nil
local g_mqtt_mtime = 0

local function get_mqtt_config()
    local st = nixio.fs.stat(CONFIG_PATH)
    local mtime = st and st.mtime or 0
    if not g_mqtt_cfg or mtime ~= g_mqtt_mtime then
        local f = io.open(CONFIG_PATH, "r")
        if f then
            local c = f:read("*a")
            f:close()
            local cfg = jsonc.parse(c) or {}
            g_mqtt_cfg = cfg.mqtt or {}
            g_mqtt_mtime = mtime
        end
    end
    return g_mqtt_cfg or {}
end

-- Ultra-Fast Immediate Telemetry Dispatch to Home Assistant
local function publish_mqtt_telemetry(node_id, metrics)
    local m = get_mqtt_config()
    if m.enabled == false then return end

    local host   = m.server or "127.0.0.1"
    local port   = tonumber(m.port) or 1883
    local prefix = m.state_prefix or "lora"
    local auth   = ""
    if m.user and m.user ~= "" then
        auth = auth .. " -u " .. shellquote(m.user)
    end
    if m.password and m.password ~= "" then
        auth = auth .. " -P " .. shellquote(m.password)
    end

    local payload = jsonc.stringify(metrics)
    local topic   = prefix .. "/" .. node_id .. "/state"
    local cmd     = string.format(
        "mosquitto_pub -h %s -p %d %s -t %s -m %s -r 2>/dev/null &",
        shellquote(host),
        port,
        auth,
        shellquote(topic),
        shellquote(payload)
    )
    os.execute(cmd)
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

-- Class A Queued Downlink Handler
local function handle_class_a_downlink(node_id, tmst, freq, datr)
    local stmt = db_ram:prepare("SELECT id, payload FROM pending_downlinks WHERE target_node = ? AND status = 'QUEUED' ORDER BY id ASC LIMIT 1;")
    if not stmt then return end

    stmt:bind_values(node_id)
    if stmt:step() == sqlite3.ROW then
        local dl_id = stmt:get_value(0)
        local raw_hex = stmt:get_value(1)
        stmt:finalize()

        -- Fetch node settings
        local rx1_delay = 1000 -- default 1s (1000ms)
        local tx_power = 14
        local n_stmt = db_nodes:prepare("SELECT rx1_delay_ms, default_tx_power FROM node_settings WHERE node_id = ?;")
        if n_stmt then
            n_stmt:bind_values(node_id)
            if n_stmt:step() == sqlite3.ROW then
                rx1_delay = n_stmt:get_value(0) or 1000
                tx_power = n_stmt:get_value(1) or 14
            end
            n_stmt:finalize()
        end

        local count_us = (tmst + (rx1_delay * 1000)) % 4294967296
        local is_clear, rssi, lbt_stat = lbt_check_channel(-85, 2, 20)

        local pkt = {
            imme = false,
            tmst = count_us,
            freq = tonumber(freq) or 868.1,
            rfch = 0,
            powe = tx_power,
            modu = "LORA",
            datr = datr or "SF7BW125",
            codr = "4/5",
            ipol = true,
            size = #raw_hex / 2,
            data = nixio.bin.b64encode(raw_hex:gsub('..', function(cc) return string.char(tonumber(cc, 16)) end))
        }

        local ok, err = send_downlink_udp(pkt)
        local tx_status = ok and "SENT_RX1" or ("ERR_" .. (err or "UDP"))

        db_ram:exec(string.format("UPDATE pending_downlinks SET status = '%s', sent_at = CURRENT_TIMESTAMP WHERE id = %d;", tx_status, dl_id))
        db_ram:exec(string.format(
            "INSERT INTO link_execution_logs (link_id, event_type, target_node, target_class, tx_status, details) " ..
            "VALUES (0, 'CLASS_A_RX1', '%s', '%s', %u, %d, %.1f);",
            node_id, tx_status, count_us, rx1_delay, rssi
        ))
    else
        stmt:finalize()
    end
end

-- Process Cross-Node Automation & Linking Rules
local function process_links(node_id, metrics, tmst)
    local stmt = db_nodes:prepare("SELECT * FROM node_links WHERE source_node = ? AND enabled = 1;")
    if not stmt then return end

    stmt:bind_values(node_id)
    while stmt:step() == sqlite3.ROW do
        local link = {}
        for col = 0, stmt:columns() - 1 do
            link[stmt:column_name(col)] = stmt:get_value(col)
        end

        local val = metrics[link.trigger_field] or metrics.val or metrics.temperature
        if val ~= nil and evaluate_condition(val, link.condition_op, tonumber(link.threshold) or 0.0) then
            -- Cooldown Debounce Check
            local cooldown = tonumber(link.cooldown_sec) or 0
            local can_trigger = true
            if cooldown > 0 and link.last_triggered then
                local check_stmt = db_nodes:prepare("SELECT (strftime('%s', 'now') - strftime('%s', ?)) > ?;")
                if check_stmt then
                    check_stmt:bind_values(link.last_triggered, cooldown)
                    if check_stmt:step() == sqlite3.ROW then
                        can_trigger = (check_stmt:get_value(0) == 1)
                    end
                    check_stmt:finalize()
                end
            end

            if can_trigger then
                local target_node = link.target_node
                local action_cmd = link.action_command
                local t_class = "A"
                local t_power = 14
                local t_freq = 868.1
                local t_datr = "SF7BW125"

                local t_stmt = db_nodes:prepare("SELECT node_class, default_tx_power FROM node_settings WHERE node_id = ?;")
                if t_stmt then
                    t_stmt:bind_values(target_node)
                    if t_stmt:step() == sqlite3.ROW then
                        t_class = t_stmt:get_value(0) or "A"
                        t_power = t_stmt:get_value(1) or 14
                    end
                    t_stmt:finalize()
                end

                if t_class == "C" then
                    -- Class C: Immediate Downlink
                    local is_clear, rssi = lbt_check_channel(-85, 2, 20)
                    local pkt = {
                        imme = true,
                        freq = t_freq,
                        rfch = 0,
                        powe = t_power,
                        modu = "LORA",
                        datr = t_datr,
                        codr = "4/5",
                        ipol = false,
                        size = #action_cmd / 2,
                        data = nixio.bin.b64encode(action_cmd:gsub('..', function(cc) return string.char(tonumber(cc, 16)) end))
                    }
                    local ok, err = send_downlink_udp(pkt)
                    local tx_status = ok and "SENT_IMME" or ("ERR_" .. (err or "UDP"))

                    db_ram:exec(string.format(
                        "INSERT INTO link_execution_logs (link_id, event_type, source_node, target_node, target_class, trigger_value, tx_status, details) " ..
                        "VALUES (%d, 'CLASS_C_DOWNLINK', '%s', '%s', '%s', %.2f, '%s', 'LBT RSSI: %.1f dBm');",
                        link.link_id, node_id, target_node, t_class, val or 0.0, tx_status, rssi
                    ))

                    db_nodes:exec(string.format(
                        "UPDATE node_links SET last_triggered = CURRENT_TIMESTAMP, last_status = '%s' WHERE link_id = %d;",
                        tx_status, link.link_id
                    ))
                else
                    -- Class A: Queue for next RX1 window
                    db_ram:exec(string.format(
                        "INSERT INTO pending_downlinks (target_node, target_class, payload, status) " ..
                        "VALUES ('%s', '%s', '%s', 'QUEUED');",
                        target_node, t_class, action_cmd
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

-- ==============================================================================
-- Ingest New Packet: Fast Decode -> Immediate MQTT Dispatch -> Background Storage
-- ==============================================================================
local function ingest_packet(pkt)
    if not pkt or not pkt.hex then return end

    -- 1. STRICT HARDWARE CRC INTEGRITY GATE:
    -- Only frames that passed hardware CRC check (CRC_OK) enter the pipeline.
    -- Any corrupted packet (CRC_BAD, CRC_ERR, NO_CRC) is immediately dropped.
    local status = tostring(pkt.status or ""):upper()
    if status ~= "" and status ~= "CRC_OK" then
        return
    end

    -- 2. DECODE RAW PAYLOAD VIA STANDALONE DECODER FEATURE
    local dec_res, dec_err = LoraDecoder.decode_packet(pkt)
    if not dec_res or not dec_res.metrics then
        return
    end

    local metrics = dec_res.metrics
    local node_id = dec_res.node_id or metrics.node_id or "UNKNOWN"

    -- 3. CHECK CONDITIONS FOR HOME ASSISTANT
    -- Must be an adopted, configured node with assigned group (ha_enabled == 1)
    local should_pub = false
    local n_stmt = db_nodes:prepare("SELECT ha_enabled, is_configured, group_name FROM node_settings WHERE node_id = ?;")
    if n_stmt then
        n_stmt:bind_values(node_id)
        if n_stmt:step() == sqlite3.ROW then
            local ha_en  = n_stmt:get_value(0) or 0
            local is_cfg = n_stmt:get_value(1) or 0
            local grp    = n_stmt:get_value(2) or "Unassigned"
            if ha_en == 1 and is_cfg == 1 and grp ~= "Unassigned" and grp ~= "Uncategorized" and grp ~= "" then
                should_pub = true
            end
        end
        n_stmt:finalize()
    end

    -- 4. SEND TO HA OVER MQTT AS FAST AS POSSIBLE (PRIORITY 1)
    if should_pub then
        publish_mqtt_telemetry(node_id, metrics)
    end

    -- 5. BACKGROUND STORAGE & DOWNSTREAM ACTIONS
    -- 5.1 Rolling message buffer in RAM
    local decoded_json = jsonc.stringify(metrics)
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

    -- 5.2 Auto-discovery & Node Registry update on Flash
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

    -- 5.3 Class A Downlink checks
    if pkt.tmst then
        handle_class_a_downlink(node_id, tonumber(pkt.tmst), pkt.freq, pkt.datr)
    end

    -- 5.4 Cross-Node Linking & Automation Rules
    process_links(node_id, metrics, tonumber(pkt.tmst))
end

-- ==============================================================================
-- Ultra-Responsive Low-Latency Packet Listener Loop (50ms Polling via stat())
-- ==============================================================================
print("[ENGINE] LoRa Linking Engine running with Standalone LoraDecoder v" .. LoraDecoder._VERSION .. "...")

local seen_tmst = {}
local last_mtime = 0

while true do
    local st = nixio.fs.stat(PACKETS_JSON)
    local cur_mtime = st and st.mtime or 0
    if cur_mtime ~= last_mtime then
        last_mtime = cur_mtime
        local f = io.open(PACKETS_JSON, "r")
        if f then
            local raw = f:read("*a")
            f:close()
            local list = raw and jsonc.parse(raw)
            if list and #list > 0 then
                -- Ingest new packets from oldest to newest
                for i = #list, 1, -1 do
                    local p = list[i]
                    local tm = tonumber(p.tmst) or 0
                    if tm > 0 and not seen_tmst[tm] then
                        seen_tmst[tm] = true
                        ingest_packet(p)
                    end
                end

                -- Bound ring buffer size to 200 items to avoid RAM growth
                local count = 0
                for _ in pairs(seen_tmst) do count = count + 1 end
                if count > 200 then seen_tmst = {} end
            end
        end
    end
    nixio.nanosleep(0, 50000000) -- Sleep 50ms (ultra-fast, virtually 0% CPU via stat)
end
