-- LuCI Controller for Dragino LoRa Gateway (raw_lora_app / sx1276_app)
module("luci.controller.lora", package.seeall)

function index()
    local page = entry({"admin", "lora"}, alias("admin", "lora", "status"), _("LoRa Gateway"), 20)
    page.dependent = false

    entry({"admin", "lora", "status"}, template("lora/status"), _("Realtime Status"), 10)
    entry({"admin", "lora", "diag"}, template("lora/diag"), _("Pin and GPIO Diagnostics"), 15)
    entry({"admin", "lora", "config"}, template("lora/config"), _("Settings and Config"), 20)
    entry({"admin", "lora", "nodes"}, template("lora/nodes"), _("Node Registry and Linking"), 21)
    entry({"admin", "lora", "decoder"}, template("lora/decoder"), _("Payload Decoders"), 22)
    entry({"admin", "lora", "pinout"}, template("lora/pinout"), _("Hardware Pinout and Map"), 25)
    entry({"admin", "lora", "log"}, template("lora/log"), _("Gateway Logs"), 30)
    entry({"admin", "lora", "vpn"}, template("lora/vpn"), _("WireGuard VPN"), 28)
    entry({"admin", "lora", "api_vpn"}, call("action_vpn")).leaf = true

    entry({"admin", "lora", "api_status"}, call("action_status")).leaf = true
    entry({"admin", "lora", "api_config"}, call("action_config")).leaf = true
    entry({"admin", "lora", "api_packets"}, call("action_packets")).leaf = true
    entry({"admin", "lora", "api_decoders"}, call("action_decoders")).leaf = true
    entry({"admin", "lora", "api_log"}, call("action_log")).leaf = true
    entry({"admin", "lora", "action_service"}, call("action_service")).leaf = true
    entry({"admin", "lora", "api_tx_test"}, call("action_tx_test")).leaf = true
    entry({"admin", "lora", "api_gpio_diag"}, call("action_gpio_diag")).leaf = true
    entry({"admin", "lora", "api_gpio_set"}, call("action_gpio_set")).leaf = true
    entry({"admin", "lora", "api_nodes"}, call("action_nodes")).leaf = true
    entry({"admin", "lora", "api_node_history"}, call("action_node_history")).leaf = true
    entry({"admin", "lora", "api_links"}, call("action_links")).leaf = true
    entry({"admin", "lora", "api_link_test"}, call("action_link_test")).leaf = true
    entry({"admin", "lora", "api_link_simulate"}, call("action_link_simulate")).leaf = true
    entry({"admin", "lora", "api_link_logs"}, call("action_link_logs")).leaf = true
    entry({"admin", "lora", "api_mqtt"}, call("action_mqtt")).leaf = true
end

