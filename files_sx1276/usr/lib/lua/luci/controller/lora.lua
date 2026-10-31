-- LuCI Controller for LoRaWAN Gateway
module("luci.controller.lora", package.seeall)

function index()
    -- Top-level tab: LoRa Gateway (order 20, between Status and System)
    local page = entry({"admin", "lora"}, alias("admin", "lora", "status"), _("LoRa Gateway"), 20)
    page.dependent = false

    -- Submenus
    entry({"admin", "lora", "status"}, template("lora/status"), _("Realtime Status"), 10)
    entry({"admin", "lora", "config"}, cbi("lora/config"), _("Settings & Config"), 20)
    entry({"admin", "lora", "log"}, template("lora/log"), _("Gateway Logs"), 30)

    -- AJAX JSON Endpoints
    entry({"admin", "lora", "api_status"}, call("action_status")).leaf = true
    entry({"admin", "lora", "api_packets"}, call("action_packets")).leaf = true
    entry({"admin", "lora", "api_log"}, call("action_log")).leaf = true
    entry({"admin", "lora", "action_service"}, call("action_service")).leaf = true
end

function action_status()
    local sys = require "luci.sys"
    local http = require "luci.http"
    local uci = require("luci.model.uci").cursor()
    local jsonc = require "luci.jsonc"

    local pid_str = sys.exec("pidof raw_lora_app lg02_pkt_fwd lg01_pkt_fwd 2>/dev/null || pgrep -f lora_qemu_sim.sh 2>/dev/null"):match("(%d+)") or ""
    local pid = tonumber(pid_str)
    local is_running = (pid ~= nil and pid > 0)

    local gwid = uci:get("lora", "general", "gateway_id") or "a84041ffff16c21c"
    local server = uci:get("lora", "general", "server_address") or "eu1.cloud.thethings.network"
    local port_up = uci:get("lora", "general", "serv_port_up") or "1700"
    local port_down = uci:get("lora", "general", "serv_port_down") or "1700"
    local region = uci:get("lora", "general", "region") or "EU868"
    local concentrator = uci:get("lora", "general", "concentrator") or "sx1302"
    local iface = uci:get("lora", "general", "interface") or "spi"
    local tx_power = uci:get("lora", "general", "tx_power") or "26"
    local syncword = uci:get("lora", "general", "syncword") or "0x34"

    local uptime = "Offline"
    if is_running then
        uptime = "Active (PID " .. pid .. ")"
    end

    local rx_cnt = 0
    local tx_cnt = 0
    local crc_err = 0
    local ack_ratio = "100%"

    local sf = io.open("/tmp/lora_stats.json", "r")
    if sf then
        local content = sf:read("*a")
        sf:close()
        local s = jsonc.parse(content)
        if s and type(s) == "table" then
            rx_cnt = s.rx or 0
            tx_cnt = s.tx or 0
            crc_err = s.crc_err or 0
            if s.ack_ratio then ack_ratio = tostring(s.ack_ratio) end
        end
    end

    local res = {
        running = is_running,
        pid = pid or 0,
        uptime = uptime,
        gateway_id = gwid,
        server = server,
        port_up = tonumber(port_up) or 1700,
        port_down = tonumber(port_down) or 1700,
        region = region,
        concentrator = concentrator,
        interface = iface,
        tx_power = tonumber(tx_power) or 26,
        syncword = syncword,
        rx_count = rx_cnt,
        tx_count = tx_cnt,
        crc_err = crc_err,
        ack_ratio = ack_ratio
    }

    http.prepare_content("application/json")
    http.write_json(res)
end

function action_packets()
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    local packets = {}

    local f = io.open("/tmp/lora_packets.json", "r")
    if f then
        local content = f:read("*a")
        f:close()
        local parsed = jsonc.parse(content)
        if parsed and type(parsed) == "table" then
            packets = parsed
        end
    end

    if #packets == 0 then
        local pipe = io.popen("logread -l 40 2>/dev/null | grep -F '[RX]' | tail -n 25")
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
                        freq = freq:gsub("%s+", ""),
                        rssi = rssi:gsub("%s+", ""),
                        snr = snr:gsub("%s+", ""),
                        status = crc:gsub("%s+", "")
                    })
                    id = id + 1
                end
            end
            pipe:close()
        end
    end

    http.prepare_content("application/json")
    http.write_json(packets)
end

function action_log()
    local http = require "luci.http"
    local pipe = io.popen("logread -l 60 2>/dev/null | grep -iE 'lora|sx1302|sx1276|pkt_fwd' | tail -n 50")
    local output = ""
    if pipe then
        output = pipe:read("*a")
        pipe:close()
    end
    if output == "" then
        output = "[Log] Gateway service initializing or waiting for radio events..."
    end
    http.prepare_content("text/plain")
    http.write(output)
end

function action_service()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local cmd = http.formvalue("cmd")

    if cmd == "restart" or cmd == "start" or cmd == "stop" then
        sys.call("/etc/init.d/lora_gateway " .. cmd .. " >/dev/null 2>&1 &")
        http.prepare_content("application/json")
        http.write_json({ success = true, command = cmd })
    else
        http.status(400, "Invalid Command")
    end
end
