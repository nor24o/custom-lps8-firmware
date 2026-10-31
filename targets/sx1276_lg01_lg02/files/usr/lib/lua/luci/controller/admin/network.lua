-- Streamlined Network Controller (NO DHCP, NO Static Routes)
module("luci.controller.admin.network", package.seeall)

function index()
	local uci = require("luci.model.uci").cursor()
	local page

	page = node("admin", "network")
	page.target = firstchild()
	page.title  = _("Network")
	page.order  = 50
	page.index  = true

	local has_switch = false
	uci:foreach("network", "switch",
		function(s)
			has_switch = true
			return false
		end)

	if has_switch then
		page  = node("admin", "network", "vlan")
		page.target = cbi("admin_network/vlan")
		page.title  = _("Switch")
		page.order  = 20

		page = entry({"admin", "network", "switch_status"}, call("switch_status"), nil)
		page.leaf = true
	end

	local has_wifi = false
	uci:foreach("wireless", "wifi-device",
		function(s)
			has_wifi = true
			return false
		end)

	if has_wifi then
		page = entry({"admin", "network", "wireless_assoclist"}, call("wifi_assoclist"), nil)
		page.leaf = true

		page = entry({"admin", "network", "wireless_join"}, post("wifi_join"), nil)
		page.leaf = true

		page = entry({"admin", "network", "wireless_add"}, post("wifi_add"), nil)
		page.leaf = true

		page = entry({"admin", "network", "wireless_status"}, call("wifi_status"), nil)
		page.leaf = true

		page = entry({"admin", "network", "wireless_reconnect"}, post("wifi_reconnect"), nil)
		page.leaf = true

		page = entry({"admin", "network", "wireless_scan_trigger"}, post("wifi_scan_trigger"), nil)
		page.leaf = true

		page = entry({"admin", "network", "wireless_scan_results"}, call("wifi_scan_results"), nil)
		page.leaf = true

		page = entry({"admin", "network", "wireless"}, arcombine(cbi("admin_network/wifi_overview"), cbi("admin_network/wifi")), _("Wireless"), 15)
		page.leaf = true
		page.subindex = true

		if page.inreq then
			local wdev
			local net = require "luci.model.network".init(uci)
			for _, wdev in ipairs(net:get_wifidevs()) do
				local wnet
				for _, wnet in ipairs(wdev:get_wifinets()) do
					entry(
						{"admin", "network", "wireless", wnet:id()},
						alias("admin", "network", "wireless"),
						wdev:name() .. ": " .. wnet:shortname()
					)
				end
			end
		end
	end

	page = entry({"admin", "network", "iface_add"}, form("admin_network/iface_add"), nil)
	page.leaf = true

	page = entry({"admin", "network", "iface_status"}, call("iface_status"), nil)
	page.leaf = true

	page = entry({"admin", "network", "iface_reconnect"}, post("iface_reconnect"), nil)
	page.leaf = true

	page = entry({"admin", "network", "network"}, arcombine(cbi("admin_network/network"), cbi("admin_network/ifaces")), _("Interfaces"), 10)
	page.leaf   = true
	page.subindex = true

	if page.inreq then
		uci:foreach("network", "interface",
			function (section)
				local ifc = section[".name"]
				if ifc ~= "loopback" then
					entry({"admin", "network", "network", ifc},
					true, ifc:upper())
				end
			end)
	end

	page = node("admin", "network", "diagnostics")
	page.target = template("admin_network/diagnostics")
	page.title  = _("Diagnostics")
	page.order  = 60

	page = entry({"admin", "network", "diag_ping"}, post("diag_ping"), nil)
	page.leaf = true

	page = entry({"admin", "network", "diag_nslookup"}, post("diag_nslookup"), nil)
	page.leaf = true

	page = entry({"admin", "network", "diag_traceroute"}, post("diag_traceroute"), nil)
	page.leaf = true

	page = entry({"admin", "network", "diag_ping6"}, post("diag_ping6"), nil)
	page.leaf = true

	page = entry({"admin", "network", "diag_traceroute6"}, post("diag_traceroute6"), nil)
	page.leaf = true
end

function wifi_join()
	local tpl  = require "luci.template"
	local http = require "luci.http"
	local dev  = http.formvalue("device")
	local ssid = http.formvalue("join")

	if dev and ssid then
		local cancel = (http.formvalue("cancel") or http.formvalue("cbi.cancel"))
		if not cancel then
			local cbi = require "luci.cbi"
			local map = luci.cbi.load("admin_network/wifi_add")[1]

			if map:parse() ~= cbi.FORM_DONE then
				tpl.render("header")
				map:render()
				tpl.render("footer")
			end

			return
		end
	end

	tpl.render("admin_network/wifi_join")