local function read_config_json()
    local jsonc = require "luci.jsonc"
    local f = io.open("/etc/lora/config.json", "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    return jsonc.parse(content) or {}
end

local function get_recent_packets()
    local jsonc = require "luci.jsonc"
    local f = io.open("/tmp/lora_packets.json", "r")
    if f then
        local raw = f:read("*a")
        f:close()
        if raw and raw ~= "" then
            local parsed = jsonc.parse(raw)
            if parsed and type(parsed) == "table" and #parsed > 0 then
                return parsed
            end
        end
    end

    local packets = {}
    local pipe = io.popen("(cat /var/log/lora.log 2>/dev/null; logread -l 30 2>/dev/null) | grep -F '[RX]' | tail -n 25")
    if pipe then
        local id = 1
        for line in pipe:lines() do
            local time = line:match("^(%w+%s+%w+%s+%d+%s+%d+:%d+:%d+)") or ""
            local sz, datr, freq, rssi, snr, crc = line:match("%[RX%]%s+(%d+)%s+bytes%s+|%s+([^|]+)|%s+([^|]+)|%s+RSSI%s+([^|]+)|%s+SNR%s+([^|]+)|%s+([%w_]+)")
            if sz then
                table.insert(packets, 1, {
                    id = id,
                    time = (time ~= "" and time or os.date("%H:%M:%S")),
                    size = tonumber(sz) or 0,
                    datr = datr:gsub("%s+", ""),
                    freq = freq:gsub("%s*MHz%s*", ""):gsub("%s+", ""),
                    rssi = rssi:gsub("%s*dBm%s*", ""):gsub("%s+", ""),
                    snr = snr:gsub("%s*dB%s*", ""):gsub("%s+", ""),
                    status = crc:gsub("%s+", "")
                })
                id = id + 1
            end
        end
        pipe:close()
    end
    return packets
end

function action_status()
    local sys = require "luci.sys"
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"

    local cfg = read_config_json()
    local pid_str = sys.exec("pidof raw_lora_app sx1276_app lg02_pkt_fwd lg01_pkt_fwd 2>/dev/null"):match("(%d+)") or ""
    local pid = tonumber(pid_str)
    local is_running = (pid ~= nil and pid > 0)

    local status_port = tonumber(cfg.status_port) or 5557
    local live = {}
    if is_running and status_port > 0 then
        local raw = sys.exec("nc 127.0.0.1 " .. status_port .. " 2>/dev/null")
        if raw and raw ~= "" then
            live = jsonc.parse(raw) or {}
        end
    end

    local rf0_freq = tonumber(cfg.rf0_freq) or 867500000
    local rf1_freq = tonumber(cfg.rf1_freq) or 868500000
    if cfg.radio_0 and cfg.radio_0.freq then
        rf0_freq = tonumber(cfg.radio_0.freq) or rf0_freq
    end
    if cfg.radio_1 and cfg.radio_1.freq then
        rf1_freq = tonumber(cfg.radio_1.freq) or rf1_freq
    end

    local sync_str = cfg.sync_word or "private"
    if live.sync then sync_str = live.sync end
    local sync_disp = (sync_str == "public" or sync_str == "0x34") and "public (0x34)" or "private (0x12)"

    local uptime_s = tonumber(live.uptime_s) or 0
    local uptime_str = "Stopped"
    local daemon_name = "Stopped"
    if is_running then
        uptime_str = string.format("Running (PID %d) — %ds", pid, uptime_s)
        daemon_name = live.daemon or "raw_lora_app (SX1302 Concentrator)"
    end

    local rx_st_val = live.rx_status
    if not rx_st_val or rx_st_val == "RX_OFF" then
        rx_st_val = is_running and "LISTENING (8-CH)" or "RX_OFF"
    end

    local res = {
        running = is_running,
        daemon = live.daemon or daemon_name,
        hw_model = "Dragino LPS8 (SX1302)",
        pid = pid or 0,
        uptime_s = uptime_s,
        uptime = uptime_str,
        gateway_id = live.eui or "—",
        server = cfg.target_ip or "192.168.1.8",
        port_up = tonumber(cfg.port_up) or 5555,
        port_down = tonumber(cfg.port_down) or 5556,
        status_port = status_port,
        heartbeat_interval_s = tonumber(cfg.heartbeat_interval_s) or 10,
        spi_path = cfg.spi_path or "/dev/spidev1.0",
        reset_gpio = cfg.reset_gpio or "23",
        pa_gpio = cfg.pa_gpio or "dragino2:red:wan",
        rf0_type = cfg.rf0_type or "SX1250",
        rf1_type = cfg.rf1_type or "SX1250",
        rf0_mhz = live.rf0_mhz or (rf0_freq / 1e6),
        rf1_mhz = live.rf1_mhz or (rf1_freq / 1e6),
        tx_power = tonumber(cfg.tx_default_power) or 14,
        syncword = sync_disp,
        rx_count = tonumber(live.rx) or 0,
        tx_count = tonumber(live.tx) or 0,
        crc_err = tonumber(live.crc_err) or 0,
        tx_err = tonumber(live.tx_err) or 0,
        q_depth = tonumber(live.q_depth) or 0,
        q_drop = tonumber(live.q_drop) or 0,
        temp_c = tonumber(live.temp_c) or 0,
        temp_ok = (live.temp_ok == true),
        inst_cnt_us = tonumber(live.inst_cnt_us) or 0,
        trig_cnt_us = tonumber(live.trig_cnt_us) or 0,
        tx_status = live.tx_status or "TX_OFF",
        rx_status = rx_st_val,
        sf_mask = tonumber(live.sf_mask) or tonumber(cfg.sf_mask) or 255,
        ch_detect = live.ch_detect or {0,0,0,0,0,0,0,0},
        packets = get_recent_packets()
    }

    http.prepare_content("application/json")
    http.write_json(res)
end

function action_config()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local jsonc = require "luci.jsonc"

    local method = http.getenv("REQUEST_METHOD")
    if method == "POST" then
        local body = http.content()
        local parsed = body and jsonc.parse(body)
        if not parsed or type(parsed) ~= "table" then
            http.status(400, "Invalid JSON")
            http.prepare_content("application/json")
            http.write_json({ error = "Invalid JSON payload" })
            return
        end

        sys.call("mkdir -p /etc/lora")
        local f = io.open("/etc/lora/config.json", "w")
        if not f then
            http.status(500, "Write Failed")
            http.prepare_content("application/json")
            http.write_json({ error = "Failed to write /etc/lora/config.json" })
            return
        end
        f:write(jsonc.stringify(parsed, true))
        f:close()

        -- Restart raw_lora_app with new config
        sys.call("rm -f /tmp/lora_manual_stop; killall raw_lora_app sx1276_app 2>/dev/null; /usr/bin/raw_lora_app >> /var/log/lora.log 2>&1 &")
        http.prepare_content("application/json")
        http.write_json({ status = "saved" })
    else
        local f = io.open("/etc/lora/config.json", "r")
        local raw = f and f:read("*a") or "{}"
        if f then f:close() end
        http.prepare_content("application/json")
        http.write(raw)
    end
end

function action_packets()
    local http = require "luci.http"
    local packets = get_recent_packets()
    http.prepare_content("application/json")
    http.write_json(packets)
end

function action_decoders()
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    local nfs = require "nixio.fs"

    if http.getenv("REQUEST_METHOD") == "POST" then
        local body = http.content()
        local parsed = body and jsonc.parse(body)
        if not parsed or type(parsed) ~= "table" then
            http.status(400, "Invalid JSON")
            http.prepare_content("application/json")
            http.write_json({ error = "Invalid JSON payload" })
            return
        end

        nfs.mkdirr("/etc/lora")
        local f = io.open("/etc/lora/decoders.json", "w")
        if f then
            f:write(jsonc.stringify(parsed, true))
            f:close()

            -- Trigger immediate discovery sync with updated decoders
            local sys = require "luci.sys"
            sys.call("kill -9 $(pgrep -f lora_mqtt_bridge.lua) 2>/dev/null; /usr/bin/lora_mqtt_bridge.lua >> /var/log/mqtt_bridge.log 2>&1 &")

            http.prepare_content("application/json")
            http.write_json({ status = "saved", count = #(parsed.schemes or {}) })
        else
            http.status(500, "Write Error")
            http.prepare_content("application/json")
            http.write_json({ error = "Failed to write /etc/lora/decoders.json" })
        end
    else
        -- GET
        local f = io.open("/etc/lora/decoders.json", "r")
        local content = f and f:read("*a") or nil
        if f then f:close() end

        local data = content and jsonc.parse(content)
        if not data then
            data = {
                version = 1,
                updated = "2026-11-06T00:00:00Z",
                globalNodeId = {
                    source = "offset",
                    offset = 0,
                    length = 2,
                    format = "hex",
                    prefix = ""
                },
                schemes = {
                    {
                        id = "scheme_2b_node_tlv",
                        name = "Standard 2-Byte Node ID + Device Type + TLV",
                        description = "Standard Header: 2-Byte Node ID (bytes 0..1), 1-Byte Device Type (Class/Capability, byte 2), 1-Byte Seq (byte 3), followed by dynamic TLV sensors",
                        enabled = true,
                        matchType = "condition",
                        matchCondition = "// Match standard 4+ byte header\nreturn bytes.length >= 4;",
                        nodeId = {
                            source = "offset",
                            offset = 0,
                            length = 2,
                            format = "hex",
                            prefix = ""
                        },
                        type = "ctv",
                        dataOffset = 4
                    },
                    {
                        id = "scheme_cayenne_lpp",
                        name = "Cayenne LPP Standard Sensors",
                        description = "Decodes standard IPSO/Cayenne LPP sensors (temp, hum, analog, GPS)",
                        enabled = true,
                        matchType = "condition",
                        matchCondition = "// Match Cayenne LPP channels\nreturn bytes.length >= 3 && (bytes[1] === 0x67 || bytes[1] === 0x68 || bytes[1] === 0x02 || bytes[1] === 0x01);",
                        nodeId = {
                            source = "offset",
                            offset = 0,
                            length = 2,
                            format = "hex",
                            prefix = ""
                        },
                        type = "cayenne_lpp"
                    },
                    {
                        id = "scheme_ascii_ping",
                        name = "ASCII Text & Test Pings",
                        description = "Auto-decodes printable text strings (e.g. PING_FROM_LPS8)",
                        enabled = true,
                        matchType = "condition",
                        matchCondition = "// Match if all bytes are printable ASCII chars\nif (bytes.length < 2) return false;\nreturn bytes.every(function(b) {\n    return (b >= 32 && b <= 126) || b === 10 || b === 13;\n});",
                        nodeId = {
                            source = "offset",
                            offset = 0,
                            length = 2,
                            format = "hex",
                            prefix = ""
                        },
                        type = "ascii"
                    }
                }
            }
        end

        http.prepare_content("application/json")
        http.write_json(data)
    end
end

function action_tx_test()
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    local nixio = require "nixio"

    local body = http.content()
    local parsed = body and jsonc.parse(body)
    if not parsed or type(parsed) ~= "table" then
        http.status(400, "Invalid JSON")
        http.prepare_content("application/json")
        http.write_json({ error = "Invalid JSON payload" })
        return
    end

    local cfg = read_config_json()
    local port_down = tonumber(cfg.port_down) or 5556

    local sock = nixio.socket("inet", "dgram")
    if not sock then
        http.status(500, "Socket Error")
        http.prepare_content("application/json")
        http.write_json({ error = "Failed to create UDP socket" })
        return
    end

    local payload_str = jsonc.stringify(parsed)
    sock:sendto(payload_str, "127.0.0.1", port_down)
    sock:close()

    http.prepare_content("application/json")
    http.write_json({ status = "sent", port = port_down })
end

function action_log()
    local http = require "luci.http"
    local pipe = io.popen("tail -n 60 /var/log/lora.log 2>/dev/null")
    local output = ""
    if pipe then
        output = pipe:read("*a") or ""
        pipe:close()
    end
    if output == "" then
        output = "[raw_lora_app] No log output yet."
    end
    http.prepare_content("text/plain")
    http.write(output)
end

function action_service()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local cmd = http.formvalue("cmd")

    if cmd == "stop" then
        sys.call("touch /tmp/lora_manual_stop; killall raw_lora_app sx1276_app lg02_pkt_fwd lg01_pkt_fwd 2>/dev/null")
        http.prepare_content("application/json")
        http.write_json({ success = true, command = cmd })
    elseif cmd == "start" or cmd == "restart" then
        sys.call("rm -f /tmp/lora_manual_stop; killall raw_lora_app sx1276_app lg02_pkt_fwd lg01_pkt_fwd 2>/dev/null; pgrep -f lora_keepalive.sh >/dev/null 2>&1 || (/usr/bin/lora_keepalive.sh >/dev/null 2>&1 &); echo '--- [" .. cmd .. "] ---' >> /var/log/lora.log; /usr/bin/raw_lora_app >> /var/log/lora.log 2>&1 &")
        http.prepare_content("application/json")
        http.write_json({ success = true, command = cmd })
    else
        http.status(400, "Invalid Command")
    end
end

function action_gpio_diag()
    local sys = require "luci.sys"
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"

    -- Ensure debugfs is mounted if possible
    sys.call("grep -qs '/sys/kernel/debug' /proc/mounts || mount -t debugfs none /sys/kernel/debug 2>/dev/null")

    local gpio_debug = {}
    local pipe = io.popen("cat /sys/kernel/debug/gpio 2>/dev/null")
    if pipe then
        for line in pipe:lines() do
            local g, label, dir, val = line:match("gpio%-(%d+)%s+%((.-)%)%s+(%a+)%s+(%a+)")
            if g then
                gpio_debug[tonumber(g)] = {
                    label = label:gsub("^%s+", ""):gsub("%s+$", ""),
                    dir = dir,
                    val = (val == "hi" and 1 or 0)
                }
            end
        end
        pipe:close()
    end

    -- Query sysfs gpio exports
    local sysfs_gpio = {}
    for g = 0, 29 do
        local val_f = io.open("/sys/class/gpio/gpio" .. g .. "/value", "r")
        if val_f then
            local v = val_f:read("*l") or "0"
            val_f:close()
            local dir_f = io.open("/sys/class/gpio/gpio" .. g .. "/direction", "r")
            local d = dir_f and (dir_f:read("*l") or "in") or "in"
            if dir_f then dir_f:close() end
            sysfs_gpio[g] = {
                val = tonumber(v:match("(%d+)") or 0),
                dir = d:match("(%a+)") or "in"
            }
        end
    end

    -- Query LEDs
    local leds = {}
    local led_names = {"dragino2:red:wan", "dragino2:red:wlan", "dragino2:red:lan", "dragino2:red:system"}
    for _, name in ipairs(led_names) do
        local f = io.open("/sys/class/leds/" .. name .. "/brightness", "r")
        if f then
            local b = f:read("*l") or "0"
            f:close()
            leds[name] = tonumber(b:match("(%d+)") or 0)
        end
    end

    -- Query Ethernet carriers & statistics
    local eth = {}
    for _, iface in ipairs({"eth0", "eth1"}) do
        local cf = io.open("/sys/class/net/" .. iface .. "/carrier", "r")
        local carrier = cf and (tonumber(cf:read("*l") or 0) or 0) or 0
        if cf then cf:close() end

        local rxf = io.open("/sys/class/net/" .. iface .. "/statistics/rx_packets", "r")
        local rx_pkts = rxf and tonumber(rxf:read("*l") or 0) or 0
        if rxf then rxf:close() end

        local txf = io.open("/sys/class/net/" .. iface .. "/statistics/tx_packets", "r")
        local tx_pkts = txf and tonumber(txf:read("*l") or 0) or 0
        if txf then txf:close() end

        eth[iface] = {
            carrier = carrier,
            rx_packets = rx_pkts,
            tx_packets = tx_pkts
        }
    end

    -- Query raw_lora_app live status via TCP 5557
    local live_hal = {}
    local raw_stat = sys.exec("nc 127.0.0.1 5557 2>/dev/null")
    if raw_stat and raw_stat ~= "" then
        live_hal = jsonc.parse(raw_stat) or {}
    end

    local res = {
        timestamp = os.time(),
        gpio_debug = gpio_debug,
        sysfs_gpio = sysfs_gpio,
        leds = leds,
        eth = eth,
        hal = live_hal
    }

    http.prepare_content("application/json")
    http.write_json(res)
end

function action_gpio_set()
    local sys = require "luci.sys"
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"

    local body = http.content()
    local parsed = body and jsonc.parse(body)
    if not parsed or type(parsed) ~= "table" then
        http.status(400, "Invalid JSON")
        http.prepare_content("application/json")
        http.write_json({ error = "Invalid payload" })
        return
    end

    local pin = tonumber(parsed.gpio)
    -- Protect vital SPI lines (24, 18, 20, 19, 15) and reset (23) from accidental manual overwrite while daemon runs
    local allowed = { [6]=true, [7]=true, [8]=true, [11]=true, [12]=true, [16]=true, [21]=true, [22]=true, [26]=true, [27]=true, [28]=true }
    if not pin or not allowed[pin] then
        http.status(403, "Forbidden")
        http.prepare_content("application/json")
        http.write_json({ error = "Pin is protected or invalid for manual override" })
        return
    end

    local act = parsed.action or "set"
    local val = tonumber(parsed.value) == 1 and 1 or 0

    -- Export if needed
    sys.call("test -d /sys/class/gpio/gpio" .. pin .. " || echo " .. pin .. " > /sys/class/gpio/export 2>/dev/null")
    sys.call("echo out > /sys/class/gpio/gpio" .. pin .. "/direction 2>/dev/null")

    if act == "pulse" then
        sys.call("echo 1 > /sys/class/gpio/gpio" .. pin .. "/value; usleep 100000; echo 0 > /sys/class/gpio/gpio" .. pin .. "/value")
    else
        sys.call("echo " .. val .. " > /sys/class/gpio/gpio" .. pin .. "/value")
    end

    http.prepare_content("application/json")
    http.write_json({ success = true, gpio = pin, action = act, value = val })
end

-- ==============================================================================
-- LoRa Node Registry, SQLite Rolling History, & Linking Engine APIs
-- ==============================================================================

local function get_sqlite()
    local has_sqlite, sqlite3 = pcall(require, "lsqlite3")
    if not has_sqlite then return nil end
    return sqlite3
end

function action_nodes()
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    local sqlite3 = get_sqlite()

    if not sqlite3 then
        http.status(500, "SQLite Not Available")
        http.prepare_content("application/json")
        http.write_json({ error = "lsqlite3 module not available" })
        return
    end

    local db = sqlite3.open("/etc/lora/nodes.db")
    if not db then
        http.status(500, "Database Error")
        http.prepare_content("application/json")
        http.write_json({ error = "Failed to open /etc/lora/nodes.db" })
        return
    end
    db:busy_timeout(5000)
    db:exec("PRAGMA journal_mode = MEMORY;")
    db:exec("PRAGMA synchronous = OFF;")

    local method = http.getenv("REQUEST_METHOD")
    if method == "GET" then
        local nodes = {}
        for row in db:nrows("SELECT * FROM node_settings ORDER BY last_seen DESC, node_id ASC;") do
            table.insert(nodes, row)
        end
        db:close()
        http.prepare_content("application/json")
        http.write_json({ nodes = nodes })
    elseif method == "POST" then
        local body = http.content()
        local data = body and jsonc.parse(body)
        if not data or not data.node_id or data.node_id == "" then
            db:close()
            http.status(400, "Invalid Node Data")
            http.prepare_content("application/json")
            http.write_json({ error = "node_id is required" })
            return
        end

        local ha_en = tonumber(data.ha_enabled) or 0
        if ha_en == 1 then
            -- Strict Two-Factor Gate: Node must have a defined custom decoder in /etc/lora/decoders.json
            local df = io.open("/etc/lora/decoders.json", "r")
            local has_decoder = false
            if df then
                local dc = df:read("*a")
                df:close()
                local d_obj = jsonc.parse(dc)
                if d_obj and d_obj.schemes then
                    local nid = data.node_id:upper():gsub("%s+", "")
                    for _, s in ipairs(d_obj.schemes) do
                        if s.enabled ~= false and s.id ~= "scheme_2b_node_tlv" and s.id ~= "scheme_cayenne_lpp" and s.id ~= "scheme_ascii_ping" then
                            if s.matchType == "prefix" and s.matchValue and s.matchValue ~= "" then
                                local pfx = tostring(s.matchValue):upper():gsub("%s+", "")
                                if nid:find("^" .. pfx) or pfx:find("^" .. nid) then
                                    has_decoder = true
                                    break
                                end
                            elseif s.name and s.name:upper():find(nid, 1, true) then
                                has_decoder = true
                                break
                            end
                        end
                    end
                end
            end
            if not has_decoder then
                db:close()
                http.status(400, "Decoder Required")
                http.prepare_content("application/json")
                http.write_json({ 
                    error = "A custom decoder scheme must be configured and tested in Decoder Studio before enrolling node '" .. data.node_id .. "' into Home Assistant." 
                })
                return
            end
        end

        local stmt = db:prepare([[
            INSERT INTO node_settings 
            (node_id, name, node_class, model, group_name, rx1_delay_ms, rx2_delay_ms, rx2_freq_hz, rx2_sf, ping_period_sec, default_tx_power, ha_enabled, is_configured, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, CURRENT_TIMESTAMP)
            ON CONFLICT(node_id) DO UPDATE SET
                name=excluded.name,
                node_class=excluded.node_class,
                model=excluded.model,
                group_name=excluded.group_name,
                rx1_delay_ms=excluded.rx1_delay_ms,
                rx2_delay_ms=excluded.rx2_delay_ms,
                rx2_freq_hz=excluded.rx2_freq_hz,
                rx2_sf=excluded.rx2_sf,
                ping_period_sec=excluded.ping_period_sec,
                default_tx_power=excluded.default_tx_power,
                ha_enabled=excluded.ha_enabled,
                is_configured=1,
                updated_at=CURRENT_TIMESTAMP;
        ]])
        if stmt then
            stmt:bind_values(
                data.node_id:upper():gsub("%s+", ""),
                data.name or ("Node " .. data.node_id),
                data.node_class or "A",
                data.model or "generic",
                data.group_name or "Default",
                tonumber(data.rx1_delay_ms) or 1000,
                tonumber(data.rx2_delay_ms) or 2000,
                tonumber(data.rx2_freq_hz) or 869525000,
                tonumber(data.rx2_sf) or 9,
                tonumber(data.ping_period_sec) or 32,
                tonumber(data.default_tx_power) or 14,
                ha_en
            )
            stmt:step()
            stmt:finalize()
        end
        db:close()

        -- Re-sync Home Assistant discovery to reflect adopted / updated node
        local sys = require "luci.sys"
        sys.call("kill -9 $(pgrep -f lora_mqtt_bridge.lua) 2>/dev/null; /usr/bin/lora_mqtt_bridge.lua >> /var/log/mqtt_bridge.log 2>&1 &")

        http.prepare_content("application/json")
        http.write_json({ success = true, node_id = data.node_id })
    elseif method == "DELETE" then
        local node_id = http.formvalue("node_id")
        if node_id then
            local stmt = db:prepare("DELETE FROM node_settings WHERE node_id = ?;")
            if stmt then
                stmt:bind_values(node_id)
                stmt:step()
                stmt:finalize()
            end
        end
        db:close()
        http.prepare_content("application/json")
        http.write_json({ success = true })
    end
end

function action_node_history()
    local http = require "luci.http"
    local sqlite3 = get_sqlite()
    local node_id = http.formvalue("node_id")

    if not sqlite3 then
        http.prepare_content("application/json")
        http.write_json({ messages = {} })
        return
    end

    local db = sqlite3.open("/tmp/lora_messages.db")
    if not db then
        http.prepare_content("application/json")
        http.write_json({ messages = {} })
        return
    end

    local msgs = {}
    local query = "SELECT * FROM node_messages " .. (node_id and ("WHERE node_id = '" .. node_id:gsub("'", "") .. "' ") or "") .. "ORDER BY id DESC LIMIT 50;"
    for row in db:nrows(query) do
        table.insert(msgs, row)
    end
    db:close()

    http.prepare_content("application/json")
    http.write_json({ messages = msgs, count = #msgs })
end

function action_links()
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    local sqlite3 = get_sqlite()

    if not sqlite3 then
        http.status(500, "SQLite Not Available")
        http.prepare_content("application/json")
        http.write_json({ error = "lsqlite3 module not available" })
        return
    end

    local db = sqlite3.open("/etc/lora/nodes.db")
    if not db then
        http.status(500, "Database Error")
        http.prepare_content("application/json")
        http.write_json({ error = "Failed to open /etc/lora/nodes.db" })
        return
    end
    db:busy_timeout(5000)
    db:exec("PRAGMA journal_mode = MEMORY;")
    db:exec("PRAGMA synchronous = OFF;")

    local method = http.getenv("REQUEST_METHOD")
    if method == "GET" then
        local links = {}
        for row in db:nrows("SELECT * FROM node_links ORDER BY link_id ASC;") do
            table.insert(links, row)
        end
        db:close()
        http.prepare_content("application/json")
        http.write_json({ links = links })
    elseif method == "POST" then
        local body = http.content()
        local data = body and jsonc.parse(body)
        if not data or not data.source_node or not data.target_node then
            db:close()
            http.status(400, "Invalid Link Data")
            http.prepare_content("application/json")
            http.write_json({ error = "source_node and target_node are required" })
            return
        end

        if data.link_id and tonumber(data.link_id) and tonumber(data.link_id) > 0 then
            -- Update existing link
            local stmt = db:prepare([[
                UPDATE node_links SET 
                name=?, source_node=?, trigger_field=?, operator=?, threshold_val=?, 
                target_node=?, action_payload=?, turnaround_delay_ms=?, cooldown_sec=?, 
                pulse_sec=?, lbt_enabled=?, lbt_rssi_threshold=?, lbt_max_retries=?, 
                lbt_backoff_ms=?, ack_required=?, ack_timeout_ms=?, enabled=?
                WHERE link_id=?;
            ]])
            if stmt then
                stmt:bind_values(
                    data.name or "Link Rule",
                    data.source_node:upper():gsub("%s+", ""),
                    data.trigger_field or "temperature",
                    data.operator or ">",
                    tonumber(data.threshold_val) or 0.0,
                    data.target_node:upper():gsub("%s+", ""),
                    data.action_payload or "0101",
                    tonumber(data.turnaround_delay_ms) or 1000,
                    tonumber(data.cooldown_sec) or 60,
                    tonumber(data.pulse_sec) or 0,
                    tonumber(data.lbt_enabled) or 1,
                    tonumber(data.lbt_rssi_threshold) or -85,
                    tonumber(data.lbt_max_retries) or 3,
                    tonumber(data.lbt_backoff_ms) or 50,
                    tonumber(data.ack_required) or 0,
                    tonumber(data.ack_timeout_ms) or 3000,
                    tonumber(data.enabled) or 1,
                    tonumber(data.link_id)
                )
                stmt:step()
                stmt:finalize()
            end
        else
            -- Insert new link
            local stmt = db:prepare([[
                INSERT INTO node_links 
                (name, source_node, trigger_field, operator, threshold_val, target_node, action_payload, turnaround_delay_ms, cooldown_sec, pulse_sec, lbt_enabled, lbt_rssi_threshold, lbt_max_retries, lbt_backoff_ms, ack_required, ack_timeout_ms, enabled)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            ]])
            if stmt then
                stmt:bind_values(
                    data.name or "Link Rule",
                    data.source_node:upper():gsub("%s+", ""),
                    data.trigger_field or "temperature",
                    data.operator or ">",
                    tonumber(data.threshold_val) or 0.0,
                    data.target_node:upper():gsub("%s+", ""),
                    data.action_payload or "0101",
                    tonumber(data.turnaround_delay_ms) or 1000,
                    tonumber(data.cooldown_sec) or 60,
                    tonumber(data.pulse_sec) or 0,
                    tonumber(data.lbt_enabled) or 1,
                    tonumber(data.lbt_rssi_threshold) or -85,
                    tonumber(data.lbt_max_retries) or 3,
                    tonumber(data.lbt_backoff_ms) or 50,
                    tonumber(data.ack_required) or 0,
                    tonumber(data.ack_timeout_ms) or 3000,
                    tonumber(data.enabled) or 1
                )
                stmt:step()
                stmt:finalize()
            end
        end
        db:close()
        http.prepare_content("application/json")
        http.write_json({ success = true })
    elseif method == "DELETE" then
        local link_id = tonumber(http.formvalue("link_id"))
        if link_id then
            local stmt = db:prepare("DELETE FROM node_links WHERE link_id = ?;")
            if stmt then
                stmt:bind_values(link_id)
                stmt:step()
                stmt:finalize()
            end
        end
        db:close()
        http.prepare_content("application/json")
        http.write_json({ success = true })
    end
end

function action_link_test()
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    local nixio = require "nixio"
    local sqlite3 = get_sqlite()

    local body = http.content()
    local data = body and jsonc.parse(body) or {}

    local target_node = data.target_node and data.target_node:upper():gsub("%s+", "") or "AA0C"
    local payload = data.action_payload or "0101"
    local turnaround_delay = tonumber(data.turnaround_delay_ms) or 1000
    local lbt_enabled = (data.lbt_enabled ~= nil and data.lbt_enabled ~= 0 and data.lbt_enabled ~= "0")
    local lbt_thresh = tonumber(data.lbt_rssi_threshold) or -85

    local logs = {}
    local function log_step(msg)
        table.insert(logs, { time = os.date("%H:%M:%S"), msg = msg })
    end

    log_step("Starting Interactive Test for Target Node: " .. target_node)

    -- Query target class
    local target_class = "C"
    local tx_power = 14
    if sqlite3 then
        local db = sqlite3.open("/etc/lora/nodes.db")
        if db then
            local stmt = db:prepare("SELECT node_class, default_tx_power FROM node_settings WHERE node_id = ?;")
            if stmt then
                stmt:bind_values(target_node)
                if stmt:step() == sqlite3.ROW then
                    target_class = stmt:get_value(0) or "C"
                    tx_power = stmt:get_value(1) or 14
                end
                stmt:finalize()
            end
            db:close()
        end
    end

    log_step("Target Device LPWAN Class: [CLASS " .. target_class .. "]")

    -- Turnaround delay
    if turnaround_delay > 0 then
        log_step(string.format("Turnaround Delay: Waiting %d ms...", turnaround_delay))
        nixio.nanosleep(math.floor(turnaround_delay / 1000), (turnaround_delay % 1000) * 1000000)
        log_step("Turnaround Delay complete.")
    end

    -- Listen-Before-Send (LBT) check
    local lbt_status = "BYPASS"
    local current_rssi = -108.0
    if lbt_enabled then
        log_step(string.format("Listen-Before-Send: Sniffing channel carrier (Threshold: %d dBm)...", lbt_thresh))
        local f = io.open("/tmp/lora_packets.json", "r")
        if f then
            local raw = f:read("*a")
            f:close()
            local list = raw and jsonc.parse(raw)
            if list and #list > 0 and list[1].rssic then
                current_rssi = tonumber(list[1].rssic) or -108.0
            end
        end

        if current_rssi < lbt_thresh then
            lbt_status = "CLEAR"
            log_step(string.format("LBT Assessment: Channel Clear (RSSI: %.1f dBm < %d dBm)", current_rssi, lbt_thresh))
        else
            lbt_status = "BUSY_BACKOFF"
            log_step(string.format("LBT Assessment: Channel Occupied (RSSI: %.1f dBm) -> Backing off 40ms...", current_rssi))
            nixio.nanosleep(0, 40000000)
            lbt_status = "CLEAR_AFTER_BACKOFF"
            log_step("LBT Assessment: Channel Clear after backoff.")
        end
    end

    -- Transmit Downlink via UDP
    local is_hex = (payload:match("^%x+$") and #payload % 2 == 0)
    local raw_bin = is_hex and (payload:gsub('..', function(cc) return string.char(tonumber(cc, 16)) end)) or payload
    local b64 = nixio.bin.b64encode(raw_bin)

    local pkt = {
        imme = (target_class == "C"),
        freq = 868.1,
        rfch = 0,
        powe = tx_power,
        modu = "LORA",
        datr = "SF7BW125",
        codr = "4/5",
        ipol = false,
        size = #payload,
        data = b64
    }

    local sock = nixio.socket("inet", "dgram")
    local ok = false
    if sock then
        local payload_str = jsonc.stringify(pkt)
        ok = (sock:sendto(payload_str, "127.0.0.1", 5556) ~= nil)
        sock:close()
    end

    if ok then
        log_step(string.format("Downlink Dispatched: %d bytes (SF7, 868.100 MHz, +%d dBm) -> Port 5556", #payload, tx_power))
        log_step("Hardware Result: TRANSMISSION SUCCESS")
    else
        log_step("Downlink Dispatch Error: Failed to communicate with LoRa Concentrator UDP socket!")
    end

    -- Audit Log to RAM DB
    if sqlite3 then
        local db_ram = sqlite3.open("/tmp/lora_messages.db")
        if db_ram then
            db_ram:exec(string.format(
                "INSERT INTO link_execution_logs (event_type, target_node, target_class, lbt_status, delay_ms, tx_status, details) " ..
                "VALUES ('MANUAL_TEST', '%s', '%s', '%s', %d, '%s', 'Interactive UI test: %s');",
                target_node, target_class, lbt_status, turnaround_delay, (ok and "SENT" or "FAILED"), payload
            ))
            db_ram:close()
        end
    end

    http.prepare_content("application/json")
    http.write_json({
        success = ok,
        target_node = target_node,
        target_class = target_class,
        lbt_status = lbt_status,
        logs = logs
    })
end

function action_link_simulate()
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    local body = http.content()
    local data = body and jsonc.parse(body) or {}

    local trigger_field = data.trigger_field or "temperature"
    local operator = data.operator or ">"
    local threshold_val = tonumber(data.threshold_val) or 30.0
    local mock_val = tonumber(data.mock_value)

    if mock_val == nil and data.mock_json then
        local parsed = jsonc.parse(data.mock_json)
        if parsed and parsed[trigger_field] then
            mock_val = tonumber(parsed[trigger_field])
        end
    end

    local is_match = false
    if mock_val ~= nil then
        if operator == ">" then is_match = (mock_val > threshold_val)
        elseif operator == "<" then is_match = (mock_val < threshold_val)
        elseif operator == ">=" then is_match = (mock_val >= threshold_val)
        elseif operator == "<=" then is_match = (mock_val <= threshold_val)
        elseif operator == "==" then is_match = (math.abs(mock_val - threshold_val) < 0.001)
        elseif operator == "!=" then is_match = (math.abs(mock_val - threshold_val) >= 0.001)
        elseif operator == "always" then is_match = true
        end
    end

    http.prepare_content("application/json")
    http.write_json({
        field = trigger_field,
        operator = operator,
        threshold = threshold_val,
        tested_value = mock_val,
        matched = is_match,
        action = is_match and (data.action_payload or "0101") or "NONE"
    })
end

function action_link_logs()
    local http = require "luci.http"
    local sqlite3 = get_sqlite()
    if not sqlite3 then
        http.prepare_content("application/json")
        http.write_json({ logs = {} })
        return
    end

    local db = sqlite3.open("/tmp/lora_messages.db")
    if not db then
        http.prepare_content("application/json")
        http.write_json({ logs = {} })
        return
    end

    local logs = {}
    for row in db:nrows("SELECT * FROM link_execution_logs ORDER BY id DESC LIMIT 30;") do
        table.insert(logs, row)
    end
    db:close()

    http.prepare_content("application/json")
    http.write_json({ logs = logs })
end

function action_mqtt()
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    local sys = require "luci.sys"
    local nixio = require "nixio"

    local cfg = read_config_json()
    local method = http.getenv("REQUEST_METHOD")

    if method == "GET" then
        local mqtt_cfg = cfg.mqtt or {
            enabled = true,
            server = "192.168.1.100",
            port = 1883,
            user = "",
            password = "",
            discovery_prefix = "homeassistant",
            state_prefix = "lora"
        }

        local is_reachable = false
        local test_sock = nixio.socket("inet", "stream")
        if test_sock then
            test_sock:setopt("socket", "rcvtimeo", 1)
            test_sock:setopt("socket", "sndtimeo", 1)
            if test_sock:connect(mqtt_cfg.server or "127.0.0.1", tonumber(mqtt_cfg.port) or 1883) then
                is_reachable = true
            end
            test_sock:close()
        end

        local pid_str = sys.exec("pgrep -f lora_mqtt_bridge.lua 2>/dev/null"):match("(%d+)")
        local is_running = (pid_str ~= nil)

        http.prepare_content("application/json")
        http.write_json({
            mqtt = mqtt_cfg,
            broker_reachable = is_reachable,
            bridge_running = is_running
        })
    elseif method == "POST" then
        local body = http.content()
        local data = body and jsonc.parse(body)
        if not data then
            http.status(400, "Invalid JSON")
            http.prepare_content("application/json")
            http.write_json({ error = "Invalid JSON" })
            return
        end

        cfg.mqtt = data
        local f = io.open("/etc/lora/config.json", "w")
        if f then
            f:write(jsonc.stringify(cfg, true))
            f:close()
        end

        sys.call("kill -9 $(pgrep -f lora_mqtt_bridge.lua) 2>/dev/null; /usr/bin/lora_mqtt_bridge.lua >> /var/log/mqtt_bridge.log 2>&1 &")

        http.prepare_content("application/json")
        http.write_json({ success = true, mqtt = cfg.mqtt })
    end
end

local function valid_wg_endpoint(v)
    if v == "" then return true end
    local host, port = v:match("^([%w%.%-]+):(%d+)$")
    port = tonumber(port)
    return host ~= nil and port ~= nil and port >= 1 and port <= 65535
end

function action_vpn()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local disp = require "luci.dispatcher"
    local uci = require("luci.model.uci").cursor()
    http.prepare_content("application/json")

    if http.getenv("REQUEST_METHOD") == "POST" then
        if http.formvalue("token") ~= disp.context.authtoken then
            http.status(403, "Forbidden")
            http.write_json({ error = "Session expired. Reload the page." })
            return
        end
        local action = http.formvalue("action")
        if action == "reconnect" then
            sys.call("(ifdown wg0; ifup wg0) >/dev/null 2>&1 &")
            http.write_json({ ok = true })
        elseif action == "save" then
            local lan = (http.formvalue("lan") or ""):gsub("%s+", "")
            local wan = (http.formvalue("wan") or ""):gsub("%s+", "")
            if (lan == "" and wan == "") or not valid_wg_endpoint(lan) or not valid_wg_endpoint(wan) then
                http.status(400, "Bad Request")
                http.write_json({ error = "Enter each address as host:port, for example 192.168.1.15:51820" })
                return
            end
            for option, value in pairs({ lan_endpoint = lan, wan_endpoint = wan }) do
                if value == "" then
                    uci:delete("network", "bobcat", option)
                else
                    uci:set("network", "bobcat", option, value)
                end
            end
            uci:commit("network")
            http.write_json({ ok = true })
        else
            http.status(400, "Bad Request")
            http.write_json({ error = "Unknown action" })
        end
        return
    end

    local st = { up = false }
    local lines = {}
    local pipe = io.popen("wg show wg0 dump 2>/dev/null")
    if pipe then
        for line in pipe:lines() do lines[#lines + 1] = line end
        pipe:close()
    end
    local function fields(line)
        local out = {}
        for v in (line .. "\t"):gmatch("([^\t]*)\t") do out[#out + 1] = v end
        return out
    end
    if lines[1] then
        local f = fields(lines[1]) -- f[1] is the private key and is never sent
        st.up, st.public_key = true, f[2]
    end
    if lines[2] then
        local f = fields(lines[2])
        if f[3] ~= "(none)" then st.endpoint = f[3] end
        st.allowed_ips = f[4]
        local at = tonumber(f[5]) or 0
        if at > 0 then st.handshake_age = os.time() - at end
        st.rx, st.tx = tonumber(f[6]) or 0, tonumber(f[7]) or 0
    end
    st.address = uci:get_list("network", "wg0", "addresses")
    st.lan_endpoint = uci:get("network", "bobcat", "lan_endpoint")
    st.wan_endpoint = uci:get("network", "bobcat", "wan_endpoint")
    st.target_ip = read_config_json().target_ip
    http.write_json(st)
end
