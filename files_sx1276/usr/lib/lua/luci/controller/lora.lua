-- LuCI Controller for Dragino LoRa Gateway (raw_lora_app / sx1276_app)
module("luci.controller.lora", package.seeall)

function index()
    local page = entry({"admin", "lora"}, alias("admin", "lora", "status"), _("LoRa Gateway"), 20)
    page.dependent = false

    entry({"admin", "lora", "status"}, template("lora/status"), _("Realtime Status"), 10)
    entry({"admin", "lora", "config"}, template("lora/config"), _("Settings & Config"), 20)
    entry({"admin", "lora", "log"}, template("lora/log"), _("Gateway Logs"), 30)

    entry({"admin", "lora", "api_status"}, call("action_status")).leaf = true
    entry({"admin", "lora", "api_config"}, call("action_config")).leaf = true
    entry({"admin", "lora", "api_packets"}, call("action_packets")).leaf = true
    entry({"admin", "lora", "api_log"}, call("action_log")).leaf = true
    entry({"admin", "lora", "action_service"}, call("action_service")).leaf = true
end

local function read_config_json()
    local jsonc = require "luci.jsonc"
    local f = io.open("/etc/lora/config.json", "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    return jsonc.parse(content) or {}
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
    if is_running then
        uptime_str = string.format("Running (PID %d) — %ds", pid, uptime_s)
    end

    local res = {
        running = is_running,
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
        q_drop = tonumber(live.q_drop) or 0
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
    local packets = {}

    local pipe = io.popen("(cat /var/log/lora.log 2>/dev/null; logread 2>/dev/null) | grep -F '[RX]' | tail -n 30")
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

    http.prepare_content("application/json")
    http.write_json(packets)
end

function action_log()
    local http = require "luci.http"
    local output = ""

    local f = io.open("/var/log/lora.log", "r")
    if f then
        output = f:read("*a") or ""
        f:close()
    end

    local pipe = io.popen("logread -l 50 2>/dev/null | grep -iE 'raw_lora_app|sx1302|sx1276|lora' | tail -n 30")
    if pipe then
        local syslogs = pipe:read("*a") or ""
        pipe:close()
        if syslogs ~= "" then
            output = output .. (output ~= "" and "\n" or "") .. syslogs
        end
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