end

function wifi_add()
	local dev = luci.http.formvalue("device")
	local ntm = require "luci.model.network".init()

	dev = dev and ntm:get_wifidev(dev)

	if dev then
		local net = dev:add_wifinet({
			mode = "ap",
			network = "lan"
		})

		net:set("ssid", "OpenWrt")
		net:set("encryption", "none")

		ntm:save("wireless")
		luci.http.redirect(net:admin_url())
	end
end

function iface_status(ifaces)
	local netmd = require "luci.model.network".init()
	local rv   = { }

	for iface in ifaces:gmatch("[%w%.%-_]+") do
		local net = netmd:get_network(iface)
		local device = net and net:get_interface()
		if device then
			local data = {
				id         = iface,
				proto      = net:proto(),
				uptime     = net:uptime(),
				gwaddr     = net:gwaddr(),
				dnsaddrs   = net:dnsaddrs(),
				name       = device:shortname(),
				type       = device:type(),
				typename   = device:get_type_i18n(),
				ifname     = device:name(),
				macaddr    = device:mac(),
				is_up      = device:is_up(),
				rx_bytes   = device:rx_bytes(),
				tx_bytes   = device:tx_bytes(),
				rx_packets = device:rx_packets(),
				tx_packets = device:tx_packets(),
				subdevices = { }
			}

			for _, dev in ipairs(net:get_interfaces() or {}) do
				data.subdevices[#data.subdevices+1] = {
					name       = dev:shortname(),
					type       = dev:type(),
					typename   = dev:get_type_i18n(),
					ifname     = dev:name(),
					macaddr    = dev:mac(),
					is_up      = dev:is_up(),
					rx_bytes   = dev:rx_bytes(),
					tx_bytes   = dev:tx_bytes(),
					rx_packets = dev:rx_packets(),
					tx_packets = dev:tx_packets(),
				}
			end

			rv[#rv+1] = data
		else
			rv[#rv+1] = {
				id   = iface,
				name = iface,
				type = "ethernet"
			}
		end
	end

	if #rv > 0 then
		luci.http.prepare_content("application/json")
		luci.http.write_json(rv)
		return
	end

	luci.http.status(404, "No such device")
end

function iface_reconnect(iface)
	local netmd = require "luci.model.network".init()
	local net = netmd:get_network(iface)
	if net then
		luci.sys.call("env -i /sbin/ifup %s >/dev/null 2>/dev/null"
			% luci.util.shellquote(iface))
		luci.http.status(200, "Reconnected")
		return
	end

	luci.http.status(404, "No such interface")
end

function wifi_status(devs)
	local s    = require "luci.tools.status"
	local rv   = { }

	if type(devs) == "string" then
		local dev
		for dev in devs:gmatch("[%w%.%-]+") do
			rv[#rv+1] = s.wifi_network(dev)
		end
	end

	if #rv > 0 then
		luci.http.prepare_content("application/json")
		luci.http.write_json(rv)
		return
	end

	luci.http.status(404, "No such device")
end

function wifi_reconnect(radio)
	local rc = luci.sys.call("env -i /sbin/wifi up %s" % luci.util.shellquote(radio))
	if rc == 0 then
		luci.http.status(200, "Reconnected")
	else
		luci.http.status(500, "Error")
	end
end

function wifi_assoclist()
	local s = require "luci.tools.status"
	luci.http.prepare_content("application/json")
	luci.http.write_json(s.wifi_assoclist())
end

function switch_status(switches)
	local s = require "luci.tools.status"
	luci.http.prepare_content("application/json")
	luci.http.write_json(s.switch_status(switches))
end

function diag_command(cmd, addr)
	if addr and addr:match("^[a-zA-Z0-9%-%.:_]+$") then
		luci.http.prepare_content("text/plain")
		local util = io.popen(cmd % luci.util.shellquote(addr))
		if util then
			while true do
				local ln = util:read("*l")
				if not ln then break end
				luci.http.write(ln)
				luci.http.write("\n")
			end
			util:close()
		end
		return
	end
	luci.http.status(500, "Bad address")
end

function diag_ping(addr)
	diag_command("ping -c 5 -W 1 %s 2>&1", addr)
end

function diag_traceroute(addr)
	diag_command("traceroute -q 1 -w 1 -n %s 2>&1", addr)
end

function diag_nslookup(addr)
	diag_command("nslookup %s 2>&1", addr)
end

function diag_ping6(addr)
	diag_command("ping6 -c 5 %s 2>&1", addr)
end

function diag_traceroute6(addr)
	diag_command("traceroute6 -q 1 -w 2 -n %s 2>&1", addr)
end
