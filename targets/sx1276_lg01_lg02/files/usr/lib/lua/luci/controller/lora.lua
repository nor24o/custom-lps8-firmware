-- LuCI Controller for Dragino LoRa Gateway (raw_lora_app / sx1276_app)
module("luci.controller.lora", package.seeall)

function index()
    local page = entry({"admin", "lora"}, alias("admin", "lora", "status"), _("LoRa Gateway"), 20)
    page.dependent = false

    entry({"admin", "lora", "status"}, template("lora/status"), _("Realtime Status"), 10)
    entry({"admin", "lora", "diag"}, template("lora/diag"), _("Pin & GPIO Diagnostics"), 15)
    entry({"admin", "lora", "config"}, template("lora/config"), _("Settings & Config"), 20)
    entry({"admin", "lora", "pinout"}, template("lora/pinout"), _("Hardware Pinout & Map"), 25)
    entry({"admin", "lora", "log"}, template("lora/log"), _("Gateway Logs"), 30)

    entry({"admin", "lora", "api_status"}, call("action_status")).leaf = true
    entry({"admin", "lora", "api_config"}, call("action_config")).leaf = true
    entry({"admin", "lora", "api_packets"}, call("action_packets")).leaf = true
    entry({"admin", "lora", "api_log"}, call("action_log")).leaf = true
    entry({"admin", "lora", "action_service"}, call("action_service")).leaf = true
    entry({"admin", "lora", "api_tx_test"}, call("action_tx_test")).leaf = true
    entry({"admin", "lora", "api_gpio_diag"}, call("action_gpio_diag")).leaf = true
    entry({"admin", "lora", "api_gpio_set"}, call("action_gpio_set")).leaf = true
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
        q_drop = tonumber(live.q_drop) or 0,
        temp_c = tonumber(live.temp_c) or 0,
        temp_ok = (live.temp_ok == true),
        inst_cnt_us = tonumber(live.inst_cnt_us) or 0,
        trig_cnt_us = tonumber(live.trig_cnt_us) or 0,
        tx_status = live.tx_status or "TX_OFF",
        rx_status = live.rx_status or "RX_OFF",
        sf_mask = tonumber(live.sf_mask) or tonumber(cfg.sf_mask) or 255,
        ch_detect = live.ch_detect or {0,0,0,0,0,0,0,0}
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
    local jsonc = require "luci.jsonc"
    local packets = {}

    local f = io.open("/tmp/lora_packets.json", "r")
    if f then
        local raw = f:read("*a")
        f:close()
        local parsed = raw and jsonc.parse(raw)
        if parsed and type(parsed) == "table" and #parsed > 0 then
            http.prepare_content("application/json")
            http.write_json(parsed)
            return
        end
    end

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
